import Foundation
import NetworkExtension
#if canImport(Libbox)
import Libbox
#endif

actor RealSingboxTunnelBackend: TunnelBackend {
    private var environment = TunnelProviderEnvironment(appGroup: nil, backend: "singbox", transport: "tun")
    private var currentConfiguration: TunnelRuntimeConfiguration?
    private var connectionState: ConnectionState = .idle
    private var healthStatus: HealthStatus = .unknown
    private let runtimeDriver: SingboxRuntimeDriver

    init(tunnelProvider: PacketTunnelProvider) {
        runtimeDriver = EmbeddedSingboxRuntimeDriver(tunnelProvider: tunnelProvider)
    }

    func reset(
        environment: TunnelProviderEnvironment,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelBackendSnapshot {
        self.environment = environment
        currentConfiguration = nil
        connectionState = .idle
        healthStatus = .unknown
        await runtimeDriver.stop(diagnosticsStore: diagnosticsStore)
        diagnosticsStore.append(
            "tunnel",
            "真实 backend 已重置：backend=\(environment.backend), transport=\(environment.transport), appGroup=\(environment.appGroup ?? "未提供")。"
        )
        return snapshot
    }

    func connect(
        using configuration: TunnelRuntimeConfiguration,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelBackendSnapshot {
        guard !configuration.rawSubscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connectionState = .failed(message: "订阅内容为空")
            healthStatus = .offline
            diagnosticsStore.append("tunnel", "真实 backend 连接失败：订阅内容为空。")
            return snapshot
        }
        guard let node = configuration.selectedNodeName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !node.isEmpty else {
            connectionState = .failed(message: "未选择节点")
            healthStatus = .degraded
            diagnosticsStore.append("tunnel", "真实 backend 连接失败：未选择节点。")
            return snapshot
        }
        guard !connectionState.isBusy else {
            diagnosticsStore.append("tunnel", "真实 backend 正忙，忽略重复 connect。")
            return snapshot
        }

        if let currentConfiguration,
           currentConfiguration == configuration,
           await runtimeDriver.controllerReady() {
            connectionState = .connected(since: Date())
            healthStatus = .healthy
            diagnosticsStore.append("tunnel", "真实 backend 复用现有 libbox 会话。")
            return snapshot
        }

        connectionState = .connecting
        diagnosticsStore.append(
            "tunnel",
            "真实 backend 开始连接：节点=\(node), 模式=\(configuration.mode.rawValue)。"
        )

        let startup = await runtimeDriver.startIfNeeded(
            node: node,
            mode: configuration.mode.rawValue,
            transport: environment.transport,
            subscriptionContent: configuration.rawSubscription,
            appGroup: environment.appGroup,
            diagnosticsStore: diagnosticsStore
        )

        if startup.isReady {
            currentConfiguration = configuration
            connectionState = .connected(since: Date())
            healthStatus = .healthy
            diagnosticsStore.append("tunnel", "真实 backend 已连接，libbox runtime 已启动。")
        } else {
            currentConfiguration = nil
            connectionState = .failed(message: startup.message)
            healthStatus = .offline
            diagnosticsStore.append("tunnel", "真实 backend 连接失败：\(startup.message)")
        }
        return snapshot
    }

    func disconnect(diagnosticsStore: TunnelDiagnosticsStore) async -> TunnelBackendSnapshot {
        guard !connectionState.isBusy else { return snapshot }
        connectionState = .disconnecting
        diagnosticsStore.append("tunnel", "真实 backend 开始断开。")
        await runtimeDriver.stop(diagnosticsStore: diagnosticsStore)
        currentConfiguration = nil
        connectionState = .idle
        healthStatus = .unknown
        diagnosticsStore.append("tunnel", "真实 backend 已断开。")
        return snapshot
    }

    func probe(diagnosticsStore: TunnelDiagnosticsStore) async -> TunnelBackendSnapshot {
        if currentConfiguration == nil {
            healthStatus = .offline
            if !connectionState.isBusy {
                connectionState = .idle
            }
            diagnosticsStore.append("connectivity", "真实 backend 探针结果：未连接。")
            return snapshot
        }

        let ready = await runtimeDriver.controllerReady()
        if ready {
            if !connectionState.isConnected {
                connectionState = .connected(since: Date())
            }
            healthStatus = .healthy
        } else {
            healthStatus = .offline
            if case .connected = connectionState {
                connectionState = .failed(message: "libbox controller 不可达")
            }
        }
        diagnosticsStore.append("connectivity", "真实 backend 探针结果：\(healthStatus.rawValue)。")
        return snapshot
    }

    func status() async -> TunnelBackendSnapshot {
        snapshot
    }

    func latency(
        using configuration: TunnelRuntimeConfiguration,
        timeoutMilliseconds: Int,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelLatencyResult {
        guard let selected = configuration.selectedNodeName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty else {
            diagnosticsStore.append("latency", "真实 backend 延迟测试失败：未选择节点。")
            return TunnelLatencyResult(snapshot: snapshot, latencyMilliseconds: nil)
        }
        guard let descriptor = nodeProbeDescriptor(
            selectedNodeName: selected,
            subscriptionContent: configuration.rawSubscription
        ) else {
            diagnosticsStore.append("latency", "真实 backend 延迟测试失败：未找到节点 \(selected) 的出站配置。")
            return TunnelLatencyResult(snapshot: snapshot, latencyMilliseconds: nil)
        }
        _ = timeoutMilliseconds

        let start = DispatchTime.now().uptimeNanoseconds
        let startup = await runtimeDriver.startIfNeeded(
            node: selected,
            mode: configuration.mode.rawValue,
            transport: environment.transport,
            subscriptionContent: configuration.rawSubscription,
            appGroup: environment.appGroup,
            diagnosticsStore: diagnosticsStore
        )
        let latency: Int?
        if startup.isReady {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            latency = max(1, Int(elapsed / 1_000_000))
        } else {
            latency = nil
            diagnosticsStore.append("latency", "节点=\(selected) 核心测速失败：\(startup.message)")
        }

        diagnosticsStore.append(
            "latency",
            "真实 backend 延迟测试（核心）：节点=\(selected), 协议=\(descriptor.type), 结果=\(latency.map { "\($0)ms" } ?? "超时")。"
        )
        return TunnelLatencyResult(snapshot: snapshot, latencyMilliseconds: latency)
    }

    private var snapshot: TunnelBackendSnapshot {
        TunnelBackendSnapshot(connectionState: connectionState, healthStatus: healthStatus)
    }

    private struct NodeProbeDescriptor {
        let type: String
    }

    private func nodeProbeDescriptor(selectedNodeName: String, subscriptionContent: String) -> NodeProbeDescriptor? {
        guard let data = subscriptionContent.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]] else {
            return nil
        }
        guard let outbound = outbounds.first(where: { ($0["tag"] as? String) == selectedNodeName }) else {
            return nil
        }
        let type = (outbound["type"] as? String) ?? "unknown"
        return NodeProbeDescriptor(type: type)
    }
}

private struct SingboxStartupResult {
    let isReady: Bool
    let message: String
}

private protocol SingboxRuntimeDriver: Sendable {
    func startIfNeeded(
        node: String,
        mode: String,
        transport: String,
        subscriptionContent: String?,
        appGroup: String?,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> SingboxStartupResult
    func stop(diagnosticsStore: TunnelDiagnosticsStore) async
    func controllerReady() async -> Bool
}

private actor EmbeddedSingboxRuntimeDriver: SingboxRuntimeDriver {
    #if canImport(Libbox)
    private let platformInterface: GemodLibboxPlatformInterface
    private var commandServer: LibboxCommandServer?
    #else
    init(tunnelProvider: PacketTunnelProvider) {
        _ = tunnelProvider
    }
    #endif
    private var activeConfig: String?
    private var serviceStarted = false
    private var setupFinished = false
    private var runtimePresentChecked = false
    private var runtimePresent = false
    private var bundledRuleSetInstalled = false

    init(tunnelProvider: PacketTunnelProvider) {
        #if canImport(Libbox)
        platformInterface = GemodLibboxPlatformInterface(tunnelProvider: tunnelProvider)
        #else
        _ = tunnelProvider
        #endif
    }

    func startIfNeeded(
        node: String,
        mode: String,
        transport: String,
        subscriptionContent: String?,
        appGroup: String?,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> SingboxStartupResult {
        guard transport.lowercased() == "tun" else {
            return SingboxStartupResult(isReady: false, message: "仅支持 tun transport")
        }
        guard detectRuntimePresenceIfNeeded() else {
            return SingboxStartupResult(isReady: false, message: "Libbox 未链接到 GemodTunnel target")
        }

        #if canImport(Libbox)
        do {
            try ensureLibboxSetup(appGroup: appGroup)
            installBundledRuleSetsIfNeeded(appGroup: appGroup, diagnosticsStore: diagnosticsStore)
            let server = try ensureCommandServer(diagnosticsStore: diagnosticsStore)
            guard let configContent = buildConfig(
                node: node,
                mode: mode,
                subscriptionContent: subscriptionContent,
                appGroup: appGroup,
                diagnosticsStore: diagnosticsStore
            ) else {
                return SingboxStartupResult(isReady: false, message: "无法从订阅生成 sing-box 配置")
            }

            if activeConfig == configContent, serviceStarted {
                return SingboxStartupResult(isReady: true, message: "")
            }

            do {
                try server.checkConfig(configContent)
            } catch {
                return SingboxStartupResult(
                    isReady: false,
                    message: "libbox 配置校验失败：\(error.localizedDescription)"
                )
            }

            let overrideOptions = LibboxOverrideOptions()
            do {
                try server.startOrReloadService(configContent, options: overrideOptions)
            } catch {
                let message = error.localizedDescription
                if shouldRetryWithoutRemoteRuleSet(message),
                   let fallbackConfig = buildRuleSetFallbackConfig(from: configContent) {
                    diagnosticsStore.append("tunnel", "检测到 rule-set 初始化失败，尝试无 rule_set 降级重试。")
                    do {
                        try server.startOrReloadService(fallbackConfig, options: overrideOptions)
                        activeConfig = fallbackConfig
                        serviceStarted = true
                        diagnosticsStore.append("tunnel", "libbox 已以无 rule_set 降级配置启动。")
                        diagnosticsStore.append("connectivity", "libbox fallback 已启动（禁用 clash controller 监听）。")
                        return SingboxStartupResult(isReady: true, message: "")
                    } catch {
                        return SingboxStartupResult(
                            isReady: false,
                            message: "libbox fallback 启动失败：\(error.localizedDescription)"
                        )
                    }
                }
                return SingboxStartupResult(
                    isReady: false,
                    message: "libbox 启动失败：\(message)"
                )
            }

            activeConfig = configContent
            serviceStarted = true
            diagnosticsStore.append("tunnel", "libbox 服务已启动或重载。")
        } catch {
            return SingboxStartupResult(isReady: false, message: error.localizedDescription)
        }
        #else
        return SingboxStartupResult(isReady: false, message: "当前构建不包含 Libbox")
        #endif

        diagnosticsStore.append("connectivity", "libbox 服务已启动（禁用 clash controller 监听）。")
        return SingboxStartupResult(isReady: true, message: "")
    }

    func stop(diagnosticsStore: TunnelDiagnosticsStore) async {
        #if canImport(Libbox)
        if let commandServer {
            do {
                try commandServer.closeService()
            } catch {
                diagnosticsStore.append("tunnel", "libbox closeService 失败：\(error.localizedDescription)")
            }
            commandServer.close()
            diagnosticsStore.append("tunnel", "libbox command server 已关闭。")
        }
        commandServer = nil
        #else
        _ = diagnosticsStore
        #endif
        activeConfig = nil
        serviceStarted = false
    }

    func controllerReady() async -> Bool {
        serviceStarted
    }

    private func detectRuntimePresenceIfNeeded() -> Bool {
        if runtimePresentChecked {
            return runtimePresent
        }
        runtimePresentChecked = true
        #if canImport(Libbox)
        let version = LibboxVersion()
        runtimePresent = !version.isEmpty
        return runtimePresent
        #else
        runtimePresent = false
        return false
        #endif
    }

    #if canImport(Libbox)
    private func ensureLibboxSetup(appGroup: String?) throws {
        guard !setupFinished else { return }

        let baseURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup ?? "group.com.gemod.shared")?
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
        options.crashReportSource = "GemodTunnel"
        options.debug = true
        options.logMaxLines = 200

        guard LibboxSetup(options, nil) else {
            throw NSError(
                domain: "GemodLibboxSetup",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "LibboxSetup 失败"]
            )
        }

        setupFinished = true
    }

    private func ensureCommandServer(diagnosticsStore: TunnelDiagnosticsStore) throws -> LibboxCommandServer {
        if let commandServer {
            return commandServer
        }

        let handler = GemodLibboxCommandServerHandler(diagnosticsStore: diagnosticsStore)
        var createError: NSError?
        guard let server = LibboxNewCommandServer(handler, platformInterface, &createError) else {
            throw createError ?? NSError(
                domain: "GemodLibboxCommandServer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "创建 LibboxCommandServer 失败"]
            )
        }

        do {
            try server.start()
        } catch {
            throw NSError(
                domain: "GemodLibboxCommandServer",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "启动 LibboxCommandServer 失败：\(error.localizedDescription)"]
            )
        }

        commandServer = server
        diagnosticsStore.append(
            "tunnel",
            "libbox command server 已启动，libbox=\(LibboxVersion())，go=\(LibboxGoVersion())。"
        )
        return server
    }
    #endif

    private func buildConfig(
        node: String,
        mode: String,
        subscriptionContent: String?,
        appGroup: String?,
        diagnosticsStore: TunnelDiagnosticsStore
    ) -> String? {
        guard let raw = subscriptionContent?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sourceOutbounds = json["outbounds"] as? [[String: Any]], !sourceOutbounds.isEmpty else {
            diagnosticsStore.append("tunnel", "订阅解析失败：缺少 outbounds。")
            return nil
        }

        let proxyOutbounds = extractProxyOutbounds(from: sourceOutbounds)
        guard !proxyOutbounds.isEmpty else {
            diagnosticsStore.append("tunnel", "订阅解析失败：没有可用代理出站。")
            return nil
        }

        let selectedTag = resolvedSelectedTag(node: node, proxyOutbounds: proxyOutbounds)
        guard let selectedOutbound = proxyOutbounds.first(where: { ($0["tag"] as? String) == selectedTag }) else {
            diagnosticsStore.append("tunnel", "订阅解析失败：未找到选中节点对应的出站。")
            return nil
        }

        let bootstrapDomains = extractProxyServerDomains(from: proxyOutbounds)
        let isRuleMode = mode.lowercased() == "rule"
        let localManagedRuleSets = managedLocalRuleSetEntries(appGroup: appGroup)
        let hasLocalManagedRuleSets = !localManagedRuleSets.isEmpty
        let availableRuleSetTags = Set(localManagedRuleSets.compactMap { $0["tag"] as? String })
        let availableGeoSiteTags = ["geosite-cn", "geosite-private", "geosite-apple", "geosite-icloud"]
            .filter { availableRuleSetTags.contains($0) }
        let availableGeoIPTags = ["geoip-cn", "geoip-private"]
            .filter { availableRuleSetTags.contains($0) }

        var dnsRules: [[String: Any]] = []
        if !bootstrapDomains.isEmpty {
            dnsRules.append([
                "domain": bootstrapDomains,
                "server": "gemod-dns-bootstrap",
            ])
        }
        if isRuleMode && hasLocalManagedRuleSets {
            dnsRules.append(["domain_suffix": ["alibaba.com"], "server": "gemod-dns-remote"])
            if !availableGeoSiteTags.isEmpty {
                dnsRules.append([
                    "rule_set": availableGeoSiteTags,
                    "server": "gemod-dns-bootstrap",
                ])
            }
            dnsRules.append(["domain_suffix": ["amazon.cn"], "server": "gemod-dns-bootstrap"])
            dnsRules.append(["domain_suffix": ["678ceo.com", "gemod.net"], "server": "gemod-dns-bootstrap"])
        }

        let dnsConfig: [String: Any] = [
            "servers": [
                [
                    "type": "https",
                    "tag": "gemod-dns-remote",
                    "server": "1.1.1.1",
                    "server_port": 443,
                    "path": "/dns-query",
                    "detour": selectedTag,
                ],
                [
                    "type": "tcp",
                    "tag": "gemod-dns-bootstrap",
                    "server": "223.5.5.5",
                    "server_port": 53,
                ],
            ],
            "rules": dnsRules,
            "final": "gemod-dns-remote",
            "independent_cache": true,
        ]

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["action": "hijack-dns", "protocol": "dns"],
        ]
        if isRuleMode {
            routeRules.append(["domain_suffix": ["alibaba.com"], "outbound": selectedTag])
            if hasLocalManagedRuleSets {
                if !availableGeoSiteTags.isEmpty {
                    routeRules.append([
                        "rule_set": availableGeoSiteTags,
                        "outbound": "direct",
                    ])
                }
                if !availableGeoIPTags.isEmpty {
                    routeRules.append(["rule_set": availableGeoIPTags, "outbound": "direct"])
                }
            }
            routeRules.append(["domain_suffix": ["amazon.cn"], "outbound": "direct"])
            routeRules.append(["domain_suffix": ["678ceo.com", "gemod.net"], "outbound": "direct"])
            routeRules.append(["ip_is_private": true, "outbound": "direct"])
        }

        var routeConfig: [String: Any] = [
            "auto_detect_interface": false,
            "rules": routeRules,
            "final": selectedTag,
        ]
        if isRuleMode {
            if hasLocalManagedRuleSets {
                routeConfig["rule_set"] = localManagedRuleSets
            } else {
                diagnosticsStore.append("tunnel", "未发现本地 geosite/geoip 规则集，rule 模式按内置域名规则运行（可预装 .srs 后自动启用）。")
            }
        }

        let config: [String: Any] = [
            "log": [
                "level": "info",
            ],
            "dns": dnsConfig,
            "inbounds": [[
                "type": "tun",
                "tag": "tun-in",
                "stack": "gvisor",
                "auto_route": true,
                "strict_route": false,
                "address": ["10.8.0.2/24"],
                "mtu": 1500,
            ]],
            "outbounds": [
                selectedOutbound,
                ["type": "direct", "tag": "direct"],
                ["type": "block", "tag": "block"],
            ],
            "route": routeConfig,
        ]

        guard let output = try? JSONSerialization.data(withJSONObject: config, options: []),
              let text = String(data: output, encoding: .utf8) else {
            return nil
        }

        diagnosticsStore.append(
            "tunnel",
            "libbox 配置已生成：节点=\(selectedTag)，模式=\(isRuleMode ? "rule" : "global")。"
        )
        return text
    }

    private func resolvedSelectedTag(node: String, proxyOutbounds: [[String: Any]]) -> String {
        let normalized = node.trimmingCharacters(in: .whitespacesAndNewlines)
        if proxyOutbounds.contains(where: { ($0["tag"] as? String) == normalized }) {
            return normalized
        }
        return (proxyOutbounds.first?["tag"] as? String) ?? normalized
    }

    private func extractProxyOutbounds(from outbounds: [[String: Any]]) -> [[String: Any]] {
        let proxyTypes: Set<String> = [
            "shadowsocks", "vmess", "vless", "trojan", "hysteria", "hysteria2",
            "tuic", "wireguard", "ssh", "socks", "http", "anytls", "shadowtls"
        ]
        return outbounds.filter { outbound in
            guard let tag = outbound["tag"] as? String,
                  !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
            guard !host.isEmpty, !isIPv4Literal(host), !host.contains(":") else { continue }
            domains.insert(host)
        }
        return domains.sorted()
    }

    private func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".")
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let number = Int(part), number >= 0, number <= 255 else {
                return false
            }
        }
        return true
    }

    private func managedRuleSetSpecs() -> [(tag: String, fileName: String)] {
        [
            ("geosite-cn", "geosite-cn.srs"),
            ("geosite-private", "geosite-private.srs"),
            ("geosite-apple", "geosite-apple.srs"),
            ("geosite-icloud", "geosite-icloud.srs"),
            ("geoip-cn", "geoip-cn.srs"),
            ("geoip-private", "geoip-private.srs"),
        ]
    }

    private func managedLocalRuleSetEntries(appGroup: String?) -> [[String: Any]] {
        guard let directory = ruleSetDirectoryURL(appGroup: appGroup) else { return [] }
        return managedRuleSetSpecs().compactMap { spec in
            let fileURL = directory.appendingPathComponent(spec.fileName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return [
                "type": "local",
                "tag": spec.tag,
                "path": fileURL.path,
                "format": "binary",
            ]
        }
    }

    private func installBundledRuleSetsIfNeeded(appGroup: String?, diagnosticsStore: TunnelDiagnosticsStore) {
        guard !bundledRuleSetInstalled else { return }
        bundledRuleSetInstalled = true
        guard let targetDirectory = ruleSetDirectoryURL(appGroup: appGroup) else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        for spec in managedRuleSetSpecs() {
            let destinationURL = targetDirectory.appendingPathComponent(spec.fileName, isDirectory: false)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            guard let bundledURL = Bundle.main.url(forResource: spec.fileName, withExtension: nil, subdirectory: "RuleSets")
                    ?? Bundle.main.url(forResource: spec.fileName, withExtension: nil) else {
                continue
            }
            do {
                try fileManager.copyItem(at: bundledURL, to: destinationURL)
                diagnosticsStore.append("tunnel", "已加载预装规则集：\(spec.fileName)。")
            } catch {
                diagnosticsStore.append("tunnel", "加载预装规则集失败：\(spec.fileName)，\(error.localizedDescription)")
            }
        }
    }

    private func ruleSetDirectoryURL(appGroup: String?) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup ?? "group.com.gemod.shared")?
            .appendingPathComponent("rulesets", isDirectory: true)
    }

    private func shouldRetryWithoutRemoteRuleSet(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("initialize rule-set")
            || lower.contains("initial rule-set")
            || lower.contains("rule-set")
    }

    private func buildRuleSetFallbackConfig(from configContent: String) -> String? {
        guard let data = configContent.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if var route = json["route"] as? [String: Any] {
            route.removeValue(forKey: "rule_set")
            if let rules = route["rules"] as? [[String: Any]] {
                route["rules"] = rules.filter { $0["rule_set"] == nil }
            }
            json["route"] = route
        }

        if var dns = json["dns"] as? [String: Any], let rules = dns["rules"] as? [[String: Any]] {
            dns["rules"] = rules.filter { $0["rule_set"] == nil }
            json["dns"] = dns
        }

        guard let output = try? JSONSerialization.data(withJSONObject: json, options: []),
              let text = String(data: output, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

#if canImport(Libbox)
private final class GemodLibboxCommandServerHandler: NSObject, LibboxCommandServerHandlerProtocol {
    private let diagnosticsStore: TunnelDiagnosticsStore

    init(diagnosticsStore: TunnelDiagnosticsStore) {
        self.diagnosticsStore = diagnosticsStore
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        let status = LibboxSystemProxyStatus()
        status.available = false
        status.enabled = false
        return status
    }

    func serviceReload() throws {}
    func serviceStop() throws {}
    func setSystemProxyEnabled(_ enabled: Bool) throws {
        diagnosticsStore.append("tunnel", "忽略系统代理切换请求：enabled=\(enabled ? "true" : "false")。")
    }

    func triggerNativeCrash() throws {}

    func writeDebugMessage(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        diagnosticsStore.append("tunnel", "libbox: \(message)")
    }
}

private final class GemodLibboxPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private weak var tunnelProvider: PacketTunnelProvider?

    init(tunnelProvider: PacketTunnelProvider) {
        self.tunnelProvider = tunnelProvider
    }

    func autoDetectControl(_ fd: Int32) throws {
        _ = fd
    }

    func clearDNSCache() {}

    func closeDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        _ = listener
    }

    func closeNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        _ = listener
    }

    func findConnectionOwner(
        _ ipProtocol: Int32,
        sourceAddress: String?,
        sourcePort: Int32,
        destinationAddress: String?,
        destinationPort: Int32
    ) throws -> LibboxConnectionOwner {
        _ = (ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
        let owner = LibboxConnectionOwner()
        owner.userId = -1
        owner.userName = ""
        owner.processPath = ""
        return owner
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        EmptyNetworkInterfaceIterator()
    }

    func includeAllNetworks() -> Bool { false }
    func localDNSTransport() -> LibboxLocalDNSTransportProtocol? { nil }

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -10, userInfo: [
                NSLocalizedDescriptionKey: "openTun options is nil",
            ])
        }
        guard let tunnelProvider else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -11, userInfo: [
                NSLocalizedDescriptionKey: "openTun tunnelProvider is nil",
            ])
        }
        guard let ret0_ else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -12, userInfo: [
                NSLocalizedDescriptionKey: "openTun return pointer is nil",
            ])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        if let dnsIterator = try? options.getDNSServerAddress(),
           let dnsServer = firstString(from: dnsIterator), !dnsServer.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: [dnsServer])
        } else {
            settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
        }

        let ipv4Prefixes = collectRoutePrefixes(from: options.getInet4Address())
        let ipv4Addresses = ipv4Prefixes.map(\.address)
        let ipv4Masks = ipv4Prefixes.map(\.mask)
        let fallbackIPv4Addresses = ipv4Addresses.isEmpty ? ["10.8.0.2"] : ipv4Addresses
        let fallbackIPv4Masks = ipv4Masks.isEmpty ? ["255.255.255.0"] : ipv4Masks
        let ipv4Settings = NEIPv4Settings(addresses: fallbackIPv4Addresses, subnetMasks: fallbackIPv4Masks)

        let includedIPv4Routes = collectRoutePrefixes(from: options.getInet4RouteAddress()).map {
            NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask)
        }
        if !includedIPv4Routes.isEmpty {
            ipv4Settings.includedRoutes = includedIPv4Routes
        } else if options.getAutoRoute() {
            ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        }

        let excludedIPv4Routes = collectRoutePrefixes(from: options.getInet4RouteExcludeAddress()).map {
            NEIPv4Route(destinationAddress: $0.address, subnetMask: $0.mask)
        }
        if !excludedIPv4Routes.isEmpty {
            ipv4Settings.excludedRoutes = excludedIPv4Routes
        }
        settings.ipv4Settings = ipv4Settings

        let ipv6Prefixes = collectRoutePrefixes(from: options.getInet6Address())
        if !ipv6Prefixes.isEmpty {
            let ipv6Settings = NEIPv6Settings(
                addresses: ipv6Prefixes.map(\.address),
                networkPrefixLengths: ipv6Prefixes.map { NSNumber(value: $0.prefix) }
            )

            let includedIPv6Routes = collectRoutePrefixes(from: options.getInet6RouteAddress()).map {
                NEIPv6Route(
                    destinationAddress: $0.address,
                    networkPrefixLength: NSNumber(value: $0.prefix)
                )
            }
            if !includedIPv6Routes.isEmpty {
                ipv6Settings.includedRoutes = includedIPv6Routes
            } else if options.getAutoRoute() {
                ipv6Settings.includedRoutes = [NEIPv6Route.default()]
            }

            let excludedIPv6Routes = collectRoutePrefixes(from: options.getInet6RouteExcludeAddress()).map {
                NEIPv6Route(
                    destinationAddress: $0.address,
                    networkPrefixLength: NSNumber(value: $0.prefix)
                )
            }
            if !excludedIPv6Routes.isEmpty {
                ipv6Settings.excludedRoutes = excludedIPv6Routes
            }

            settings.ipv6Settings = ipv6Settings
        }

        try runBlocking {
            try await tunnelProvider.setTunnelNetworkSettingsAsync(settings)
        }

        if let tunFD = tunnelProvider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = tunFD
            return
        }

        let fallbackFD = LibboxGetTunnelFileDescriptor()
        guard fallbackFD != -1 else {
            throw NSError(domain: "GemodLibboxPlatformInterface", code: -13, userInfo: [
                NSLocalizedDescriptionKey: "无法获取 tun file descriptor",
            ])
        }
        ret0_.pointee = fallbackFD
    }

    func readWIFIState() -> LibboxWIFIState? { nil }
    func registerMyInterface(_ name: String?) { _ = name }
    func send(_ notification: LibboxNotification?) throws {
        _ = notification
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        _ = listener
    }

    func startNeighborMonitor(_ listener: LibboxNeighborUpdateListenerProtocol?) throws {
        _ = listener
    }

    func systemCertificates() -> LibboxStringIteratorProtocol? {
        EmptyStringIterator()
    }

    func underNetworkExtension() -> Bool { true }
    func usePlatformAutoDetectControl() -> Bool { false }
    func useProcFS() -> Bool { false }

    private func collectRoutePrefixes(
        from iterator: LibboxRoutePrefixIteratorProtocol?
    ) -> [(address: String, mask: String, prefix: Int32)] {
        guard let iterator else { return [] }
        var items: [(address: String, mask: String, prefix: Int32)] = []
        while iterator.hasNext() {
            guard let prefix = iterator.next() else { continue }
            items.append((prefix.address(), prefix.mask(), prefix.prefix()))
        }
        return items
    }

    private func firstString(from iterator: LibboxStringIteratorProtocol) -> String? {
        guard iterator.hasNext() else { return nil }
        let value = iterator.next().trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
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
