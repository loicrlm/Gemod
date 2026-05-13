import Foundation

enum TunnelMessageAction: String, Codable {
    case connect
    case disconnect
    case diagnostics
    case probe
    case status
    case latency
}

enum TunnelStartupPhase: String, Codable, Equatable {
    case idle
    case preparing
    case ready
    case failed
}

struct TunnelMessage: Codable {
    var action: TunnelMessageAction
    var configuration: TunnelRuntimeConfiguration?
    var timeoutMilliseconds: Int?
}

struct TunnelResponse: Codable {
    var connectionState: ConnectionState
    var healthStatus: HealthStatus
    var diagnostics: [DiagnosticLogEntry]
    var startupPhase: TunnelStartupPhase
    var startupErrorMessage: String?
    var latencyMilliseconds: Int?
}
