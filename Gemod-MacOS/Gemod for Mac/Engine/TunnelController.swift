import Foundation
import NetworkExtension

enum TunnelControllerError: LocalizedError {
    case unavailable
    case providerUnavailable
    case invalidResponse
    case providerStartupFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return NSLocalizedString("System tunnel controller is currently unavailable.", comment: "Controller unavailable")
        case .providerUnavailable:
            return NSLocalizedString("Tunnel provider is not ready yet.", comment: "Provider unavailable")
        case .invalidResponse:
            return NSLocalizedString("Received an invalid tunnel response.", comment: "Invalid tunnel response")
        case .providerStartupFailed(let message):
            return String(
                format: NSLocalizedString("Tunnel provider startup failed: %@.", comment: "Provider startup failed"),
                message
            )
        }
    }
}

actor TunnelController {
    private let managerBundleIdentifier = "com.gemod.Gemod-for-Mac.tunnel"
    private let appGroupIdentifier = "group.com.gemod.shared"
    private let providerBackend = "singbox"
    private let providerResponseRetryCount = 6
    private let providerResponseRetryDelayNanoseconds: UInt64 = 150_000_000

    func connect(using configuration: TunnelRuntimeConfiguration) async throws -> TunnelStatusSnapshot {
        let manager = try await loadManager()
        try await saveIfNeeded(manager)
        let session = try session(from: manager)
        do {
            try await startTunnelIfNeeded(using: manager)
            _ = try await waitUntilProviderReady(session)
            let response = try await send(
                .init(action: .connect, configuration: configuration, timeoutMilliseconds: nil),
                through: session,
                requireActiveTunnel: true
            )
            if !response.connectionState.isConnected {
                manager.connection.stopVPNTunnel()
                try? await waitUntilTunnelInactive(manager.connection)
                let message = response.diagnostics.first?.message
                    ?? response.startupErrorMessage
                    ?? NSLocalizedString("System tunnel connection failed.", comment: "Tunnel connection failed")
                throw TunnelControllerError.providerStartupFailed(message)
            }
            return TunnelStatusSnapshot(
                connectionState: response.connectionState,
                healthStatus: response.healthStatus,
                diagnosticMessage: response.diagnostics.first?.message
            )
        } catch {
            // 连接任一阶段失败都主动停止系统隧道，避免 UI 与系统设置状态不一致。
            if isTunnelActive(manager.connection.status) {
                manager.connection.stopVPNTunnel()
                try? await waitUntilTunnelInactive(manager.connection)
            }
            throw error
        }
    }

    func disconnect() async throws -> TunnelStatusSnapshot {
        let manager = try await loadManager()
        let session = try session(from: manager)
        guard isTunnelActive(manager.connection.status) else {
            return TunnelStatusSnapshot(
                connectionState: .idle,
                healthStatus: .unknown,
                diagnosticMessage: NSLocalizedString("System tunnel is not running.", comment: "Tunnel not running")
            )
        }
        let response: TunnelResponse
        do {
            response = try await send(
                .init(action: .disconnect, configuration: nil, timeoutMilliseconds: nil),
                through: session,
                requireActiveTunnel: true
            )
        } catch {
            // 即使 provider 消息链路异常，也继续执行系统级 stop，避免设置里残留已连接状态。
            response = TunnelResponse(
                connectionState: .idle,
                healthStatus: .unknown,
                diagnostics: [],
                startupPhase: .idle,
                startupErrorMessage: nil,
                latencyMilliseconds: nil
            )
        }
        manager.connection.stopVPNTunnel()
        try await waitUntilTunnelInactive(manager.connection)
        return TunnelStatusSnapshot(
            connectionState: response.connectionState,
            healthStatus: response.healthStatus,
            diagnosticMessage: response.diagnostics.first?.message
        )
    }

    func diagnostics() async throws -> [DiagnosticLogEntry] {
        let manager = try await loadManager()
        let session = try session(from: manager)
        return try await send(
            .init(action: .diagnostics, configuration: nil, timeoutMilliseconds: nil),
            through: session,
            requireActiveTunnel: true
        ).diagnostics
    }

    func probe() async throws -> HealthStatus {
        let manager = try await loadManager()
        let session = try session(from: manager)
        return try await send(
            .init(action: .probe, configuration: nil, timeoutMilliseconds: nil),
            through: session,
            requireActiveTunnel: true
        ).healthStatus
    }

    func status() async throws -> TunnelResponse {
        let manager = try await loadManager()
        let session = try session(from: manager)
        return try await send(
            .init(action: .status, configuration: nil, timeoutMilliseconds: nil),
            through: session,
            requireActiveTunnel: true
        )
    }

    func latency(nodeName: String, rawSubscription: String, timeoutMilliseconds: Int = 1800) async throws -> Int? {
        let manager = try await loadManager()
        try await saveIfNeeded(manager)
        let session = try session(from: manager)
        try await startTunnelIfNeeded(using: manager)
        _ = try await waitUntilProviderReady(session)
        let response = try await send(
            .init(
                action: .latency,
                configuration: TunnelRuntimeConfiguration(
                    rawSubscription: rawSubscription,
                    selectedNodeName: nodeName,
                    mode: .rule
                ),
                timeoutMilliseconds: timeoutMilliseconds
            ),
            through: session,
            requireActiveTunnel: true
        )
        return response.latencyMilliseconds
    }

    private func send(
        _ message: TunnelMessage,
        through session: NETunnelProviderSession,
        requireActiveTunnel: Bool
    ) async throws -> TunnelResponse {
        if requireActiveTunnel && !isTunnelActive(session.status) {
            throw TunnelControllerError.providerUnavailable
        }

        let data = try JSONEncoder().encode(message)
        let responseData = try await sendProviderMessage(
            data,
            through: session,
            remainingAttempts: providerResponseRetryCount
        )

        return try JSONDecoder().decode(TunnelResponse.self, from: responseData)
    }

    private func loadManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == managerBundleIdentifier
        }) {
            return manager
        }

        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = managerBundleIdentifier
        proto.serverAddress = "Gemod Tunnel"
        proto.providerConfiguration = [
            "appGroup": appGroupIdentifier,
            "transport": "tun",
            "backend": providerBackend
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Gemod Tunnel"
        manager.isEnabled = true
        return manager
    }

    private func saveIfNeeded(_ manager: NETunnelProviderManager) async throws {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            throw TunnelControllerError.unavailable
        }
        proto.providerBundleIdentifier = managerBundleIdentifier
        proto.serverAddress = "Gemod Tunnel"
        proto.providerConfiguration = [
            "appGroup": appGroupIdentifier,
            "transport": "tun",
            "backend": providerBackend
        ]
        manager.protocolConfiguration = proto
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    private func session(from manager: NETunnelProviderManager) throws -> NETunnelProviderSession {
        guard let session = manager.connection as? NETunnelProviderSession else {
            throw TunnelControllerError.providerUnavailable
        }
        return session
    }

    private func startTunnelIfNeeded(using manager: NETunnelProviderManager) async throws {
        if isTunnelActive(manager.connection.status) {
            return
        }
        try manager.connection.startVPNTunnel()
        try await waitUntilTunnelActive(manager.connection)
    }

    private func waitUntilProviderReady(_ session: NETunnelProviderSession) async throws -> TunnelResponse {
        var lastStartupError: String?
        for _ in 0..<15 {
            do {
                let response = try await send(
                    .init(action: .status, configuration: nil, timeoutMilliseconds: nil),
                    through: session,
                    requireActiveTunnel: true
                )
                switch response.startupPhase {
                case .ready:
                    return response
                case .failed:
                    throw TunnelControllerError.providerStartupFailed(
                        response.startupErrorMessage ?? NSLocalizedString("No detailed error provided.", comment: "No startup detail")
                    )
                case .idle, .preparing:
                    lastStartupError = response.startupErrorMessage
                }
            } catch TunnelControllerError.invalidResponse {
                // provider 刚启动时可能还未进入可响应状态，继续等待
            }
            try await Task.sleep(nanoseconds: 150_000_000)
        }

        if let lastStartupError, !lastStartupError.isEmpty {
            throw TunnelControllerError.providerStartupFailed(lastStartupError)
        }
        throw TunnelControllerError.providerUnavailable
    }

    private func waitUntilTunnelActive(_ connection: NEVPNConnection) async throws {
        for _ in 0..<20 {
            if isTunnelActive(connection.status) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TunnelControllerError.providerUnavailable
    }

    private func waitUntilTunnelInactive(_ connection: NEVPNConnection) async throws {
        for _ in 0..<20 {
            if !isTunnelActive(connection.status) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw TunnelControllerError.providerUnavailable
    }

    private func sendProviderMessage(
        _ data: Data,
        through session: NETunnelProviderSession,
        remainingAttempts: Int
    ) async throws -> Data {
        do {
            let responseData = try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(data) { response in
                        if let response {
                            continuation.resume(returning: response)
                        } else {
                            continuation.resume(throwing: TunnelControllerError.invalidResponse)
                        }
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            return responseData
        } catch TunnelControllerError.invalidResponse where remainingAttempts > 1 {
            try await Task.sleep(nanoseconds: providerResponseRetryDelayNanoseconds)
            return try await sendProviderMessage(
                data,
                through: session,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private func isTunnelActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connected, .connecting, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting:
            return false
        @unknown default:
            return false
        }
    }
}
