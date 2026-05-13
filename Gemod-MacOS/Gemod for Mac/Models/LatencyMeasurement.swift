import Foundation

struct LatencyMeasurement: Codable, Equatable, Identifiable {
    let id: UUID
    let nodeID: UUID
    let valueMilliseconds: Int?
    let testedAt: Date
    let isReachable: Bool

    init(
        id: UUID = UUID(),
        nodeID: UUID,
        valueMilliseconds: Int?,
        testedAt: Date = Date(),
        isReachable: Bool
    ) {
        self.id = id
        self.nodeID = nodeID
        self.valueMilliseconds = valueMilliseconds
        self.testedAt = testedAt
        self.isReachable = isReachable
    }
}
