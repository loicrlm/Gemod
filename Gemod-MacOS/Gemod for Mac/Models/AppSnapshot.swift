import Foundation

struct AppSnapshot: Codable, Equatable {
    var subscription: SubscriptionRecord?
    var mode: TunnelMode
    var connectionState: ConnectionState
    var healthStatus: HealthStatus
    var diagnostics: [DiagnosticLogEntry]

    static let empty = AppSnapshot(
        subscription: nil,
        mode: .rule,
        connectionState: .idle,
        healthStatus: .unknown,
        diagnostics: []
    )
}
