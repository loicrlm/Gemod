import Foundation

struct SubscriptionRecord: Codable, Equatable {
    var sourceURL: URL
    var rawContent: String
    var nodes: [NodeItem]
    var selectedNodeID: NodeItem.ID?
    var importedAt: Date

    var selectedNode: NodeItem? {
        guard let selectedNodeID else { return nil }
        return nodes.first(where: { $0.id == selectedNodeID })
    }

    init(
        sourceURL: URL,
        rawContent: String,
        nodes: [NodeItem],
        selectedNodeID: NodeItem.ID? = nil,
        importedAt: Date = Date()
    ) {
        self.sourceURL = sourceURL
        self.rawContent = rawContent
        self.nodes = nodes
        self.selectedNodeID = selectedNodeID ?? nodes.first?.id
        self.importedAt = importedAt
    }
}
