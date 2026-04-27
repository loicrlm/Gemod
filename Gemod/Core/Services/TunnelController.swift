import Foundation
import NetworkExtension

enum TunnelControllerError: LocalizedError {
    case managerUnavailable
    case invalidConfiguration
    case startFailed
    case simulatorUnsupported
    case providerNotConnected
    case providerMessageFailed
    case tunnelStartTimeout

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
        case .tunnelStartTimeout:
            return AppLanguage.useSimplifiedChinese ? "隧道启动超时" : "Tunnel startup timed out"
        }
    }
}

final class TunnelController {
    private let providerBundleIdentifier: String
    private let appGroupIdentifier: String
    private let resetManagerOnStart: Bool

    init(
        providerBundleIdentifier: String = "com.gemod.Gemod.GemodTunnel",
        appGroupIdentifier: String = "group.com.gemod.Gemod",
        // 若每次连前都 removeFromPreferences，部分设备上系统长期停在 disconnected
        resetManagerOnStart: Bool = false
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
        self.appGroupIdentifier = appGroupIdentifier
        self.resetManagerOnStart = resetManagerOnStart
    }

    func startTunnel() async throws {
        #if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
        #endif
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
            try await manager.saveToPreferencesAsync()
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
    }

    func stopTunnel() async throws {
        TunnelEventStore.markUserInitiatedStop()
        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        appendManagerSnapshot(manager, source: "stopTunnel")
        manager.connection.stopVPNTunnel()
    }

    func currentStatus() async throws -> NEVPNStatus {
        #if targetEnvironment(simulator)
        return .disconnected
        #endif

        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        appendManagerSnapshot(manager, source: "currentStatus")
        return manager.connection.status
    }

    func sendProviderCommand(_ payload: [String: String]) async throws -> [String: String] {
        #if targetEnvironment(simulator)
        throw TunnelControllerError.simulatorUnsupported
        #endif

        let manager = try await loadOrCreateManager()
        try await manager.loadFromPreferencesAsync()
        appendManagerSnapshot(manager, source: "sendProviderCommand")
        guard let session = manager.connection as? NETunnelProviderSession else {
            TunnelEventStore.appendDiagnostic("send command failed: no provider session")
            throw TunnelControllerError.managerUnavailable
        }
        TunnelEventStore.appendStatusTimeline(session.status, source: "sendProviderCommand")
        if session.status == .connecting {
            try await waitUntilConnected(connection: manager.connection)
        }
        guard session.status == .connected || session.status == .reasserting else {
            TunnelEventStore.appendDiagnostic("send command blocked by status=\(session.status.rawValue)")
            throw TunnelControllerError.providerNotConnected
        }
        let requestData = try JSONSerialization.data(withJSONObject: payload)
        let responseData = try await sendProviderMessage(session: session, data: requestData)
        guard
            let responseData,
            let jsonObject = try JSONSerialization.jsonObject(with: responseData) as? [String: String]
        else {
            throw TunnelControllerError.providerMessageFailed
        }
        return jsonObject
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferencesAsync()
        if let existing = managers.first(where: { manager in
            guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                return false
            }
            return proto.providerBundleIdentifier == providerBundleIdentifier
        }) {
            return existing
        }

        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "Gemod Tunnel"
        proto.providerConfiguration = ["appGroup": appGroupIdentifier]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Gemod Tunnel"
        manager.isEnabled = true

        try await manager.saveToPreferencesAsync()
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
        data: Data
    ) async throws -> Data? {
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

    private func waitUntilConnected(
        connection: NEVPNConnection,
        timeout: TimeInterval = 20.0,
        interval: UInt64 = 200_000_000
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: nil
        ) { _ in
            TunnelEventStore.appendStatusTimeline(connection.status, source: "notify")
        }
        defer { NotificationCenter.default.removeObserver(observer) }

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

    private func appendManagerSnapshot(_ manager: NETunnelProviderManager, source: String) {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        let providerID = proto?.providerBundleIdentifier ?? "nil"
        let serverAddress = proto?.serverAddress ?? "nil"
        let statusText = statusText(manager.connection.status)
        TunnelEventStore.appendDiagnostic(
            "[\(source)] enabled=\(manager.isEnabled) status=\(statusText) providerID=\(providerID) server=\(serverAddress)"
        )
        appendConnectionSnapshot(manager.connection, source: source)
    }

    private func appendConnectionSnapshot(_ connection: NEVPNConnection, source: String) {
        let statusText = statusText(connection.status)
        TunnelEventStore.appendDiagnostic("[\(source)] status=\(statusText)")
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
