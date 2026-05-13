import Foundation

struct TunnelRuntimeConfiguration: Codable, Equatable {
    var rawSubscription: String
    var selectedNodeName: String?
    var mode: TunnelMode
}

struct TunnelStatusSnapshot: Equatable {
    var connectionState: ConnectionState
    var healthStatus: HealthStatus
    var diagnosticMessage: String?
}

protocol CoreEngine: AnyObject {
    func connect(using configuration: TunnelRuntimeConfiguration) async throws -> TunnelStatusSnapshot
    func disconnect() async throws -> TunnelStatusSnapshot
    func testLatency(for nodes: [NodeItem], rawSubscription: String) async -> [LatencyMeasurement]
    func probeConnectivity() async -> HealthStatus
    func fetchDiagnostics() async -> [DiagnosticLogEntry]
}
