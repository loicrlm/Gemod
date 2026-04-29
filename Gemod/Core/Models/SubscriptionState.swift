import Foundation

enum ProxyMode: String, Codable, CaseIterable {
    case rule
    case global

    var displayName: String {
        switch self {
        case .rule:
            return AppLanguage.useSimplifiedChinese ? "规则" : "Rule"
        case .global:
            return AppLanguage.useSimplifiedChinese ? "全局" : "Global"
        }
    }
}

struct SubscriptionState: Codable {
    let url: String
    let nodes: [String]
    let selectedNode: String?
    let rawSubscriptionContent: String?
    let mode: ProxyMode
    let isConnected: Bool

    private enum CodingKeys: String, CodingKey {
        case url
        case nodes
        case selectedNode
        case rawSubscriptionContent
        case mode
        case isConnected
    }

    init(url: String, nodes: [String], selectedNode: String?, rawSubscriptionContent: String?, mode: ProxyMode, isConnected: Bool) {
        self.url = url
        self.nodes = nodes
        self.selectedNode = selectedNode
        self.rawSubscriptionContent = rawSubscriptionContent
        self.mode = mode
        self.isConnected = isConnected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        nodes = try container.decode([String].self, forKey: .nodes)
        selectedNode = try container.decodeIfPresent(String.self, forKey: .selectedNode)
        rawSubscriptionContent = try container.decodeIfPresent(String.self, forKey: .rawSubscriptionContent)
        mode = try container.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? .rule
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
    }
}
