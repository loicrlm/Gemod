import Foundation

actor SingboxRealEngine: CoreEngine {
    private let controller: TunnelController
    private var lastDiagnostics: [DiagnosticLogEntry] = []

    init(controller: TunnelController = TunnelController()) {
        self.controller = controller
    }

    func connect(using configuration: TunnelRuntimeConfiguration) async throws -> TunnelStatusSnapshot {
        let snapshot = try await controller.connect(using: configuration)
        lastDiagnostics = try await controller.diagnostics()
        return snapshot
    }

    func disconnect() async throws -> TunnelStatusSnapshot {
        let snapshot = try await controller.disconnect()
        // disconnect 后 provider 可能已停止，diagnostics 调用允许失败，保留已有日志即可。
        if let logs = try? await controller.diagnostics() {
            lastDiagnostics = logs
        }
        return snapshot
    }

    func testLatency(for nodes: [NodeItem], rawSubscription: String) async -> [LatencyMeasurement] {
        var measurements: [LatencyMeasurement] = []
        measurements.reserveCapacity(nodes.count)
        for node in nodes {
            let latency = try? await controller.latency(
                nodeName: node.name,
                rawSubscription: rawSubscription,
                timeoutMilliseconds: 1800
            )
            measurements.append(
                LatencyMeasurement(
                    nodeID: node.id,
                    valueMilliseconds: latency,
                    isReachable: latency != nil
                )
            )
        }
        return measurements
    }

    func probeConnectivity() async -> HealthStatus {
        (try? await controller.probe()) ?? .offline
    }

    func fetchDiagnostics() async -> [DiagnosticLogEntry] {
        if let logs = try? await controller.diagnostics() {
            lastDiagnostics = logs
        }
        return lastDiagnostics
    }
}
