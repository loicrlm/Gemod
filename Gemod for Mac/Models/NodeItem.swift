import Foundation

struct NodeItem: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var source: NodeSource
    var latencyMilliseconds: Int?
    var lastTestedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        source: NodeSource = .subscription,
        latencyMilliseconds: Int? = nil,
        lastTestedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.latencyMilliseconds = latencyMilliseconds
        self.lastTestedAt = lastTestedAt
    }
}

enum NodeSource: String, Codable, CaseIterable {
    case subscription
    case selector
}
