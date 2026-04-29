import Foundation
@preconcurrency import NetworkExtension

enum TunnelControllerError: LocalizedError {
    case managerUnavailable
    case invalidConfiguration
    case startFailed
    case simulatorUnsupported
    case providerNotConnected
    case providerMessageFailed
    case providerMessageTimeout
    case tunnelStartTimeout
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .managerUnavailable:
            return AppLanguage.useSimplifiedChinese ? "隧道管理器不可用" : "Tunnel manager unavailable"
        case .invalidConfiguration:
            return AppLanguage.useSimplifiedChinese ? "隧道配置无效" : "Invalid tunnel configuration"
        case .startFailed:
            return AppLanguage.useSimplifiedChinese ? "启动隧道失败" : "Failed to start tunnel"
        case .simulatorUnsupported:
            return AppLanguage.useSimplifiedChinese ? "模拟器不支持启动 Packet Tunnel，请使用真机" : "Packet Tunnel is unsupported on simulator, use a real device"
        case .providerNotConnected:
            return AppLanguage.useSimplifiedChinese ? "隧道未连接，无法发送命令" : "Tunnel not connected, cannot send command"
        case .providerMessageFailed:
            return AppLanguage.useSimplifiedChinese ? "隧道命令发送失败" : "Failed to send tunnel command"
        case .providerMessageTimeout:
            return AppLanguage.useSimplifiedChinese ? "隧道命令响应超时" : "Tunnel command response timed out"
        case .tunnelStartTimeout:
            return AppLanguage.useSimplifiedChinese ? "隧道启动超时" : "Tunnel startup timed out"
        case .permissionDenied:
            return AppLanguage.useSimplifiedChinese ? "系统拒绝保存 VPN 配置（permission denied）" : "System denied saving VPN configuration (permission denied)"
        }
    }
}

final class TunnelController {
    private let providerBundleIdentifier: String
    private let appGroupIdentifier: String
    private let providerBackend: String
    private let resetManagerOnStart: Bool

    init(
        providerBundleIdentifier: String = "com.gemod.Gemod.GemodTunnel",
        appGroupIdentifier: String = "group.com.gemod.Gemod",
        providerBackend: String = TunnelController.resolveProviderBackend(),
        // 若每次连前都 removeFromPreferences，部分设备上系统长期停在 disconnected
        resetManagerOnStart: Bool = false
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.appGroupIdentifier = appGroupIdentifier
        self.providerBackend = providerBackend
        self.resetManagerOnStart = resetManagerOnStart
    }

    func startTunnel() async throws {
#if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
#else
        TunnelEventStore.clearUserInitiatedStopFlag()
        TunnelEventStore.clearDiagnostics()
        TunnelEventStore.appendDiagnostic("startTunnel requested")
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) == nil {
            TunnelEventStore.appendDiagnostic("appGroupContainer=nil (签名/描述文件需含 App Group，删 App 重装)")
        } else {
            TunnelEventStore.appendDiagnostic("appGroupContainer=ok")
        }
        if resetManagerOnStart {
            try await removeExistingManagers()
        }

        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        appendManagerSnapshot(manager, source: "startTunnel-after-load")
        if !manager.isEnabled {
            manager.isEnabled = true
            try await saveManagerWithStaleRetry(manager) { staleManager in
                staleManager.isEnabled = true
            }
            try await manager.loadFromPreferencesAsync()
            appendManagerSnapshot(manager, source: "startTunnel-after-enable")
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            TunnelEventStore.appendDiagnostic("manager connection is not NETunnelProviderSession")
            throw TunnelControllerError.managerUnavailable
        }
        TunnelEventStore.appendStatusTimeline(session.status, source: "startTunnel-before")
        if session.status == .connected || session.status == .reasserting {
            return
        }
        if session.status == .connecting {
            try await waitUntilConnected(connection: manager.connection)
            return
        }
        do {
            try session.startVPNTunnel()
            TunnelEventStore.appendDiagnostic(
                "startVPNTunnel called immediateStatus=\(statusText(session.status))"
            )
        } catch {
            let nsError = error as NSError
            TunnelEventStore.appendDiagnostic(
                "startVPNTunnel failed domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
            )
            throw TunnelControllerError.startFailed
        }
        try await waitUntilConnected(connection: manager.connection)
#endif
    }

    func stopTunnel() async throws {
        TunnelEventStore.markUserInitiatedStop()
        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        appendManagerSnapshot(manager, source: "stopTunnel")
        manager.connection.stopVPNTunnel()
        try await waitUntilDisconnected(connection: manager.connection)
    }

    func currentStatus() async throws -> NEVPNStatus {
#if targetEnvironment(simulator)
        return .disconnected
#else
        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        appendManagerSnapshot(manager, source: "currentStatus")
        return manager.connection.status
#endif
    }

    func sendProviderCommand(_ payload: [String: String]) async throws -> [String: String] {
#if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
#else
        var lastError: Error = TunnelControllerError.providerNotConnected
        for attempt in 0...1 {
            do {
                let manager = try await ensureTunnelReadyForProviderMessage()
                appendManagerSnapshot(manager, source: "sendProviderCommand")
                guard let session = manager.connection as? NETunnelProviderSession else {
                    TunnelEventStore.appendDiagnostic("send command failed: no provider session")
                    throw TunnelControllerError.managerUnavailable
                }
                let requestData = try JSONSerialization.data(withJSONObject: payload)
                let command = payload["command"] ?? "unknown"
                let timeout = timeoutForProviderCommand(command)
                TunnelEventStore.appendDiagnostic("sendProviderMessage command=\(command) timeout=\(timeout)s")
                let responseData = try await sendProviderMessage(session: session, data: requestData, timeout: timeout)
                guard
                    let responseData,
                    let jsonObject = try JSONSerialization.jsonObject(with: responseData) as? [String: String]
                else {
                    throw TunnelControllerError.providerMessageFailed
                }
                return jsonObject
            } catch {
                lastError = error
                let shouldRetry = attempt == 0 && shouldRetryProviderSend(error: error)
                if shouldRetry {
                    TunnelEventStore.appendDiagnostic("sendProviderCommand retry after error=\(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
            }
        }
        throw lastError
#endif
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferencesAsync()
        if let existing = managers.first(where: { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == providerBundleIdentifier
        }) {
            if applyDesiredProviderConfiguration(to: existing) {
                try await saveManagerWithStaleRetry(existing) { staleManager in
                    _ = self.applyDesiredProviderConfiguration(to: staleManager)
                }
                try await existing.loadFromPreferencesAsync()
            }
            return existing
        }

        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "Gemod Tunnel"
        proto.providerConfiguration = [
            "appGroup": appGroupIdentifier,
            "transport": "tun",
            "backend": providerBackend
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Gemod Tunnel"
        manager.isEnabled = true
        _ = applyDesiredProviderConfiguration(to: manager)

        try await saveManagerWithStaleRetry(manager) { staleManager in
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.providerBundleIdentifier
            proto.serverAddress = "Gemod Tunnel"
            proto.providerConfiguration = [
                "appGroup": self.appGroupIdentifier,
                "transport": "tun",
                "backend": self.providerBackend
            ]
            staleManager.protocolConfiguration = proto
            staleManager.localizedDescription = "Gemod Tunnel"
            staleManager.isEnabled = true
            _ = self.applyDesiredProviderConfiguration(to: staleManager)
        }
        try await manager.loadFromPreferencesAsync()
        return manager
    }

    private func removeExistingManagers() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferencesAsync()
        let matched = managers.filter { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == providerBundleIdentifier
        }
        guard !matched.isEmpty else { return }
        TunnelEventStore.appendDiagnostic("removing existing managers count=\(matched.count)")
        for manager in matched {
            try await manager.removeFromPreferencesAsync()
        }
    }

    private func sendProviderMessage(
        session: NETunnelProviderSession,
        data: Data,
        timeout: TimeInterval = 3.0
    ) async throws -> Data? {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                    do {
                        try session.sendProviderMessage(data) { responseData in
                            continuation.resume(returning: responseData)
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw TunnelControllerError.providerMessageTimeout
            }
            let result = try await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    private func ensureTunnelReadyForProviderMessage() async throws -> NETunnelProviderManager {
        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelControllerError.managerUnavailable
        }

        TunnelEventStore.appendStatusTimeline(session.status, source: "sendProviderCommand-precheck")
        switch session.status {
        case .connected, .reasserting:
            return manager
        case .connecting:
            try await waitUntilConnected(connection: manager.connection)
            return manager
        default:
            // Sequence hardening: provider command path ensures tunnel is up.
            TunnelEventStore.appendDiagnostic("provider command precheck status=\(session.status.rawValue), auto-start tunnel")
            try await startTunnel()
            let reloaded = try await loadOrCreateManager()
            try await reloaded.loadFromPreferencesAsync()
            guard let reloadedSession = reloaded.connection as? NETunnelProviderSession else {
                throw TunnelControllerError.managerUnavailable
            }
            if reloadedSession.status == .connecting {
                try await waitUntilConnected(connection: reloaded.connection)
            }
            guard reloadedSession.status == .connected || reloadedSession.status == .reasserting else {
                TunnelEventStore.appendDiagnostic("provider command precheck still disconnected status=\(reloadedSession.status.rawValue)")
                throw TunnelControllerError.providerNotConnected
            }
            return reloaded
        }
    }

    private func shouldRetryProviderSend(error: Error) -> Bool {
        guard let tunnelError = error as? TunnelControllerError else {
            return false
        }
        switch tunnelError {
        case .providerNotConnected, .providerMessageFailed, .providerMessageTimeout:
            return true
        default:
            return false
        }
    }

    private func timeoutForProviderCommand(_ command: String) -> TimeInterval {
        switch command.lowercased() {
        case "connect":
            // real sing-box/libbox startup + readiness probe may take several seconds
            return 12.0
        case "disconnect":
            return 6.0
        case "status", "health":
            return 4.0
        case "latency":
            return 5.0
        default:
            return 5.0
        }
    }

    private func waitUntilConnected(
        connection: NEVPNConnection,
        timeout: TimeInterval = 20.0,
        interval: UInt64 = 200_000_000
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = connection.status
            TunnelEventStore.appendStatusTimeline(status, source: "wait")
            if status == .connected || status == .reasserting {
                TunnelEventStore.appendDiagnostic("tunnel reached connected state")
                return
            }
            if status == .invalid {
                TunnelEventStore.appendDiagnostic("tunnel status became invalid")
                appendConnectionSnapshot(connection, source: "wait-invalid")
                throw TunnelControllerError.providerNotConnected
            }
            try await Task.sleep(nanoseconds: interval)
        }
        TunnelEventStore.appendDiagnostic("wait connected timeout")
        if connection.status == .disconnected {
            TunnelEventStore.appendDiagnostic(
                "tunnel stayed disconnected; check VPN permission prompt, Network Extension entitlement, provisioning profile, and provider bundle id"
            )
        }
        appendConnectionSnapshot(connection, source: "wait-timeout")
        throw TunnelControllerError.tunnelStartTimeout
    }

    private func waitUntilDisconnected(
        connection: NEVPNConnection,
        timeout: TimeInterval = 6.0,
        interval: UInt64 = 200_000_000
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = connection.status
            TunnelEventStore.appendStatusTimeline(status, source: "wait-stop")
            if status == .disconnected || status == .invalid {
                TunnelEventStore.appendDiagnostic("tunnel reached disconnected state")
                return
            }
            try await Task.sleep(nanoseconds: interval)
        }
        TunnelEventStore.appendDiagnostic("wait disconnected timeout")
    }

    private func appendManagerSnapshot(_ manager: NETunnelProviderManager, source: String) {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let providerID = proto?.providerBundleIdentifier ?? "nil"
        let serverAddress = proto?.serverAddress ?? "nil"
        let providerConfig = (proto?.providerConfiguration as? [String: String]) ?? [:]
        let backend = providerConfig["backend"] ?? "nil"
        let transport = providerConfig["transport"] ?? "nil"
        let statusText = statusText(manager.connection.status)
        TunnelEventStore.appendDiagnostic(
            "[\(source)] enabled=\(manager.isEnabled) status=\(statusText) providerID=\(providerID) server=\(serverAddress) backend=\(backend) transport=\(transport)"
        )
        appendConnectionSnapshot(manager.connection, source: source)
    }

    private func appendConnectionSnapshot(_ connection: NEVPNConnection, source: String) {
        let statusText = statusText(connection.status)
        TunnelEventStore.appendDiagnostic("[\(source)] status=\(statusText)")
    }

    @discardableResult
    private func applyDesiredProviderConfiguration(to manager: NETunnelProviderManager) -> Bool {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            return false
        }
        let desired: [String: String] = [
            "appGroup": appGroupIdentifier,
            "transport": "tun",
            "backend": providerBackend
        ]

        var merged = (proto.providerConfiguration as? [String: String]) ?? [:]
        var changed = false
        for (key, value) in desired {
            if merged[key] != value {
                merged[key] = value
                changed = true
            }
        }
        if changed {
            proto.providerConfiguration = merged
            manager.protocolConfiguration = proto
        }
        return changed
    }

    private func statusText(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    static func resolveProviderBackend() -> String {
        "singbox"
    }

    private func saveManagerWithStaleRetry(
        _ manager: NETunnelProviderManager,
        reapply: (NETunnelProviderManager) -> Void
    ) async throws {
        do {
            try await manager.saveToPreferencesAsync()
        } catch {
            if isPermissionDeniedError(error) {
                let nsError = error as NSError
                TunnelEventStore.appendDiagnostic(
                    "saveToPreferences permission denied domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
                )
                throw TunnelControllerError.permissionDenied
            }
            guard isStaleConfigurationError(error) else {
                throw error
            }
            TunnelEventStore.appendDiagnostic("saveToPreferences stale; reload + reapply + retry")
            try await manager.loadFromPreferencesAsync()
            reapply(manager)
            do {
                try await manager.saveToPreferencesAsync()
            } catch {
                if isPermissionDeniedError(error) {
                    let nsError = error as NSError
                    TunnelEventStore.appendDiagnostic(
                        "saveToPreferences permission denied after stale-retry domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)"
                    )
                    throw TunnelControllerError.permissionDenied
                }
                throw error
            }
        }
    }

    private func isStaleConfigurationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 5 {
            return true
        }
        if nsError.domain == "NEVPNErrorDomain" && nsError.code == 4 {
            return true
        }
        return nsError.localizedDescription.lowercased().contains("stale")
    }

    private func isPermissionDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "NEConfigurationErrorDomain" && nsError.code == 10 {
            return true
        }
        if nsError.domain == "NEVPNErrorDomain" && nsError.code == 5 {
            return true
        }
        return nsError.localizedDescription.lowercased().contains("permission denied")
    }
}

private extension NETunnelProviderManager {
    static func loadAllFromPreferencesAsync() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NETunnelProviderManager], Error>) in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: managers ?? [])
            }
        }
    }

    func saveToPreferencesAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    func loadFromPreferencesAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    func removeFromPreferencesAsync() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            removeFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}
