//
//  PacketTunnelProvider.swift
//  GemodTunnel
//
//  Created by Loic on 2026/4/24.
//

import Foundation
import NetworkExtension
#if canImport(Libbox)
import Libbox
#endif

class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var backend: ProxyBackend = RealSingboxProxyBackend(tunnelProvider: self)

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        _ = options
        SharedTunnelEventStore.appendDiagnostic("startTunnel invoked")
        SharedTunnelEventStore.clearUserInitiatedStopFlag()
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard error == nil else {
                let ns = error as NSError?
                let msg = "setTunnelNetworkSettings failed domain=\(ns?.domain ?? "-") code=\(ns?.code ?? -1) desc=\(ns?.localizedDescription ?? "unknown")"
                SharedTunnelEventStore.appendDiagnostic(msg)
                completionHandler(error)
                return
            }
            Task {
                await self?.backend.reset()
                completionHandler(nil)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let isUserInitiated = SharedTunnelEventStore.consumeUserInitiatedStopFlag()
        if !isUserInitiated && reason != .none {
            SharedTunnelEventStore.saveLastStopReason(reason)
        }
        SharedTunnelEventStore.appendDiagnostic("stopTunnel reason=\(reason.rawValue)")
        Task {
            await backend.reset()
            completionHandler()
        }
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let payload = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: String],
              let command = payload["command"] else {
            completionHandler?(encodeResponse(["status": "error", "message": "invalid message"]))
            return
        }

        switch command {
        case "health":
            Task {
                completionHandler?(encodeResponse(await backend.healthPayload()))
            }
        case "connect":
            let transport = payload["transport"] ?? "tun"
            let node = payload["node"] ?? ""
            let mode = payload["mode"] ?? "rule"
            let subscriptionContent = payload["subscription_content"]
            Task {
                completionHandler?(encodeResponse(await backend.connect(
                    node: node,
                    mode: mode,
                    transport: transport,
                    subscriptionContent: subscriptionContent
                )))
            }
        case "disconnect":
            Task {
                completionHandler?(encodeResponse(await backend.disconnect()))
            }
        case "status":
            Task {
                completionHandler?(encodeResponse(await backend.statusPayload()))
            }
        case "latency":
            let node = payload["node"] ?? ""
            let timeoutMs = Int(payload["timeout_ms"] ?? "") ?? 2500
            Task {
                completionHandler?(encodeResponse(await backend.latencyPayload(node: node, timeoutMs: timeoutMs)))
            }
        default:
            completionHandler?(encodeResponse(["status": "error", "message": "unsupported command"]))
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }

    private func encodeResponse(_ payload: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: payload)
    }
}

private protocol ProxyBackend {
    func reset() async
    func healthPayload() async -> [String: String]
    func connect(node: String, mode: String, transport: String, subscriptionContent: String?) async -> [String: String]
    func disconnect() async -> [String: String]
    func statusPayload() async -> [String: String]
    func latencyPayload(node: String, timeoutMs: Int) async -> [String: String]
}

private actor RealSingboxProxyBackend: ProxyBackend {
    private let activeSelectorTag = "gemod-active"
    private enum ProxyState: String {
        case idle
        case connecting
        case connected
        case disconnecting
        case failed
    }
    private enum StartupPhase: String {
        case idle
        case preparing
        case ready
        case failed
    }
    private var state: ProxyState = .idle
    private var currentNode: String = ""
    private var currentMode: String = "rule"
    private var ready: Bool = false
    private var startupPhase: StartupPhase = .idle
    private var lastErrorMessage: String = ""
    private var lastProbeAt: Date?
    private var lastDNSProbeAt: Date?
    private var lastTransitionAt: Date = .distantPast
    private var runtimeDiagnostics: [String: String] = [:]
    private let minimumTransitionInterval: TimeInterval = 0.25
    private let runtimeDriver: SingboxRuntimeDriver

    init(tunnelProvider: PacketTunnelProvider? = nil, runtimeDriver: SingboxRuntimeDriver? = nil) {
        if let runtimeDriver {
            self.runtimeDriver = runtimeDriver
        } else {
            self.runtimeDriver = EmbeddedSingboxRuntimeDriver(tunnelProvider: tunnelProvider)
        }
    }

    func reset() async {
        state = .idle
        currentNode = ""
        currentMode = "rule"
        ready = false
        startupPhase = .idle
        lastErrorMessage = ""
        lastProbeAt = nil
        lastDNSProbeAt = nil
        lastTransitionAt = Date()
        runtimeDiagnostics = [:]
        await runtimeDriver.stop()
    }

    func healthPayload() async -> [String: String] {
        let wasReady = ready
        let pingOK = await ensureControllerReady(maxWait: 1.0)
        if wasReady && !pingOK && state == .connected {
            SharedTunnelEventStore.saveInterruptionNotice(
                source: "core",
                message: lastErrorMessage.isEmpty ? "sing-box controller became unavailable" : lastErrorMessage
            )
        }
        await refreshSelectorDiagnostics()
        await refreshDNSProbeDiagnosticsIfNeeded(force: false)
        var payload: [String: String] = [
            "status": "ok",
            "backend": "singbox",
            "state": state.rawValue,
            "transport": "tun",
            "startup_phase": startupPhase.rawValue,
            "ready": pingOK ? "true" : "false",
            "message": pingOK ? "" : lastErrorMessage
        ]
        for (key, value) in runtimeDiagnostics where !value.isEmpty {
            payload[key] = value
        }
        return payload
    }

    func connect(node: String, mode: String, transport: String, subscriptionContent: String?) async -> [String: String] {
        let normalizedTransport = transport.lowercased()
        guard normalizedTransport == "tun" else {
            return [
                "status": "error",
                "message": "unsupported transport: \(transport), only tun is allowed"
            ]
        }
        let trimmedNode = node.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNode.isEmpty else {
            return [
                "status": "error",
                "message": "missing node"
            ]
        }
        let now = Date()
        if now.timeIntervalSince(lastTransitionAt) < minimumTransitionInterval {
            return [
                "status": "error",
                "message": "busy, retry shortly",
                "retry_after_ms": "250"
            ]
        }
        if state == .connecting || state == .disconnecting {
            return [
                "status": "error",
                "message": "state busy: \(state.rawValue)",
                "retry_after_ms": "250"
            ]
        }
        if state == .connected &&
            currentNode == trimmedNode &&
            currentMode == mode &&
            ready {
            var payload: [String: String] = [
                "status": "ok",
                "node": trimmedNode,
                "mode": mode,
                "transport": "tun",
                "state": state.rawValue,
                "idempotent": "true",
                "ready": "true",
                "config_mode": "subscription-proxies-only"
            ]
            for (key, value) in runtimeDiagnostics where !value.isEmpty {
                payload[key] = value
            }
            return payload
        }

        if state == .connected &&
            ready {
            if await switchActiveNodeViaClashAPI(to: trimmedNode) {
                currentNode = trimmedNode
                currentMode = mode
                lastErrorMessage = ""
                lastTransitionAt = Date()
                await refreshSelectorDiagnostics()
                await refreshDNSProbeDiagnosticsIfNeeded(force: true)
                return [
                    "status": "ok",
                    "node": trimmedNode,
                    "mode": mode,
                    "transport": "tun",
                    "state": state.rawValue,
                    "startup_phase": startupPhase.rawValue,
                    "ready": "true",
                    "config_mode": "subscription-proxies-only",
                    "switched_via": "clash_selector"
                ]
            }
            SharedTunnelEventStore.appendDiagnostic("selector switch failed, fallback to service restart")
        }

        state = .connecting
        startupPhase = .preparing
        currentNode = trimmedNode
        currentMode = mode
        lastTransitionAt = now

        let startup = await runtimeDriver.startIfNeeded(
            node: trimmedNode,
            mode: mode,
            transport: transport,
            subscriptionContent: subscriptionContent
        )
        runtimeDiagnostics = startup.diagnostics
        if startup.isReady {
            state = .connected
            startupPhase = .ready
            ready = true
            lastErrorMessage = ""
            lastProbeAt = Date()
            lastTransitionAt = Date()
            _ = await switchActiveNodeViaClashAPI(to: trimmedNode, interruptExistingConnections: false)
            await refreshSelectorDiagnostics()
            await refreshDNSProbeDiagnosticsIfNeeded(force: true)
            var payload: [String: String] = [
                "status": "ok",
                "node": trimmedNode,
                "mode": mode,
                "transport": "tun",
                "state": state.rawValue,
                "startup_phase": startupPhase.rawValue,
                "ready": "true",
                "config_mode": "subscription-proxies-only"
            ]
            for (key, value) in runtimeDiagnostics where !value.isEmpty {
                payload[key] = value
            }
            return payload
        } else {
            state = .failed
            startupPhase = .failed
            ready = false
            lastErrorMessage = startup.message
            lastProbeAt = Date()
            lastTransitionAt = Date()
            var payload: [String: String] = [
                "status": "error",
                "message": lastErrorMessage.isEmpty ? "sing-box controller unavailable on 127.0.0.1" : lastErrorMessage,
                "retry_after_ms": "1000"
            ]
            for (key, value) in runtimeDiagnostics where !value.isEmpty {
                payload[key] = value
            }
            return payload
        }
    }

    func disconnect() async -> [String: String] {
        let now = Date()
        if now.timeIntervalSince(lastTransitionAt) < minimumTransitionInterval {
            return [
                "status": "error",
                "message": "busy, retry shortly",
                "retry_after_ms": "250"
            ]
        }
        if state == .idle || state == .disconnecting {
            return [
                "status": "ok",
                "state": state.rawValue,
                "idempotent": "true"
            ]
        }
        state = .disconnecting
        lastTransitionAt = now
        currentNode = ""
        currentMode = "rule"
        state = .idle
        ready = false
        startupPhase = .idle
        lastErrorMessage = ""
        runtimeDiagnostics = [:]
        await runtimeDriver.stop()
        lastTransitionAt = Date()
        return [
            "status": "ok",
            "state": state.rawValue,
            "idempotent": "true"
        ]
    }

    func statusPayload() async -> [String: String] {
        await refreshSelectorDiagnostics()
        await refreshDNSProbeDiagnosticsIfNeeded(force: false)
        var payload: [String: String] = [
            "status": "ok",
            "connected": state == .connected ? "true" : "false",
            "node": currentNode,
            "mode": currentMode,
            "transport": "tun",
            "state": state.rawValue,
            "backend": "singbox",
            "startup_phase": startupPhase.rawValue,
            "ready": ready ? "true" : "false",
            "message": ready ? "" : lastErrorMessage,
            "config_mode": "subscription-proxies-only"
        ]
        for (key, value) in runtimeDiagnostics where !value.isEmpty {
            payload[key] = value
        }
        return payload
    }

    func latencyPayload(node: String, timeoutMs: Int) async -> [String: String] {
        let trimmedNode = node.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNode.isEmpty else {
            return ["status": "error", "message": "missing node"]
        }
        guard await ensureControllerReady(maxWait: 1.2) else {
            return ["status": "error", "message": "sing-box controller not ready"]
        }

        let boundedTimeout = max(800, min(timeoutMs, 6000))
        let testURLs = ["https://www.google.com.hk"]
        let resolvedNodeTag = await resolveProxyTag(for: trimmedNode) ?? trimmedNode
        if resolvedNodeTag != trimmedNode {
            SharedTunnelEventStore.appendDiagnostic("latency tag remap from=\(trimmedNode) to=\(resolvedNodeTag)")
        }
        var lastError = "delay api timeout"
        var attemptedURLs: [String] = []
        for testURL in testURLs {
            attemptedURLs.append(testURL)
            let result = await requestClashDelay(
                path: "proxies",
                nodeTag: resolvedNodeTag,
                testURL: testURL,
                timeoutMs: boundedTimeout
            )
            if let delay = result.delay {
                return [
                    "status": "ok",
                    "latency_ms": String(delay),
                    "probe": "clashapi/proxies",
                    "probe_url": testURL
                ]
            }
            if let reason = result.error {
                lastError = reason
            }
        }
        SharedTunnelEventStore.appendDiagnostic("latency failed node=\(resolvedNodeTag) urls=\(attemptedURLs.joined(separator: ",")) error=\(lastError)")
        return [
            "status": "error",
            "message": lastError,
            "probe": "clashapi",
            "probe_urls": attemptedURLs.joined(separator: ",")
        ]
    }

    private func probeLocalController() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9090/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func switchActiveNodeViaClashAPI(to nodeTag: String, interruptExistingConnections: Bool = true) async -> Bool {
        let resolvedNodeTag = await resolveProxyTag(for: nodeTag) ?? nodeTag
        guard let encodedSelector = activeSelectorTag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://127.0.0.1:9090/proxies/\(encodedSelector)") else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: 2.2)
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": resolvedNodeTag], options: [])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            let didInterrupt = interruptExistingConnections
                ? await interruptActiveConnectionsViaClashAPI()
                : true
            SharedTunnelEventStore.appendDiagnostic(
                "selector switched to node=\(resolvedNodeTag) interrupt=\(interruptExistingConnections ? (didInterrupt ? "true" : "false") : "skipped")"
            )
            return didInterrupt
        } catch {
            SharedTunnelEventStore.appendDiagnostic("selector switch error: \(error.localizedDescription)")
            return false
        }
    }

    private func interruptActiveConnectionsViaClashAPI() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9090/connections") else {
            return false
        }
        var request = URLRequest(url: url, timeoutInterval: 2.5)
        request.httpMethod = "DELETE"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                SharedTunnelEventStore.appendDiagnostic("interrupt active connections missing status")
                return false
            }
            guard http.statusCode == 204 || (200...299).contains(http.statusCode) else {
                SharedTunnelEventStore.appendDiagnostic("interrupt active connections status=\(http.statusCode)")
                return false
            }
            return true
        } catch {
            SharedTunnelEventStore.appendDiagnostic("interrupt active connections error: \(error.localizedDescription)")
            return false
        }
    }

    private func requestClashDelay(
        path: String,
        nodeTag: String,
        testURL: String,
        timeoutMs: Int
    ) async -> (delay: Int?, error: String?) {
        guard let encodedTag = nodeTag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return (nil, "node tag encode failed")
        }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = 9090
        components.percentEncodedPath = "/\(path)/\(encodedTag)/delay"
        components.queryItems = [
            URLQueryItem(name: "url", value: testURL),
            URLQueryItem(name: "timeout", value: String(timeoutMs))
        ]
        guard let url = components.url else { return (nil, "delay url build failed") }

        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeoutMs) / 1000.0 + 0.8)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (nil, "delay response missing status")
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let compact = body.replacingOccurrences(of: "\n", with: " ")
                let snippet = String(compact.prefix(120))
                return (nil, "delay \(path) status=\(http.statusCode) body=\(snippet)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, "delay \(path) invalid json")
            }
            if let value = json["delay"] as? Int {
                if value > 0 { return (value, nil) }
                return (nil, "delay \(path) value=\(value)")
            }
            if let value = json["delay"] as? Double {
                if value > 0 { return (Int(value.rounded()), nil) }
                return (nil, "delay \(path) value=\(value)")
            }
            if let value = json["delay"] as? String, let intValue = Int(value), intValue > 0 {
                return (intValue, nil)
            }
            return (nil, "delay \(path) missing delay field")
        } catch {
            return (nil, "delay \(path) request error=\(error.localizedDescription)")
        }
    }

    private func resolveProxyTag(for requestedTag: String) async -> String? {
        guard let url = URL(string: "http://127.0.0.1:9090/proxies") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 2.0)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let proxies = json["proxies"] as? [String: Any] else {
                return nil
            }
            if proxies[requestedTag] != nil {
                return requestedTag
            }
            let normalizedRequested = normalizeTagForLookup(requestedTag)
            if let matched = proxies.keys.first(where: { normalizeTagForLookup($0) == normalizedRequested }) {
                return matched
            }
            return nil
        } catch {
            return nil
        }
    }

    private func normalizeTagForLookup(_ text: String) -> String {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return compact.lowercased()
    }

    private func ensureControllerReady(maxWait: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        startupPhase = .preparing
        var attempts = 0
        while Date() <= deadline {
            attempts += 1
            if await probeLocalController() {
                ready = true
                startupPhase = .ready
                lastErrorMessage = ""
                lastProbeAt = Date()
                return true
            }
            lastProbeAt = Date()
            lastErrorMessage = "sing-box controller not ready on 127.0.0.1 (attempt \(attempts))"
            if Date() < deadline {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        ready = false
        startupPhase = .failed
        return false
    }

    private func refreshSelectorDiagnostics() async {
        guard ready || state == .connected else { return }
        if let selectorCurrent = await currentSelectorTagViaClashAPI(tag: activeSelectorTag) {
            runtimeDiagnostics["selector_current"] = selectorCurrent
        } else if !currentNode.isEmpty {
            runtimeDiagnostics["selector_current"] = currentNode
        }
    }

    private func currentSelectorTagViaClashAPI(tag: String) async -> String? {
        guard let encodedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://127.0.0.1:9090/proxies/\(encodedTag)") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            if let now = json["now"] as? String, !now.isEmpty {
                return now
            }
            return nil
        } catch {
            return nil
        }
    }

    private func refreshDNSProbeDiagnosticsIfNeeded(force: Bool) async {
        guard ready, !currentNode.isEmpty else { return }
        if !force, let lastDNSProbeAt, Date().timeIntervalSince(lastDNSProbeAt) < 12 {
            return
        }
        let targetText = runtimeDiagnostics["dns_probe_targets"] ?? "-"
        guard targetText != "-", !targetText.isEmpty else {
            runtimeDiagnostics["dns_probe"] = "no-https-target"
            return
        }

        var resultItems: [String] = []
        let entries = targetText.split(separator: ",").map(String.init)
        for entry in entries {
            let parts = entry.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let tag = parts[0]
            let detour = parts[1]
            let url = parts[2]

            if detour == "direct" {
                let ok = await probeDirectURL(url, timeoutMs: 1800)
                resultItems.append(ok ? "\(tag):ok(direct)" : "\(tag):fail(direct)")
                continue
            }

            let probeTag = await resolveProxyTag(for: detour) ?? detour
            let result = await requestClashDelay(
                path: "proxies",
                nodeTag: probeTag,
                testURL: url,
                timeoutMs: 1800
            )
            if let delay = result.delay {
                resultItems.append("\(tag):ok(\(delay)ms)")
            } else {
                resultItems.append("\(tag):\(compactDelayError(result.error))")
            }
        }
        let probeText = resultItems.isEmpty ? "empty" : resultItems.joined(separator: ",")
        runtimeDiagnostics["dns_probe"] = probeText
        runtimeDiagnostics["dns_probe_at"] = String(Int(Date().timeIntervalSince1970))
        lastDNSProbeAt = Date()
        SharedTunnelEventStore.appendDiagnostic("dns probe \(probeText)")
    }

    private func probeDirectURL(_ rawURL: String, timeoutMs: Int) async -> Bool {
        guard let url = URL(string: rawURL) else { return false }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeoutMs) / 1000.0)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...399).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func compactDelayError(_ raw: String?) -> String {
        let text = (raw ?? "").lowercased()
        if text.isEmpty { return "fail" }
        if text.contains("timed out") || text.contains("timeout") { return "timeout" }
        if text.contains("status=503") { return "503" }
        if text.contains("status=404") { return "404" }
        if text.contains("request error") { return "request-error" }
        return "fail"
    }
}

private struct SingboxStartupResult {
    let isReady: Bool
    let message: String
    let diagnostics: [String: String]

    init(isReady: Bool, message: String, diagnostics: [String: String] = [:]) {
        self.isReady = isReady
        self.message = message
        self.diagnostics = diagnostics
    }
}

private protocol SingboxRuntimeDriver: Sendable {
    func startIfNeeded(node: String, mode: String, transport: String, subscriptionContent: String?) async -> SingboxStartupResult
    func stop() async
    func diagnosticPayload() async -> [String: String]
}

private actor EmbeddedSingboxRuntimeDriver: SingboxRuntimeDriver {
    private let activeSelectorTag = "gemod-active"
    private var lastStartAt: Date?
    private var launchAttempts: Int = 0
    private var runtimePresenceChecked = false
    private var runtimePresent = false
    private var lastRuntimeDiagnostics: [String: String] = [:]
    #if canImport(Libbox)
    private var setupFinished = false
    private var activeService: LibboxBoxService?
    private var activeConfig: String?
    private let platformInterface: GemodLibboxPlatformInterface
    #endif

    init(tunnelProvider: PacketTunnelProvider? = nil) {
        #if canImport(Libbox)
        self.platformInterface = GemodLibboxPlatformInterface(tunnelProvider: tunnelProvider)
        #else
        _ = tunnelProvider
        #endif
    }

    func startIfNeeded(node: String, mode: String, transport: String, subscriptionContent: String?) async -> SingboxStartupResult {
        _ = transport
        let hasRuntime = detectRuntimePresenceIfNeeded()
        guard hasRuntime else {
            return SingboxStartupResult(
                isReady: false,
                message: "sing-box runtime is unavailable (Libbox not linked/importable in GemodTunnel target)",
                diagnostics: lastRuntimeDiagnostics
            )
        }

        #if canImport(Libbox)
        var configContent = buildConfig(node: node, mode: mode, subscriptionContent: subscriptionContent)
        configContent = await localizeRemoteRuleSets(configContent)
        if await probeLocalController(), activeConfig == configContent {
            return SingboxStartupResult(isReady: true, message: "", diagnostics: lastRuntimeDiagnostics)
        }
        #else
        if await probeLocalController() {
            return SingboxStartupResult(isReady: true, message: "", diagnostics: lastRuntimeDiagnostics)
        }
        #endif

        launchAttempts += 1
        lastStartAt = Date()

        #if canImport(Libbox)
        let startup = startServiceIfNeeded(configContent: configContent)
        guard startup.isReady else {
            return startup
        }
        #endif

        let ready = await waitControllerReady(maxWait: 2.6)
        if ready {
            return SingboxStartupResult(isReady: true, message: "", diagnostics: lastRuntimeDiagnostics)
        }
        let detail = "sing-box runtime not ready (attempt \(launchAttempts)); controller not reachable on 127.0.0.1:9090"
        return SingboxStartupResult(isReady: false, message: detail, diagnostics: lastRuntimeDiagnostics)
    }

    func stop() async {
        #if canImport(Libbox)
        if let service = activeService {
            do {
                try service.close()
            } catch {
                SharedTunnelEventStore.appendDiagnostic("libbox service close error: \(error.localizedDescription)")
            }
        }
        activeService = nil
        activeConfig = nil
        #endif
        lastRuntimeDiagnostics = [:]
    }

    func diagnosticPayload() async -> [String: String] {
        return lastRuntimeDiagnostics
    }

    private func detectRuntimePresenceIfNeeded() -> Bool {
        if runtimePresenceChecked {
            return runtimePresent
        }
        runtimePresenceChecked = true

        #if canImport(Libbox)
        runtimePresent = true
        SharedTunnelEventStore.appendDiagnostic("libbox module detected via canImport(Libbox)")
        return true
        #else
        let knownTokens = ["singbox", "libbox"]
        let frameworkMatches = Bundle.allFrameworks.contains { bundle in
            let name = bundle.bundleURL.lastPathComponent.lowercased()
            return knownTokens.contains(where: { name.contains($0) })
        }
        if frameworkMatches {
            runtimePresent = true
            return true
        }

        if let pluginsURL = Bundle.main.builtInPlugInsURL,
           let entries = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) {
            let pluginMatch = entries.contains { url in
                let name = url.lastPathComponent.lowercased()
                return knownTokens.contains(where: { name.contains($0) })
            }
            runtimePresent = pluginMatch
            return pluginMatch
        }

        runtimePresent = false
        return false
        #endif
    }

    private func waitControllerReady(maxWait: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(maxWait)
        while Date() <= deadline {
            if await probeLocalController() {
                return true
            }
            if Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        return false
    }

    private func probeLocalController() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:9090/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    #if canImport(Libbox)
    private func startServiceIfNeeded(configContent: String) -> SingboxStartupResult {
        do {
            try ensureLibboxSetup()
        } catch {
            return SingboxStartupResult(
                isReady: false,
                message: "libbox setup failed: \(error.localizedDescription)",
                diagnostics: lastRuntimeDiagnostics
            )
        }

        if let existingService = activeService, activeConfig == configContent {
            do {
                try existingService.start()
                SharedTunnelEventStore.appendDiagnostic("libbox service start called (reuse)")
                return SingboxStartupResult(isReady: true, message: "", diagnostics: lastRuntimeDiagnostics)
            } catch {
                activeService = nil
                activeConfig = nil
                SharedTunnelEventStore.appendDiagnostic("libbox service restart failed: \(error.localizedDescription)")
            }
        }

        var createError: NSError?
        guard let service = LibboxNewService(configContent, platformInterface, &createError) else {
            let detail = createError?.localizedDescription ?? "unknown create error"
            return SingboxStartupResult(
                isReady: false,
                message: "libbox create service failed: \(detail)",
                diagnostics: lastRuntimeDiagnostics
            )
        }

        do {
            try service.start()
        } catch {
            let rawMessage = error.localizedDescription
            if shouldRetryWithLocalRuleSetFallback(rawMessage),
               let fallbackConfig = buildLocalRuleSetFallbackConfig(from: configContent) {
                SharedTunnelEventStore.appendDiagnostic("libbox start failed on remote rule-set; retry with local-rule_set fallback")
                var retryCreateError: NSError?
                if let retryService = LibboxNewService(fallbackConfig, platformInterface, &retryCreateError) {
                    do {
                        try retryService.start()
                        activeService = retryService
                        activeConfig = fallbackConfig
                        lastRuntimeDiagnostics["config_source"] = "subscription-local-ruleset-fallback"
                        SharedTunnelEventStore.appendDiagnostic("libbox service started (local-rule_set fallback)")
                        return SingboxStartupResult(isReady: true, message: "", diagnostics: lastRuntimeDiagnostics)
                    } catch {
                        let retryDetail = error.localizedDescription
                        SharedTunnelEventStore.appendDiagnostic("libbox local-rule_set fallback failed: \(retryDetail)")
                    }
                } else if let retryCreateError {
                    SharedTunnelEventStore.appendDiagnostic("libbox local-rule_set fallback create failed: \(retryCreateError.localizedDescription)")
                }
            }
            return SingboxStartupResult(
                isReady: false,
                message: "libbox start failed: \(rawMessage)",
                diagnostics: lastRuntimeDiagnostics
            )
        }

        activeService = service
        activeConfig = configContent
        SharedTunnelEventStore.appendDiagnostic("libbox service started")
        return SingboxStartupResult(isReady: true, message: "", diagnostics: lastRuntimeDiagnostics)
    }

    private func localizeRemoteRuleSets(_ configContent: String) async -> String {
        lastRuntimeDiagnostics["ruleset_mode"] = "bypass"
        lastRuntimeDiagnostics["ruleset_local_count"] = "0"
        lastRuntimeDiagnostics["ruleset_downloaded_count"] = "0"
        lastRuntimeDiagnostics["ruleset_cached_count"] = "0"
        lastRuntimeDiagnostics["ruleset_removed_count"] = "0"
        lastRuntimeDiagnostics["ruleset_removed_tags"] = ""
        guard let data = configContent.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var route = json["route"] as? [String: Any],
              let rawRuleSets = route["rule_set"] as? [Any],
              !rawRuleSets.isEmpty else {
            return configContent
        }

        let ruleSetDirectory = ensureLocalRuleSetDirectory()
        var localizedRuleSets: [Any] = []
        var changed = false
        var removedRemoteTags: [String] = []
        var downloadedTags: [String] = []
        var cachedTags: [String] = []

        for item in rawRuleSets {
            guard let dict = item as? [String: Any] else {
                localizedRuleSets.append(item)
                continue
            }
            let type = (dict["type"] as? String)?.lowercased() ?? ""
            guard type == "remote" else {
                localizedRuleSets.append(dict)
                continue
            }

            let tag = (dict["tag"] as? String) ?? ""
            let urlText = (dict["url"] as? String) ?? ""
            guard !tag.isEmpty, let remoteURL = URL(string: urlText), !urlText.isEmpty else {
                changed = true
                removedRemoteTags.append(tag.isEmpty ? "<empty>" : tag)
                continue
            }

            let format = (dict["format"] as? String) ?? "binary"
            let localName = localRuleSetFileName(for: tag)
            let localURL = ruleSetDirectory.appendingPathComponent(localName, isDirectory: false)
            let hasCachedFile = FileManager.default.fileExists(atPath: localURL.path)
            var shouldUseLocal = false

            if let downloaded = await downloadRuleSetData(from: remoteURL) {
                do {
                    try downloaded.write(to: localURL, options: .atomic)
                    shouldUseLocal = true
                    changed = true
                    downloadedTags.append(tag)
                    SharedTunnelEventStore.appendDiagnostic("ruleset downloaded tag=\(tag) bytes=\(downloaded.count)")
                } catch {
                    SharedTunnelEventStore.appendDiagnostic("ruleset write failed tag=\(tag) error=\(error.localizedDescription)")
                    shouldUseLocal = hasCachedFile
                }
            } else {
                shouldUseLocal = hasCachedFile
                if hasCachedFile {
                    cachedTags.append(tag)
                    SharedTunnelEventStore.appendDiagnostic("ruleset download timeout tag=\(tag), use cached local file")
                } else {
                    SharedTunnelEventStore.appendDiagnostic("ruleset download timeout tag=\(tag), no local cache")
                }
            }

            if shouldUseLocal {
                var localEntry: [String: Any] = [
                    "type": "local",
                    "tag": tag,
                    "path": localURL.path
                ]
                if !format.isEmpty {
                    localEntry["format"] = format
                }
                localizedRuleSets.append(localEntry)
                changed = true
            } else {
                removedRemoteTags.append(tag)
                changed = true
            }
        }

        if changed {
            if localizedRuleSets.isEmpty {
                route.removeValue(forKey: "rule_set")
            } else {
                route["rule_set"] = localizedRuleSets
            }
            json["route"] = route

            let availableTags = Set(localizedRuleSets.compactMap { item -> String? in
                if let text = item as? String, !text.isEmpty { return text }
                if let dict = item as? [String: Any], let tag = dict["tag"] as? String, !tag.isEmpty { return tag }
                return nil
            })

            if let routeRules = (json["route"] as? [String: Any])?["rules"] as? [[String: Any]],
               var routeRoot = json["route"] as? [String: Any] {
                routeRoot["rules"] = routeRules.filter { rule in
                    guard let dependency = rule["rule_set"] else { return true }
                    let tags = normalizeRuleSetTags(dependency)
                    if tags.isEmpty { return true }
                    return tags.allSatisfy { availableTags.contains($0) }
                }
                json["route"] = routeRoot
            }
            if var dns = json["dns"] as? [String: Any], let dnsRules = dns["rules"] as? [[String: Any]] {
                dns["rules"] = dnsRules.filter { rule in
                    guard let dependency = rule["rule_set"] else { return true }
                    let tags = normalizeRuleSetTags(dependency)
                    if tags.isEmpty { return true }
                    return tags.allSatisfy { availableTags.contains($0) }
                }
                json["dns"] = dns
            }
        }

        guard let output = try? JSONSerialization.data(withJSONObject: json, options: []),
              let text = String(data: output, encoding: .utf8) else {
            return configContent
        }
        let localizedCount = localizedRuleSets.compactMap { item -> String? in
            if let dict = item as? [String: Any], let type = dict["type"] as? String, type == "local" {
                return dict["tag"] as? String
            }
            return nil
        }.count
        lastRuntimeDiagnostics["ruleset_mode"] = "localized"
        lastRuntimeDiagnostics["ruleset_local_count"] = String(localizedCount)
        lastRuntimeDiagnostics["ruleset_downloaded_count"] = String(downloadedTags.count)
        lastRuntimeDiagnostics["ruleset_cached_count"] = String(cachedTags.count)
        lastRuntimeDiagnostics["ruleset_removed_count"] = String(removedRemoteTags.count)
        if !removedRemoteTags.isEmpty {
            let removedText = removedRemoteTags.joined(separator: ",")
            lastRuntimeDiagnostics["ruleset_removed_tags"] = removedText
            SharedTunnelEventStore.appendDiagnostic(
                "ruleset localize removed tags=\(removedText)"
            )
        } else {
            lastRuntimeDiagnostics["ruleset_removed_tags"] = ""
        }
        return text
    }

    private func ensureLocalRuleSetDirectory() -> URL {
        let baseURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.gemod.Gemod")?
            .appendingPathComponent("rulesets", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("rulesets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        }
        return baseURL
    }

    private func localRuleSetFileName(for tag: String) -> String {
        let sanitized = tag.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let text = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if text.isEmpty {
            return "ruleset.srs"
        }
        return "\(text).srs"
    }

    private func downloadRuleSetData(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 6.0)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    private func shouldRetryWithLocalRuleSetFallback(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("initialize rule-set")
            || lower.contains("initial rule-set")
            || lower.contains("rule-set not found")
            || (lower.contains("rule-set") && lower.contains("timed out"))
            || (lower.contains("rule-set") && lower.contains("disconnected"))
    }

    private func buildLocalRuleSetFallbackConfig(from configContent: String) -> String? {
        guard let data = configContent.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var route = json["route"] as? [String: Any] else {
            return nil
        }

        let originalRuleSets = (route["rule_set"] as? [Any]) ?? []
        var removedTags = Set<String>()
        var keptRuleSets: [Any] = []
        for item in originalRuleSets {
            if let dict = item as? [String: Any] {
                let type = (dict["type"] as? String)?.lowercased() ?? ""
                let tag = (dict["tag"] as? String) ?? ""
                if type == "remote" {
                    if !tag.isEmpty { removedTags.insert(tag) }
                    continue
                }
                keptRuleSets.append(dict)
                if !tag.isEmpty { removedTags.remove(tag) }
            } else if let tag = item as? String {
                keptRuleSets.append(tag)
            }
        }

        guard !removedTags.isEmpty else { return nil }
        let availableTags = Set(keptRuleSets.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let dict = item as? [String: Any] { return dict["tag"] as? String }
            return nil
        })

        if keptRuleSets.isEmpty {
            route.removeValue(forKey: "rule_set")
        } else {
            route["rule_set"] = keptRuleSets
        }

        if let rules = route["rules"] as? [[String: Any]] {
            route["rules"] = rules.filter { rule in
                guard let dependency = rule["rule_set"] else { return true }
                let tags = normalizeRuleSetTags(dependency)
                if tags.isEmpty { return true }
                if tags.contains(where: { removedTags.contains($0) }) { return false }
                return tags.allSatisfy { availableTags.contains($0) }
            }
        }
        json["route"] = route

        if var dns = json["dns"] as? [String: Any], let dnsRules = dns["rules"] as? [[String: Any]] {
            dns["rules"] = dnsRules.filter { rule in
                guard let dependency = rule["rule_set"] else { return true }
                let tags = normalizeRuleSetTags(dependency)
                if tags.isEmpty { return true }
                if tags.contains(where: { removedTags.contains($0) }) { return false }
                return tags.allSatisfy { availableTags.contains($0) }
            }
            json["dns"] = dns
        }

        guard let fallbackData = try? JSONSerialization.data(withJSONObject: json, options: []),
              let fallbackText = String(data: fallbackData, encoding: .utf8) else {
            return nil
        }
        SharedTunnelEventStore.appendDiagnostic(
            "local-rule_set fallback removed remote tags=\(removedTags.sorted().joined(separator: ","))"
        )
        return fallbackText
    }

    private func ensureLibboxSetup() throws {
        guard !setupFinished else { return }
        let baseURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.gemod.Gemod")?
            .appendingPathComponent("singbox-runtime", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("singbox-runtime", isDirectory: true)
        let workingURL = baseURL.appendingPathComponent("working", isDirectory: true)
        let tempURL = baseURL.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: workingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

        let options = LibboxSetupOptions()
        options.basePath = baseURL.path
        options.workingPath = workingURL.path
        options.tempPath = tempURL.path
        let candidates = [
            NSUserName(),
            ProcessInfo.processInfo.environment["USER"] ?? "",
            "mobile",
            ""
        ]
        var triedUsernames: [String] = []
        var lastSetupError: NSError?
        for candidate in candidates where !triedUsernames.contains(candidate) {
            triedUsernames.append(candidate)
            options.username = candidate
            var setupError: NSError?
            LibboxSetup(options, &setupError)
            if let setupError {
                lastSetupError = setupError
                let label = candidate.isEmpty ? "<empty>" : candidate
                SharedTunnelEventStore.appendDiagnostic("libbox setup retry username=\(label) failed: \(setupError.localizedDescription)")
                continue
            }
            setupFinished = true
            let label = candidate.isEmpty ? "<empty>" : candidate
            SharedTunnelEventStore.appendDiagnostic("libbox setup done username=\(label)")
            return
        }
        throw lastSetupError ?? NSError(domain: "GemodLibboxSetup", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "libbox setup failed with all username candidates"
        ])
    }

    private func buildConfig(node: String, mode: String, subscriptionContent: String?) -> String {
        let normalizedNode = node.trimmingCharacters(in: .whitespacesAndNewlines)
        lastRuntimeDiagnostics["active_node"] = normalizedNode
        lastRuntimeDiagnostics["active_mode"] = mode.lowercased()
        lastRuntimeDiagnostics["active_transport"] = "tun"
        lastRuntimeDiagnostics["regression_stage"] = "fixed"
        if let raw = subscriptionContent?.trimmingCharacters(in: .whitespacesAndNewlines),
           let built = buildConfigFromSubscription(raw, selectedNode: node, mode: mode) {
            SharedTunnelEventStore.appendDiagnostic("libbox config built from subscription")
            return built
        }
        lastRuntimeDiagnostics["config_source"] = "bootstrap"
        lastRuntimeDiagnostics["route_final"] = mode.lowercased() == "global" ? (normalizedNode.isEmpty ? "direct" : normalizedNode) : "direct"
        lastRuntimeDiagnostics["active_outbound"] = normalizedNode.isEmpty ? "direct" : normalizedNode
        lastRuntimeDiagnostics["active_outbound_type"] = "selector"
        lastRuntimeDiagnostics["active_server"] = "-"
        lastRuntimeDiagnostics["active_port"] = "-"
        lastRuntimeDiagnostics["active_tls"] = "unknown"
        lastRuntimeDiagnostics["active_sni"] = "-"
        lastRuntimeDiagnostics["active_alpn"] = "-"
        return buildBootstrapConfig(node: node, mode: mode)
    }

    private func buildBootstrapConfig(node: String, mode: String) -> String {
        let outboundTag = node.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "direct" : node
        let modeLower = mode.lowercased()
        let routeFinal = modeLower == "global" ? outboundTag : "direct"
        let config: [String: Any] = [
            "log": [
                "level": "info"
            ],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:9090"
                ]
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "stack": "gvisor",
                    "address": [
                        "10.8.0.2/24"
                    ],
                    "mtu": 1500,
                    "auto_route": true,
                    "strict_route": false,
                    "sniff": true
                ]
            ],
            "outbounds": [
                [
                    "type": "direct",
                    "tag": "direct"
                ],
                [
                    "type": "block",
                    "tag": "block"
                ],
                [
                    "type": "selector",
                    "tag": outboundTag,
                    "outbounds": ["direct"]
                ]
            ],
            "route": [
                "auto_detect_interface": false,
                "final": routeFinal
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: config, options: []),
           let text = String(data: data, encoding: .utf8) {
            SharedTunnelEventStore.appendDiagnostic(
                "libbox bootstrap config generated mode=\(mode) node=\(outboundTag)"
            )
            return text
        }
        return #"{"log":{"level":"info"},"experimental":{"clash_api":{"external_controller":"127.0.0.1:9090"}},"inbounds":[{"type":"tun","tag":"tun-in","stack":"gvisor","auto_route":true,"strict_route":false}],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"auto_detect_interface":false,"final":"direct"}}"#
    }

    private func buildConfigFromSubscription(_ raw: String, selectedNode: String, mode: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let sourceOutbounds = json["outbounds"] as? [[String: Any]], !sourceOutbounds.isEmpty else {
            return nil
        }
        let proxyOutbounds = extractProxyOutbounds(from: sourceOutbounds)
        guard !proxyOutbounds.isEmpty else {
            SharedTunnelEventStore.appendDiagnostic("subscription contains no usable proxy outbounds")
            return nil
        }
        let bootstrapDomains = extractProxyServerDomains(from: proxyOutbounds)
        if !bootstrapDomains.isEmpty {
            SharedTunnelEventStore.appendDiagnostic("bootstrap dns domains prepared count=\(bootstrapDomains.count)")
        }
        let selected = selectedNode.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSelected: String = {
            if !selected.isEmpty,
               proxyOutbounds.contains(where: { ($0["tag"] as? String) == selected }) {
                return selected
            }
            return (proxyOutbounds.first?["tag"] as? String) ?? selected
        }()

        let droppedCount = max(0, sourceOutbounds.count - proxyOutbounds.count)
        if droppedCount > 0 {
            SharedTunnelEventStore.appendDiagnostic(
                "subscription normalized: keep proxy outbounds=\(proxyOutbounds.count), dropped non-proxy/group=\(droppedCount)"
            )
        }
        lastRuntimeDiagnostics["config_input_mode"] = "proxies-only"
        lastRuntimeDiagnostics["config_input_proxy_count"] = String(proxyOutbounds.count)

        return buildMinimalConnectivityConfig(
            allOutbounds: proxyOutbounds,
            selectedTag: effectiveSelected,
            mode: mode,
            bootstrapDomains: bootstrapDomains
        )
    }

    private func buildMinimalConnectivityConfig(
        allOutbounds: [[String: Any]],
        selectedTag: String,
        mode: String,
        bootstrapDomains: [String]
    ) -> String? {
        guard let selectedOutbound = allOutbounds.first(where: { ($0["tag"] as? String) == selectedTag }) else {
            return nil
        }
        updateRuntimeDiagnostics(
            selectedOutbound: selectedOutbound,
            selectedTag: selectedTag,
            configSource: "subscription-proxies-only",
            routeFinal: selectedTag
        )

        var outbounds: [[String: Any]] = []
        var seenTags = Set<String>()
        // Place selected outbound first for predictable behavior.
        outbounds.append(selectedOutbound)
        seenTags.insert(selectedTag)

        for outbound in allOutbounds {
            guard let tag = outbound["tag"] as? String, !tag.isEmpty else { continue }
            guard !seenTags.contains(tag) else { continue }
            outbounds.append(outbound)
            seenTags.insert(tag)
        }

        if !seenTags.contains("direct") {
            outbounds.append(["type": "direct", "tag": "direct"])
            seenTags.insert("direct")
        }
        if !seenTags.contains("block") {
            outbounds.append(["type": "block", "tag": "block"])
            seenTags.insert("block")
        }
        if !seenTags.contains("dns-out") {
            outbounds.append(["type": "dns", "tag": "dns-out"])
            seenTags.insert("dns-out")
        }

        let selectableTags = outbounds.compactMap { outbound -> String? in
            guard let tag = outbound["tag"] as? String, !tag.isEmpty else { return nil }
            guard let type = (outbound["type"] as? String)?.lowercased() else { return nil }
            if type == "direct" || type == "block" || type == "dns" || type == "selector" {
                return nil
            }
            return tag
        }
        if !selectableTags.isEmpty {
            let selector: [String: Any] = [
                "type": "selector",
                "tag": activeSelectorTag,
                "outbounds": selectableTags,
                "default": selectedTag,
                "interrupt_exist_connections": true
            ]
            outbounds.append(selector)
            seenTags.insert(activeSelectorTag)
        }

        lastRuntimeDiagnostics["latency_test_url"] = "https://www.google.com.hk"

        outbounds = applySelectorDefault(outbounds: outbounds, selectedNode: selectedTag)
        let selectedPathTag = selectableTags.isEmpty ? selectedTag : activeSelectorTag
        let proxyLikeTags = collectProxyLikeOutboundTags(from: outbounds)
        let isRuleMode = mode.lowercased() == "rule"
        lastRuntimeDiagnostics["regression_stage"] = "fixed"
        let dnsConfig: [String: Any]
        let routeConfig: [String: Any]
        var mutableDNS: [String: Any] = [
            "servers": [
                ["tag": "gemod-dns-remote", "address": "https://1.1.1.1/dns-query", "detour": selectedPathTag],
                ["tag": "gemod-dns-local", "address": "local", "detour": "direct"]
            ],
            "final": "gemod-dns-remote",
            "independent_cache": true
        ]
        ensureBootstrapDomainDNSRule(
            &mutableDNS,
            domains: bootstrapDomains,
            directServerTag: "gemod-dns-local"
        )
        ensureManagedDNSRules(&mutableDNS, enableRuleMode: isRuleMode)
        normalizeDNSServerDetoursToSelectedPath(&mutableDNS, selectedPathTag: selectedPathTag, proxyLikeTags: proxyLikeTags)
        dnsConfig = mutableDNS

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["action": "hijack-dns", "protocol": "dns"],
            ["action": "route", "port": 53, "outbound": "dns-out"]
        ]
        if isRuleMode {
            // Exception first: Alibaba main site must follow proxy path.
            routeRules.append(["domain_suffix": ["alibaba.com"], "outbound": selectedPathTag])
            routeRules.append(["rule_set": ["geosite-cn", "geosite-private", "geosite-apple", "geosite-icloud"], "outbound": "direct"])
            routeRules.append(["domain_suffix": ["amazon.cn"], "outbound": "direct"])
            routeRules.append(["domain_suffix": ["678ceo.com", "gemod.net"], "outbound": "direct"])
            routeRules.append(["rule_set": ["geoip-cn", "geoip-private"], "outbound": "direct"])
            routeRules.append(["ip_is_private": true, "outbound": "direct"])
        }
        var mutableRoute: [String: Any] = [
            "auto_detect_interface": false,
            "rules": routeRules,
            "final": selectedPathTag
        ]
        if isRuleMode {
            mutableRoute["rule_set"] = managedRuleSetEntries()
            lastRuntimeDiagnostics["route_rules_mode"] = "gemod-managed-rule"
        } else {
            lastRuntimeDiagnostics["route_rules_mode"] = "gemod-managed-global"
        }
        lastRuntimeDiagnostics["route_rules_count"] = String(routeRules.count)
        normalizeRouteOutboundsToSelectedPath(&mutableRoute, selectedPathTag: selectedPathTag, proxyLikeTags: proxyLikeTags)
        ensureDNSOutboundRouteRule(&mutableRoute)
        routeConfig = mutableRoute

        let config: [String: Any] = [
            "log": [
                "level": "info"
            ],
            "dns": dnsConfig,
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "stack": "gvisor",
                "address": ["10.8.0.2/24"],
                "mtu": 1500,
                "auto_route": true,
                "strict_route": false,
                "sniff": true
            ]],
            "outbounds": outbounds,
            "route": routeConfig,
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:9090"
                ]
            ]
        ]
        var sanitizedConfig = config
        simplifyDNSConfiguration(&sanitizedConfig)
        updateRuntimePathDiagnostics(
            config: sanitizedConfig,
            selectedTag: selectedTag,
            selectedPathTag: selectedPathTag
        )
        guard let output = try? JSONSerialization.data(withJSONObject: sanitizedConfig, options: []),
              let text = String(data: output, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func extractProxyOutbounds(from outbounds: [[String: Any]]) -> [[String: Any]] {
        let proxyTypes: Set<String> = [
            "shadowsocks", "vmess", "vless", "trojan", "hysteria", "hysteria2",
            "tuic", "wireguard", "ssh", "socks", "http", "anytls", "shadowtls"
        ]
        return outbounds.filter { outbound in
            guard let tag = outbound["tag"] as? String, !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            let type = (outbound["type"] as? String)?.lowercased() ?? ""
            return proxyTypes.contains(type)
        }
    }

    private func extractProxyServerDomains(from outbounds: [[String: Any]]) -> [String] {
        var domains = Set<String>()
        for outbound in outbounds {
            guard let server = outbound["server"] as? String else { continue }
            let host = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !host.isEmpty else { continue }
            // Skip literal IPs; bootstrap rule is only for domain-based nodes.
            if isIPv4Literal(host) || host.contains(":") {
                continue
            }
            domains.insert(host)
        }
        return domains.sorted()
    }

    private func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let num = Int(part), num >= 0, num <= 255 else {
                return false
            }
        }
        return true
    }

    private func ensureManagedDNSRules(_ dns: inout [String: Any], enableRuleMode: Bool) {
        guard enableRuleMode else { return }
        var rules = dns["rules"] as? [[String: Any]] ?? []
        rules.removeAll { rule in
            if let suffix = rule["domain_suffix"] as? [String], suffix.contains("alibaba.com") {
                return true
            }
            if let suffix = rule["domain_suffix"] as? [String], suffix.contains("678ceo.com") || suffix.contains("gemod.net") {
                return true
            }
            if let ruleSet = rule["rule_set"] as? [String],
               ruleSet.contains("geosite-cn") || ruleSet.contains("geosite-private") || ruleSet.contains("geosite-apple") || ruleSet.contains("geosite-icloud") {
                return true
            }
            return false
        }
        let managedRules: [[String: Any]] = [
            ["domain_suffix": ["alibaba.com"], "server": "gemod-dns-remote"],
            ["rule_set": ["geosite-cn", "geosite-private", "geosite-apple", "geosite-icloud"], "server": "gemod-dns-local"],
            ["domain_suffix": ["amazon.cn"], "server": "gemod-dns-local"],
            ["domain_suffix": ["678ceo.com", "gemod.net"], "server": "gemod-dns-local"]
        ]
        rules.append(contentsOf: managedRules)
        dns["rules"] = rules
    }

    private func managedRuleSetEntries() -> [[String: Any]] {
        [
            ["type": "remote", "tag": "geosite-cn", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", "format": "binary"],
            ["type": "remote", "tag": "geosite-private", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-private.srs", "format": "binary"],
            ["type": "remote", "tag": "geosite-apple", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-apple.srs", "format": "binary"],
            ["type": "remote", "tag": "geosite-icloud", "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-icloud.srs", "format": "binary"],
            ["type": "remote", "tag": "geoip-cn", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", "format": "binary"],
            ["type": "remote", "tag": "geoip-private", "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-private.srs", "format": "binary"]
        ]
    }

    private func ensureBootstrapDomainDNSRule(
        _ dns: inout [String: Any],
        domains: [String],
        directServerTag: String
    ) {
        guard !domains.isEmpty else { return }
        var rules = dns["rules"] as? [[String: Any]] ?? []
        rules.removeAll { rule in
            guard let server = rule["server"] as? String else { return false }
            guard server == directServerTag else { return false }
            return rule["domain"] != nil
        }
        rules.insert([
            "domain": domains,
            "server": directServerTag
        ], at: 0)
        dns["rules"] = rules
        SharedTunnelEventStore.appendDiagnostic("dns bootstrap rule injected domains=\(domains.count) server=\(directServerTag)")
    }

    private func collectProxyLikeOutboundTags(from outbounds: [[String: Any]]) -> Set<String> {
        var tags: Set<String> = ["proxy", "select", "auto"]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, !tag.isEmpty else { continue }
            let type = (outbound["type"] as? String)?.lowercased() ?? ""
            if type == "selector" || type == "urltest" {
                tags.insert(tag)
            }
        }
        return tags
    }

    private func normalizeDNSServerDetoursToSelectedPath(
        _ dns: inout [String: Any],
        selectedPathTag: String,
        proxyLikeTags: Set<String>
    ) {
        guard var servers = dns["servers"] as? [[String: Any]] else { return }
        var changed = false
        for index in servers.indices {
            var server = servers[index]
            if let detour = server["detour"] as? String, proxyLikeTags.contains(detour) {
                server["detour"] = selectedPathTag
                servers[index] = server
                changed = true
            }
        }
        if changed {
            dns["servers"] = servers
            SharedTunnelEventStore.appendDiagnostic(
                "dns server detour remapped to selected path tag=\(selectedPathTag)"
            )
        }
    }

    private func normalizeRouteOutboundsToSelectedPath(
        _ route: inout [String: Any],
        selectedPathTag: String,
        proxyLikeTags: Set<String>
    ) {
        guard var rules = route["rules"] as? [[String: Any]] else { return }
        var changed = false
        for index in rules.indices {
            var rule = rules[index]
            if let outbound = rule["outbound"] as? String, proxyLikeTags.contains(outbound) {
                rule["outbound"] = selectedPathTag
                rules[index] = rule
                changed = true
            }
        }
        if changed {
            route["rules"] = rules
            SharedTunnelEventStore.appendDiagnostic(
                "route outbound remapped to selected path tag=\(selectedPathTag)"
            )
        }
    }

    private func ensureDNSOutboundRouteRule(_ route: inout [String: Any]) {
        var rules = route["rules"] as? [[String: Any]] ?? []
        let exists = rules.contains { rule in
            let action = (rule["action"] as? String)?.lowercased()
            let outbound = (rule["outbound"] as? String)?.lowercased()
            if action == "route" && outbound == "dns-out" {
                if let port = rule["port"] as? Int { return port == 53 }
                if let portText = rule["port"] as? String { return portText == "53" }
            }
            return false
        }
        if !exists {
            rules.append(["action": "route", "port": 53, "outbound": "dns-out"])
            route["rules"] = rules
            lastRuntimeDiagnostics["route_rules_count"] = String(rules.count)
            SharedTunnelEventStore.appendDiagnostic("route rules append dns-out for port 53")
        }
    }

    private func updateRuntimePathDiagnostics(
        config: [String: Any],
        selectedTag: String,
        selectedPathTag: String
    ) {
        lastRuntimeDiagnostics["selected_node"] = selectedTag
        lastRuntimeDiagnostics["selected_path"] = selectedPathTag

        if let route = config["route"] as? [String: Any] {
            let final = (route["final"] as? String) ?? "-"
            lastRuntimeDiagnostics["route_final"] = final
            if lastRuntimeDiagnostics["route_rules_count"] == nil,
               let rules = route["rules"] as? [Any] {
                lastRuntimeDiagnostics["route_rules_count"] = String(rules.count)
            }
            if lastRuntimeDiagnostics["route_rules_mode"] == nil {
                lastRuntimeDiagnostics["route_rules_mode"] = "subscription"
            }
        }

        if let dns = config["dns"] as? [String: Any] {
            let final = (dns["final"] as? String) ?? "-"
            lastRuntimeDiagnostics["dns_final"] = final
            let servers = dns["servers"] as? [Any] ?? []
            lastRuntimeDiagnostics["dns_servers"] = summarizeDNSServers(servers)
            lastRuntimeDiagnostics["dns_rule_servers"] = summarizeDNSRuleServers(dns["rules"] as? [Any] ?? [])
            lastRuntimeDiagnostics["dns_probe_targets"] = summarizeDNSProbeTargets(servers)
        } else {
            lastRuntimeDiagnostics["dns_final"] = "-"
            lastRuntimeDiagnostics["dns_servers"] = "-"
            lastRuntimeDiagnostics["dns_rule_servers"] = "-"
            lastRuntimeDiagnostics["dns_probe_targets"] = "-"
        }
    }

    private func summarizeDNSServers(_ servers: [Any]) -> String {
        let summary = servers.compactMap { item -> String? in
            guard let server = item as? [String: Any] else { return nil }
            let tag = (server["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detour = (server["detour"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (tag?.isEmpty == false ? tag! : maskDNSAddress((server["address"] as? String) ?? "-"))
            let path = (detour?.isEmpty == false ? detour! : "-")
            return "\(name)@\(path)"
        }
        return summary.isEmpty ? "-" : summary.joined(separator: ",")
    }

    private func summarizeDNSRuleServers(_ rules: [Any]) -> String {
        var values: [String] = []
        for item in rules {
            guard let rule = item as? [String: Any] else { continue }
            if let server = rule["server"] as? String, !server.isEmpty, !values.contains(server) {
                values.append(server)
            }
        }
        return values.isEmpty ? "-" : values.joined(separator: ",")
    }

    private func summarizeDNSProbeTargets(_ servers: [Any]) -> String {
        let summary = servers.compactMap { item -> String? in
            guard let server = item as? [String: Any] else { return nil }
            let address = (server["address"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard address.hasPrefix("https://") else { return nil }
            let rawTag = (server["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tag = rawTag.isEmpty ? "untagged" : rawTag
            let detour = (server["detour"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
            return "\(tag)|\(detour)|\(address)"
        }
        return summary.isEmpty ? "-" : summary.joined(separator: ",")
    }

    private func updateRuntimeDiagnostics(
        selectedOutbound: [String: Any],
        selectedTag: String,
        configSource: String,
        routeFinal: String
    ) {
        let type = (selectedOutbound["type"] as? String) ?? "unknown"
        let server = maskHost((selectedOutbound["server"] as? String) ?? "-")
        let port: String = {
            if let intPort = selectedOutbound["server_port"] as? Int { return String(intPort) }
            if let strPort = selectedOutbound["server_port"] as? String { return strPort }
            if let intPort = selectedOutbound["port"] as? Int { return String(intPort) }
            if let strPort = selectedOutbound["port"] as? String { return strPort }
            return "-"
        }()
        let tls = (selectedOutbound["tls"] as? [String: Any]) ?? [:]
        let tlsEnabled: String = {
            if let enabled = tls["enabled"] as? Bool { return enabled ? "true" : "false" }
            if tls.isEmpty { return "false" }
            return "true"
        }()
        let sni = maskHost((tls["server_name"] as? String) ?? (selectedOutbound["sni"] as? String) ?? "-")
        let alpnValue: String = {
            if let list = tls["alpn"] as? [String], !list.isEmpty {
                return list.joined(separator: ",")
            }
            if let value = tls["alpn"] as? String, !value.isEmpty {
                return value
            }
            return "-"
        }()

        lastRuntimeDiagnostics["config_source"] = configSource
        lastRuntimeDiagnostics["route_final"] = routeFinal
        lastRuntimeDiagnostics["active_outbound"] = selectedTag
        lastRuntimeDiagnostics["active_outbound_type"] = type
        lastRuntimeDiagnostics["active_server"] = server
        lastRuntimeDiagnostics["active_port"] = port
        lastRuntimeDiagnostics["active_tls"] = tlsEnabled
        lastRuntimeDiagnostics["active_sni"] = sni
        lastRuntimeDiagnostics["active_alpn"] = alpnValue

        SharedTunnelEventStore.appendDiagnostic(
            "libbox outbound diag source=\(configSource) tag=\(selectedTag) type=\(type) server=\(server):\(port) tls=\(tlsEnabled) sni=\(sni) alpn=\(alpnValue)"
        )
    }

    private func maskDNSAddress(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "-" }
        if text == "local" { return "local" }
        if let url = URL(string: text), let host = url.host {
            return maskHost(host)
        }
        return maskHost(text)
    }

    private func maskHost(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "-" else { return "-" }
        if text.contains(":") || text.contains(".") {
            let parts = text.split(separator: ".")
            if parts.count >= 2 {
                let suffix = parts.suffix(2).joined(separator: ".")
                return "***." + suffix
            }
        }
        if text.count <= 6 { return "***" }
        return "\(text.prefix(3))***\(text.suffix(2))"
    }

    private func simplifyDNSConfiguration(_ json: inout [String: Any]) {
        var dns = (json["dns"] as? [String: Any]) ?? [:]
        var servers = (dns["servers"] as? [Any]) ?? []
        let availableRuleSets = extractAvailableRouteRuleSetTags(json)
        let nonFakeServers = servers.filter { !isFakeIPServer($0) }
        let fakeServers = servers.filter { isFakeIPServer($0) }
        if nonFakeServers.isEmpty {
            // Keep startup stable while avoiding a direct-only DNS fallback.
            servers = [
                [
                    "tag": "gemod-dns-remote",
                    "address": "https://1.1.1.1/dns-query"
                ],
                [
                    "tag": "gemod-dns-local",
                    "address": "local"
                ]
            ] + fakeServers
        } else {
            servers = nonFakeServers + fakeServers
        }
        dns["servers"] = servers

        if let finalTag = dns["final"] as? String {
            let valid = servers.contains { entry in
                guard let item = entry as? [String: Any], let tag = item["tag"] as? String else { return false }
                return tag == finalTag
            }
            if !valid || finalTag.lowercased().contains("fakeip") {
                if let firstTag = firstEncryptedNonFakeDNSTag(in: servers) ?? firstNonFakeDNSTag(in: servers) {
                    dns["final"] = firstTag
                } else {
                    dns.removeValue(forKey: "final")
                }
            }
        } else if let firstTag = firstEncryptedNonFakeDNSTag(in: servers) ?? firstNonFakeDNSTag(in: servers) {
            dns["final"] = firstTag
        }

        if let rules = dns["rules"] as? [[String: Any]], !rules.isEmpty {
            var removed = 0
            dns["rules"] = rules.filter { rule in
                let shouldRemove = dnsRuleDependsOnMissingRuleSet(rule, availableRuleSets: availableRuleSets)
                if shouldRemove { removed += 1 }
                return !shouldRemove
            }
            if removed > 0 {
                SharedTunnelEventStore.appendDiagnostic(
                    "dns rule_set dependency cleanup removed=\(removed) available=\(availableRuleSets.count)"
                )
            }
        }

        dns["independent_cache"] = true
        json["dns"] = dns
    }

    private func extractAvailableRouteRuleSetTags(_ json: [String: Any]) -> Set<String> {
        guard let route = json["route"] as? [String: Any],
              let ruleSets = route["rule_set"] as? [Any] else {
            return []
        }
        var tags = Set<String>()
        for item in ruleSets {
            if let text = item as? String, !text.isEmpty {
                tags.insert(text)
                continue
            }
            if let dict = item as? [String: Any],
               let tag = dict["tag"] as? String,
               !tag.isEmpty {
                tags.insert(tag)
            }
        }
        return tags
    }

    private func dnsRuleDependsOnMissingRuleSet(
        _ rule: [String: Any],
        availableRuleSets: Set<String>
    ) -> Bool {
        guard let value = rule["rule_set"] else { return false }
        let tags = normalizeRuleSetTags(value)
        if tags.isEmpty { return false }
        return tags.contains { !availableRuleSets.contains($0) }
    }

    private func normalizeRuleSetTags(_ raw: Any) -> [String] {
        if let text = raw as? String {
            return text.isEmpty ? [] : [text]
        }
        if let list = raw as? [String] {
            return list.filter { !$0.isEmpty }
        }
        if let list = raw as? [Any] {
            return list.compactMap { item in
                if let text = item as? String, !text.isEmpty {
                    return text
                }
                if let number = item as? NSNumber {
                    let text = number.stringValue
                    return text.isEmpty ? nil : text
                }
                return nil
            }
        }
        if let number = raw as? NSNumber {
            let text = number.stringValue
            return text.isEmpty ? [] : [text]
        }
        return []
    }

    private func firstNonFakeDNSTag(in servers: [Any]) -> String? {
        for entry in servers {
            guard let item = entry as? [String: Any] else { continue }
            let tag = (item["tag"] as? String) ?? ""
            if !tag.isEmpty && !tag.lowercased().contains("fakeip") {
                return tag
            }
        }
        return nil
    }

    private func firstEncryptedNonFakeDNSTag(in servers: [Any]) -> String? {
        for entry in servers {
            guard let item = entry as? [String: Any] else { continue }
            let tag = (item["tag"] as? String) ?? ""
            guard !tag.isEmpty else { continue }
            if isFakeIPServer(entry) { continue }
            guard isEncryptedDNSServer(entry) else { continue }
            return tag
        }
        return nil
    }

    private func isEncryptedDNSServer(_ server: Any) -> Bool {
        let address: String
        if let text = server as? String {
            address = text.lowercased()
        } else if let dict = server as? [String: Any] {
            address = ((dict["address"] as? String) ?? "").lowercased()
        } else {
            return false
        }
        return address.hasPrefix("https://")
            || address.hasPrefix("tls://")
            || address.hasPrefix("quic://")
            || address.hasPrefix("h3://")
    }

    private func isFakeIPServer(_ server: Any) -> Bool {
        if let text = server as? String {
            return text.lowercased().contains("fakeip")
        }
        if let dict = server as? [String: Any] {
            let tag = (dict["tag"] as? String)?.lowercased() ?? ""
            let address = (dict["address"] as? String)?.lowercased() ?? ""
            return tag.contains("fakeip") || address.contains("fakeip")
        }
        return false
    }

    private func applySelectorDefault(outbounds: [[String: Any]], selectedNode: String) -> [[String: Any]] {
        guard !selectedNode.isEmpty else { return outbounds }
        return outbounds.map { outbound in
            guard let type = outbound["type"] as? String, type.lowercased() == "selector" else {
                return outbound
            }
            guard let candidates = outbound["outbounds"] as? [String], candidates.contains(selectedNode) else {
                return outbound
            }
            var next = outbound
            next["default"] = selectedNode
            return next
        }
    }
    #endif
}

#if canImport(Libbox)
private final class GemodLibboxPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var tunnelProvider: PacketTunnelProvider?

    init(tunnelProvider: PacketTunnelProvider?) {
        self.tunnelProvider = tunnelProvider
    }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -10, userInfo: [NSLocalizedDescriptionKey: "openTun options is nil"])
        }
        guard let tunnelProvider else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -11, userInfo: [NSLocalizedDescriptionKey: "openTun tunnelProvider is nil"])
        }
        guard let ret0_ else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -1, userInfo: [NSLocalizedDescriptionKey: "openTun ret pointer is nil"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        if let dnsAddress = try? options.getDNSServerAddress().value, !dnsAddress.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: [dnsAddress])
        } else {
            settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
        }

        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        if let iterator = options.getInet4Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { continue }
                ipv4Addresses.append(prefix.address())
                ipv4Masks.append(prefix.mask())
            }
        }
        if ipv4Addresses.isEmpty {
            ipv4Addresses = ["10.8.0.2"]
            ipv4Masks = ["255.255.255.0"]
        }
        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)

        var includedRoutes: [NEIPv4Route] = []
        if let iterator = options.getInet4RouteAddress(), iterator.hasNext() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { continue }
                includedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        } else {
            includedRoutes = [NEIPv4Route.default()]
        }
        ipv4Settings.includedRoutes = includedRoutes

        var excludedRoutes: [NEIPv4Route] = []
        if let iterator = options.getInet4RouteExcludeAddress() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { continue }
                excludedRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        }
        if !excludedRoutes.isEmpty {
            ipv4Settings.excludedRoutes = excludedRoutes
        }

        settings.ipv4Settings = ipv4Settings

        var ipv6Addresses: [String] = []
        var ipv6PrefixLengths: [NSNumber] = []
        if let iterator = options.getInet6Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { continue }
                ipv6Addresses.append(prefix.address())
                ipv6PrefixLengths.append(NSNumber(value: prefix.prefix()))
            }
        }
        if !ipv6Addresses.isEmpty {
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6PrefixLengths)

            var included6: [NEIPv6Route] = []
            if let iterator = options.getInet6RouteAddress(), iterator.hasNext() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    included6.append(
                        NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        )
                    )
                }
            } else {
                included6 = [NEIPv6Route.default()]
            }
            ipv6Settings.includedRoutes = included6

            var excluded6: [NEIPv6Route] = []
            if let iterator = options.getInet6RouteExcludeAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { continue }
                    excluded6.append(
                        NEIPv6Route(
                            destinationAddress: prefix.address(),
                            networkPrefixLength: NSNumber(value: prefix.prefix())
                        )
                    )
                }
            }
            if !excluded6.isEmpty {
                ipv6Settings.excludedRoutes = excluded6
            }

            settings.ipv6Settings = ipv6Settings
        }

        try runBlocking {
            try await tunnelProvider.setTunnelNetworkSettingsAsync(settings)
        }

        if let tunFd = tunnelProvider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            SharedTunnelEventStore.appendDiagnostic("openTun using packetFlow fd=\(tunFd)")
            ret0_.pointee = tunFd
            return
        }

        let tunFd = LibboxGetTunnelFileDescriptor()
        if tunFd == -1 {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -2, userInfo: [NSLocalizedDescriptionKey: "openTun missing tunnel file descriptor"])
        }
        SharedTunnelEventStore.appendDiagnostic("openTun using libbox fd=\(tunFd)")
        ret0_.pointee = tunFd
    }

    func underNetworkExtension() -> Bool { true }
    func useProcFS() -> Bool { false }
    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_ fd: Int32) throws { _ = fd }
    func includeAllNetworks() -> Bool { false }
    func clearDNSCache() {}
    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws { _ = listener }
    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws { _ = listener }
    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol { EmptyNetworkInterfaceIterator() }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }
    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32,
        ret0_: UnsafeMutablePointer<Int32>?
    ) throws {
        _ = (ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
        ret0_?.pointee = -1
        throw NSError(domain: "GemodLibboxPlatformInterface", code: -3, userInfo: [NSLocalizedDescriptionKey: "findConnectionOwner is not implemented"])
    }
    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String {
        _ = uid
        return ""
    }
    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        _ = packageName
        ret0_?.pointee = -1
    }
    func systemCertificates() -> LibboxStringIteratorProtocol? { EmptyStringIterator() }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func send(_ notification: LibboxNotification?) throws { _ = notification }
    func writeLog(_ message: String?) {
        guard let message else { return }
        SharedTunnelEventStore.appendDiagnostic("libbox: \(message)")
    }

    private func runBlocking(_ operation: @escaping () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error?
        Task {
            defer { semaphore.signal() }
            do {
                try await operation()
            } catch {
                capturedError = error
            }
        }
        semaphore.wait()
        if let capturedError {
            throw capturedError
        }
    }
}

private final class EmptyStringIterator: NSObject, LibboxStringIteratorProtocol {
    func hasNext() -> Bool { false }
    func len() -> Int32 { 0 }
    func next() -> String { "" }
}

private final class EmptyNetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    func hasNext() -> Bool { false }
    func next() -> LibboxNetworkInterface? { nil }
}
#endif

private extension NEPacketTunnelProvider {
    func setTunnelNetworkSettingsAsync(_ settings: NEPacketTunnelNetworkSettings?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}

private enum SharedTunnelEventStore {
    private static let appGroupIdentifier = "group.com.gemod.Gemod"
    private static let sharedStateFileName = "tunnel_app_group_state.json"

    private struct AppGroupSharedState: Codable {
        var userInitiatedStop: Bool
        var lastStopReasonRaw: Int
        var lastStopTimestamp: TimeInterval
        var pendingNotice: Bool
        var lastNoticeSource: String
        var lastNoticeMessage: String
        var lastNoticeTimestamp: TimeInterval
        var pendingInterruptionNotice: Bool

        private enum CodingKeys: String, CodingKey {
            case userInitiatedStop
            case lastStopReasonRaw
            case lastStopTimestamp
            case pendingNotice
            case lastNoticeSource
            case lastNoticeMessage
            case lastNoticeTimestamp
            case pendingInterruptionNotice
        }

        init(
            userInitiatedStop: Bool,
            lastStopReasonRaw: Int,
            lastStopTimestamp: TimeInterval,
            pendingNotice: Bool,
            lastNoticeSource: String,
            lastNoticeMessage: String,
            lastNoticeTimestamp: TimeInterval,
            pendingInterruptionNotice: Bool
        ) {
            self.userInitiatedStop = userInitiatedStop
            self.lastStopReasonRaw = lastStopReasonRaw
            self.lastStopTimestamp = lastStopTimestamp
            self.pendingNotice = pendingNotice
            self.lastNoticeSource = lastNoticeSource
            self.lastNoticeMessage = lastNoticeMessage
            self.lastNoticeTimestamp = lastNoticeTimestamp
            self.pendingInterruptionNotice = pendingInterruptionNotice
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userInitiatedStop = try container.decodeIfPresent(Bool.self, forKey: .userInitiatedStop) ?? false
            lastStopReasonRaw = try container.decodeIfPresent(Int.self, forKey: .lastStopReasonRaw) ?? -1
            lastStopTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .lastStopTimestamp) ?? 0
            pendingNotice = try container.decodeIfPresent(Bool.self, forKey: .pendingNotice) ?? false
            lastNoticeSource = try container.decodeIfPresent(String.self, forKey: .lastNoticeSource) ?? ""
            lastNoticeMessage = try container.decodeIfPresent(String.self, forKey: .lastNoticeMessage) ?? ""
            lastNoticeTimestamp = try container.decodeIfPresent(TimeInterval.self, forKey: .lastNoticeTimestamp) ?? 0
            pendingInterruptionNotice = try container.decodeIfPresent(Bool.self, forKey: .pendingInterruptionNotice) ?? false
        }

        static let initial = AppGroupSharedState(
            userInitiatedStop: false,
            lastStopReasonRaw: -1,
            lastStopTimestamp: 0,
            pendingNotice: false,
            lastNoticeSource: "",
            lastNoticeMessage: "",
            lastNoticeTimestamp: 0,
            pendingInterruptionNotice: false
        )
    }

    private static let sharedLogFileName = "tunnel_diagnostics.log"
    private static let maxLogLines = 200

    private static func sharedStateFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(sharedStateFileName)
    }

    private static func loadSharedState() -> AppGroupSharedState {
        guard
            let url = sharedStateFileURL(),
            let data = try? Data(contentsOf: url)
        else { return .initial }
        return (try? JSONDecoder().decode(AppGroupSharedState.self, from: data)) ?? .initial
    }

    private static func saveSharedState(_ state: AppGroupSharedState) {
        guard let url = sharedStateFileURL() else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func clearUserInitiatedStopFlag() {
        var s = loadSharedState()
        s.userInitiatedStop = false
        saveSharedState(s)
    }

    static func consumeUserInitiatedStopFlag() -> Bool {
        var s = loadSharedState()
        let flag = s.userInitiatedStop
        s.userInitiatedStop = false
        saveSharedState(s)
        return flag
    }

    static func saveLastStopReason(_ reason: NEProviderStopReason) {
        var s = loadSharedState()
        s.lastStopReasonRaw = reason.rawValue
        s.lastStopTimestamp = Date().timeIntervalSince1970
        s.pendingNotice = true
        saveSharedState(s)
    }

    static func saveInterruptionNotice(source: String, message: String) {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty, !normalizedMessage.isEmpty else { return }
        var s = loadSharedState()
        s.lastNoticeSource = normalizedSource
        s.lastNoticeMessage = normalizedMessage
        s.lastNoticeTimestamp = Date().timeIntervalSince1970
        s.pendingInterruptionNotice = true
        saveSharedState(s)
    }

    static func appendDiagnostic(_ message: String) {
        appendSharedLogLine("D|[ext] \(message)")
    }

    private static func sharedLogFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(sharedLogFileName)
    }

    private static func readSharedLogLines() -> [String] {
        guard
            let url = sharedLogFileURL(),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func appendSharedLogLine(_ message: String) {
        guard let url = sharedLogFileURL() else {
            NSLog("[GemodTunnel] app group 容器不可用: \(appGroupIdentifier)")
            return
        }
        var lines = readSharedLogLines()
        lines.append("\(timestamp()) | \(message)")
        if lines.count > maxLogLines {
            lines = Array(lines.suffix(maxLogLines))
        }
        if let data = lines.joined(separator: "\n").data(using: .utf8) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
