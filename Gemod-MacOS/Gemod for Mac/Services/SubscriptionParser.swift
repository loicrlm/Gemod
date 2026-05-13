import Foundation

enum SubscriptionParserError: LocalizedError {
    case unsupportedFormat
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return NSLocalizedString("Unable to recognize subscription content format.", comment: "Unsupported subscription format")
        case .emptyResult:
            return NSLocalizedString("No available nodes in the subscription.", comment: "Empty subscription result")
        }
    }
}

struct SubscriptionParser {
    private let proxyOutboundTypes: Set<String> = [
        "shadowsocks", "vmess", "vless", "trojan", "hysteria", "hysteria2",
        "tuic", "wireguard", "ssh", "socks", "http", "anytls", "shadowtls"
    ]

    func parseNodes(from rawContent: String) throws -> [NodeItem] {
        let trimmed = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SubscriptionParserError.emptyResult
        }

        if let decoded = decodeBase64IfPossible(trimmed) {
            let fromDecoded = try? parseNodes(fromPlainText: decoded)
            if let fromDecoded, !fromDecoded.isEmpty {
                return fromDecoded
            }
        }

        if let jsonNodes = try? parseNodes(fromJSON: trimmed), !jsonNodes.isEmpty {
            return jsonNodes
        }

        let textNodes = try parseNodes(fromPlainText: trimmed)
        guard !textNodes.isEmpty else {
            throw SubscriptionParserError.emptyResult
        }
        return textNodes
    }

    private func parseNodes(fromJSON rawContent: String) throws -> [NodeItem] {
        guard let data = rawContent.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SubscriptionParserError.unsupportedFormat
        }

        var names: [String] = []
        if let outbounds = object["outbounds"] as? [[String: Any]] {
            for outbound in outbounds {
                guard let type = outbound["type"] as? String else { continue }
                if isProxyOutbound(type: type), let tag = outbound["tag"] as? String, !tag.isEmpty {
                    names.append(tag)
                }
            }
        }

        return names.uniquePreservingOrder().map {
            NodeItem(name: $0, source: selectorSource(for: $0))
        }
    }

    private func parseNodes(fromPlainText rawContent: String) throws -> [NodeItem] {
        var names: [String] = []
        let lines = rawContent.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let yamlName = parseYAMLNodeName(from: trimmed) {
                names.append(yamlName)
                continue
            }

            if let uriName = parseURIName(from: trimmed) {
                names.append(uriName)
                continue
            }
        }

        let unique = names.uniquePreservingOrder()
        guard !unique.isEmpty else {
            throw SubscriptionParserError.unsupportedFormat
        }
        return unique.map { NodeItem(name: $0, source: selectorSource(for: $0)) }
    }

    private func parseYAMLNodeName(from line: String) -> String? {
        let patterns = [
            #"^-?\s*name:\s*["']?(.+?)["']?$"#,
            #"^-?\s*tag:\s*["']?(.+?)["']?$"#
        ]
        for pattern in patterns {
            if let matched = firstCapture(in: line, pattern: pattern) {
                return matched
            }
        }
        return nil
    }

    private func parseURIName(from line: String) -> String? {
        guard let range = line.range(of: "#") else { return nil }
        let suffix = String(line[range.upperBound...]).removingPercentEncoding ?? String(line[range.upperBound...])
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeBase64IfPossible(_ value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "\n", with: "")
        guard normalized.range(of: #"^[A-Za-z0-9+/=]+$"#, options: .regularExpression) != nil,
              let data = Data(base64Encoded: normalized),
              let decoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return decoded
    }

    private func firstCapture(in input: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: input.utf16.count)
        guard let match = regex.firstMatch(in: input, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: input) else {
            return nil
        }
        return String(input[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isProxyOutbound(type: String) -> Bool {
        proxyOutboundTypes.contains(type.lowercased())
    }

    private func selectorSource(for name: String) -> NodeSource {
        let lowercase = name.lowercased()
        if lowercase.contains("select") || lowercase.contains("auto") || lowercase.contains("urltest") {
            return .selector
        }
        return .subscription
    }
}

private extension Array where Element == String {
    func uniquePreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
