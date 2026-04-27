import Foundation
import NetworkExtension

enum SingboxRealEngineError: LocalizedError {
    case providerRejected(String)

    var errorDescription: String? {
        switch self {
        case .providerRejected(let message):
            if message.isEmpty {
                return AppLanguage.useSimplifiedChinese ? "核心命令执行失败" : "Core command failed"
            }
            return message
        }
    }
}

final class SingboxRealEngine: CoreEngine, @unchecked Sendable {
    var requiresPacketTunnel: Bool { true }

    private let tunnelController: TunnelController

    init(
        tunnelController: TunnelController = TunnelController()
    ) {
        self.tunnelController = tunnelController
    }

    func healthCheck() async -> Bool {
        let status = try? await tunnelController.currentStatus()
        guard status == .connected || status == .reasserting else {
            return true
        }
        do {
            let response = try await tunnelController.sendProviderCommand(["command": "health"])
            return response["status"] == "ok"
        } catch {
            return false
        }
    }

    func connect(node: String, mode: ProxyMode) async throws {
        let response = try await tunnelController.sendProviderCommand([
            "command": "connect",
            "node": node,
            "mode": mode.rawValue
        ])
        guard response["status"] == "ok" else {
            throw SingboxRealEngineError.providerRejected(response["message"] ?? "connect rejected")
        }
    }

    func disconnect() async throws {
        let response = try await tunnelController.sendProviderCommand([
            "command": "disconnect"
        ])
        guard response["status"] == "ok" else {
            throw SingboxRealEngineError.providerRejected(response["message"] ?? "disconnect rejected")
        }
    }

    func testLatency(node: String, timeout: TimeInterval) async -> Int? {
        await SingboxMockEngine().testLatency(node: node, timeout: timeout)
    }
}
