import Foundation

enum TunnelMode: String, Codable {
    case rule = "Rule"
    case global = "Global"
}

enum HealthStatus: String, Codable {
    case unknown
    case healthy
    case degraded
    case offline
}

enum ConnectionState: Codable, Equatable {
    case idle
    case connecting
    case connected(since: Date)
    case disconnecting
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting:
            return true
        case .idle, .connected, .failed:
            return false
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

struct DiagnosticLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), category: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

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

struct TunnelRuntimeConfiguration: Codable, Equatable {
    var rawSubscription: String
    var selectedNodeName: String?
    var mode: TunnelMode
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
