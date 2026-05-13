import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let diagnosticsStore = TunnelDiagnosticsStore()
    private lazy var backend: TunnelBackend = RealSingboxTunnelBackend(tunnelProvider: self)
    private var runtime = ProviderRuntime()

    override func startTunnel(options: [String: NSObject]?) async throws {
        runtime.startupPhase = .preparing
        runtime.startupErrorMessage = nil
        diagnosticsStore.append("tunnel", "Packet Tunnel 启动中，准备应用最小网络设置。")

        do {
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
            let ipv4Settings = NEIPv4Settings(
                addresses: ["198.18.0.1"],
                subnetMasks: ["255.255.255.255"]
            )
            // 先不接管任何实际流量，只验证 provider 能否正常启动并响应 App 消息。
            ipv4Settings.includedRoutes = []
            settings.ipv4Settings = ipv4Settings
            settings.mtu = 1500 as NSNumber

            try await setTunnelNetworkSettings(settings)
            let snapshot = await backend.reset(
                environment: providerEnvironment,
                diagnosticsStore: diagnosticsStore
            )
            runtime.connectionState = snapshot.connectionState
            runtime.healthStatus = snapshot.healthStatus
            runtime.startupPhase = .ready
            diagnosticsStore.append("tunnel", "Packet Tunnel 已启动，最小网络设置已应用。")
        } catch {
            runtime.startupPhase = .failed
            runtime.startupErrorMessage = error.localizedDescription
            diagnosticsStore.append("tunnel", "Packet Tunnel 启动失败：\(error.localizedDescription)")
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        let snapshot = await backend.disconnect(diagnosticsStore: diagnosticsStore)
        runtime.connectionState = snapshot.connectionState
        runtime.healthStatus = snapshot.healthStatus
        runtime.startupPhase = .idle
        runtime.startupErrorMessage = nil
        diagnosticsStore.append("tunnel", "Packet Tunnel 已停止，原因：\(reason.rawValue)。")
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(TunnelMessage.self, from: messageData) else {
            return nil
        }

        var latencyMilliseconds: Int?

        switch message.action {
        case .connect:
            guard let configuration = message.configuration else { return nil }
            diagnosticsStore.append(
                "tunnel",
                "收到 connect 指令，节点：\(configuration.selectedNodeName ?? "未选择")，模式：\(configuration.mode.rawValue)。"
            )
            let snapshot = await backend.connect(using: configuration, diagnosticsStore: diagnosticsStore)
            runtime.connectionState = snapshot.connectionState
            runtime.healthStatus = snapshot.healthStatus
        case .disconnect:
            diagnosticsStore.append("tunnel", "收到 disconnect 指令。")
            let snapshot = await backend.disconnect(diagnosticsStore: diagnosticsStore)
            runtime.connectionState = snapshot.connectionState
            runtime.healthStatus = snapshot.healthStatus
        case .diagnostics:
            diagnosticsStore.append("tunnel", "收到 diagnostics 指令。")
        case .probe:
            let snapshot = await backend.probe(diagnosticsStore: diagnosticsStore)
            runtime.connectionState = snapshot.connectionState
            runtime.healthStatus = snapshot.healthStatus
            diagnosticsStore.append("connectivity", "收到 probe 指令，当前状态：\(runtime.healthStatus.rawValue)。")
        case .status:
            let snapshot = await backend.status()
            runtime.connectionState = snapshot.connectionState
            runtime.healthStatus = snapshot.healthStatus
        case .latency:
            guard let configuration = message.configuration else { return nil }
            let result = await backend.latency(
                using: configuration,
                timeoutMilliseconds: message.timeoutMilliseconds ?? 1800,
                diagnosticsStore: diagnosticsStore
            )
            runtime.connectionState = result.snapshot.connectionState
            runtime.healthStatus = result.snapshot.healthStatus
            latencyMilliseconds = result.latencyMilliseconds
        }

        let response = TunnelResponse(
            connectionState: runtime.connectionState,
            healthStatus: runtime.healthStatus,
            diagnostics: diagnosticsStore.load(),
            startupPhase: runtime.startupPhase,
            startupErrorMessage: runtime.startupErrorMessage,
            latencyMilliseconds: latencyMilliseconds
        )
        return try? JSONEncoder().encode(response)
    }

    private var providerEnvironment: TunnelProviderEnvironment {
        let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return TunnelProviderEnvironment(
            appGroup: config?["appGroup"] as? String,
            backend: (config?["backend"] as? String) ?? "singbox",
            transport: (config?["transport"] as? String) ?? "tun"
        )
    }
}

private struct ProviderRuntime {
    var connectionState: ConnectionState = .idle
    var healthStatus: HealthStatus = .unknown
    var startupPhase: TunnelStartupPhase = .idle
    var startupErrorMessage: String?
}
