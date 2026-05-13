import Foundation

enum TunnelMode: String, Codable, CaseIterable, Identifiable {
    case rule = "Rule"
    case global = "Global"

    var id: String { rawValue }
}
