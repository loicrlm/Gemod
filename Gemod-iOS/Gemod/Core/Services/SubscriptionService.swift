import Foundation

enum SubscriptionServiceError: LocalizedError {
    case invalidURL
    case networkFailure
    case httpStatus(Int)
    case invalidResponse
    case emptySubscription
    case missingVerifyCode
    case verifyCodeMismatch

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return AppLanguage.useSimplifiedChinese ? "订阅链接无效" : "Invalid subscription URL"
        case .networkFailure:
            return AppLanguage.useSimplifiedChinese ? "网络请求失败，请检查网络后重试" : "Network request failed, please try again"
        case .httpStatus(let statusCode):
            return AppLanguage.useSimplifiedChinese
                ? "订阅请求失败（HTTP \(statusCode)）"
                : "Subscription request failed (HTTP \(statusCode))"
        case .invalidResponse:
            return AppLanguage.useSimplifiedChinese ? "订阅内容无效" : "Invalid subscription content"
        case .emptySubscription:
            return AppLanguage.useSimplifiedChinese ? "未解析到节点" : "No nodes found"
        case .missingVerifyCode, .verifyCodeMismatch:
            return AppLanguage.useSimplifiedChinese
                ? "此订阅与当前应用不匹配，请使用Gemod Pro"
                : "This subscription does not match the current app. Please use Gemod Pro."
        }
    }
}

protocol SubscriptionService {
    func fetchSubscription(from urlString: String) async throws -> SubscriptionContent
}

struct SubscriptionContent {
    let nodes: [String]
    let rawText: String
}

final class MihomoSubscriptionService: SubscriptionService {
    #if GEMOD_FREE
    private enum VerifyHeader {
        static let primary = "X-Subscription-Verify"
    }
    #endif

    private static let internalTags: Set<String> = [
        "direct", "block", "dns-out", "dns", "selector", "urltest", "auto"
    ]
    private static let proxyTypes: Set<String> = [
        "shadowsocks", "vmess", "vless", "trojan", "hysteria", "hysteria2",
        "tuic", "wireguard", "ssh", "socks", "http", "anytls", "shadowtls"
    ]
    private static let groupTypes: Set<String> = [
        "selector", "urltest", "fallback", "loadbalance"
    ]

    #if GEMOD_FREE
    /// Build-time injected expected value from Info.plist key `GEMOD_HTTP_VERIFY_CODE`.
    /// Real value should be supplied via local/private xcconfig and excluded from public repo.
    private var expectedVerifyCode: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "GEMOD_HTTP_VERIFY_CODE") as? String else {
            return nil
        }
        let value = normalizedVerifyCode(raw)
        return value.isEmpty ? nil : value
    }
    #endif

    func fetchSubscription(from urlString: String) async throws -> SubscriptionContent {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw SubscriptionServiceError.invalidURL
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw SubscriptionServiceError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw SubscriptionServiceError.httpStatus(httpResponse.statusCode)
            }
            throw SubscriptionServiceError.invalidResponse
        }

        #if GEMOD_FREE
        try validateVerifyCode(from: httpResponse)
        #endif

        guard let rawText = String(data: data, encoding: .utf8), !rawText.isEmpty else {
            throw SubscriptionServiceError.invalidResponse
        }

        let nodes = parseNodeNames(from: rawText)
        guard !nodes.isEmpty else {
            throw SubscriptionServiceError.emptySubscription
        }

        return SubscriptionContent(nodes: nodes, rawText: rawText)
    }

    #if GEMOD_FREE
    private func validateVerifyCode(from response: HTTPURLResponse) throws {
        guard let expected = expectedVerifyCode else {
            // Safe fallback: if expected value isn't injected, treat as mismatch to block import.
            throw SubscriptionServiceError.verifyCodeMismatch
        }
        let received = response.value(forHTTPHeaderField: VerifyHeader.primary)
            .map(normalizedVerifyCode(_:))

        guard let received, !received.isEmpty else {
            throw SubscriptionServiceError.missingVerifyCode
        }
        guard received == expected else {
            throw SubscriptionServiceError.verifyCodeMismatch
        }
    }

    private func normalizedVerifyCode(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    #endif

    private func parseNodeNames(from text: String) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Support sing-box JSON subscription format first.
        if let jsonNames = parseNodeNamesFromJSON(text: trimmedText), !jsonNames.isEmpty {
            return jsonNames
        }

        var names: [String] = []
        let lines = text.components(separatedBy: .newlines)
        let pattern = #"^\s*-\s*name\s*:\s*(.+?)\s*$|^\s*name\s*:\s*(.+?)\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern)

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex?.firstMatch(in: line, range: range) else {
                continue
            }

            let candidate1 = match.range(at: 1)
            let candidate2 = match.range(at: 2)

            let name: String
            if let swiftRange = Range(candidate1, in: line) {
                name = String(line[swiftRange])
            } else if let swiftRange = Range(candidate2, in: line) {
                name = String(line[swiftRange])
            } else {
                continue
            }

            let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespacesAndNewlines))
            if !trimmed.isEmpty {
                names.append(trimmed)
            }
        }

        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }

    private func parseNodeNamesFromJSON(text: String) -> [String]? {
        guard text.first == "{" || text.first == "[" else { return nil }
        guard let data = text.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let outbounds: [[String: Any]]
        if let dict = json as? [String: Any],
           let value = dict["outbounds"] as? [[String: Any]] {
            outbounds = value
        } else if let value = json as? [[String: Any]] {
            outbounds = value
        } else {
            return nil
        }

        guard !outbounds.isEmpty else { return nil }

        var proxyTags: [String] = []
        var groupTags: [String] = []

        for outbound in outbounds {
            guard let tag = normalizedTag(from: outbound) else { continue }
            let type = (outbound["type"] as? String)?.lowercased()

            if let type, Self.proxyTypes.contains(type) {
                proxyTags.append(tag)
                continue
            }
            if let type, Self.groupTypes.contains(type) {
                groupTags.append(tag)
            }
        }

        // Prefer real proxy nodes. If absent, fall back to group tags.
        let selected = proxyTags.isEmpty ? groupTags : proxyTags
        return unique(selected)
    }

    private func normalizedTag(from outbound: [String: Any]) -> String? {
        guard let rawTag = outbound["tag"] as? String else { return nil }
        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }
        if Self.internalTags.contains(tag.lowercased()) {
            return nil
        }
        return tag
    }

    private func unique(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values)) as? [String] ?? values
    }
}
