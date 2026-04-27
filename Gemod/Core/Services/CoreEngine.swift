import Foundation

protocol CoreEngine: Sendable {
    /// 仅真实 sing-box controller 需要 Packet Tunnel；Mock 路线不启动隧道。
    var requiresPacketTunnel: Bool { get }

    func healthCheck() async -> Bool
    func connect(node: String, mode: ProxyMode) async throws
    func disconnect() async throws
    func testLatency(node: String, timeout: TimeInterval) async -> Int?
}

final class SingboxMockEngine: CoreEngine, @unchecked Sendable {
    var requiresPacketTunnel: Bool { false }

    func healthCheck() async -> Bool { true }

    func connect(node: String, mode: ProxyMode) async throws {
        _ = (node, mode)
    }

    func disconnect() async throws {}

    func testLatency(node: String, timeout: TimeInterval) async -> Int? {
        _ = node
        var request = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = CFAbsoluteTimeGetCurrent()
        do {
            _ = try await URLSession.shared.data(for: request)
            return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        } catch {
            return nil
        }
    }
}
