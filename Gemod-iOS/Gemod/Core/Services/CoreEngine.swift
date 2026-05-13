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
        let candidates = [
            "https://cp.cloudflare.com/generate_204",
            "https://www.gstatic.com/generate_204"
        ]
        for rawURL in candidates {
            guard let url = URL(string: rawURL) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let start = CFAbsoluteTimeGetCurrent()
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                    return Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
