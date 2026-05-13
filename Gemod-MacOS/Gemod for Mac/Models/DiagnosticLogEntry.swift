import Foundation

struct DiagnosticLogEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticCategory,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

enum DiagnosticCategory: String, Codable, CaseIterable {
    case app
    case tunnel
    case connectivity
    case latency
    case importFlow = "import"
}
