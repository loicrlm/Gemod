import Foundation

enum SubscriptionImportError: LocalizedError {
    case invalidURL
    case emptyClipboard
    case unsupportedClipboard
    case serverNotFound
    case timedOut
    case noInternet
    case secureConnectionFailed
    case invalidResponse
    case serverError(statusCode: Int)
    case networkFailure

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("Please enter a valid HTTP or HTTPS subscription URL.", comment: "Invalid URL")
        case .emptyClipboard:
            return NSLocalizedString("No subscription URL found in the clipboard.", comment: "Empty clipboard")
        case .unsupportedClipboard:
            return NSLocalizedString("Clipboard content is not a valid subscription URL.", comment: "Unsupported clipboard")
        case .serverNotFound:
            return NSLocalizedString("Subscription server not found. Check the domain or IP in the URL.", comment: "Server not found")
        case .timedOut:
            return NSLocalizedString("Subscription request timed out. Please try again later.", comment: "Timeout")
        case .noInternet:
            return NSLocalizedString("Network is unavailable. Please check your system connection.", comment: "No internet")
        case .secureConnectionFailed:
            return NSLocalizedString("Secure connection to the subscription server failed. Check HTTPS settings.", comment: "TLS error")
        case .invalidResponse:
            return NSLocalizedString("Subscription server returned invalid content.", comment: "Invalid response")
        case .serverError(let statusCode):
            return String(
                format: NSLocalizedString("Subscription server returned status code: %d.", comment: "HTTP status error"),
                statusCode
            )
        case .networkFailure:
            return NSLocalizedString("Failed to fetch subscription. Please try again later.", comment: "Network failure")
        }
    }
}

struct SubscriptionImportResult {
    var sourceURL: URL
    var rawContent: String
    var nodes: [NodeItem]
}

struct SubscriptionImporter {
    private let session: URLSession
    private let parser: SubscriptionParser
    private let userAgent = "Gemod/"

    init(session: URLSession = .shared, parser: SubscriptionParser = SubscriptionParser()) {
        self.session = session
        self.parser = parser
    }

    func validateURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw SubscriptionImportError.invalidURL
        }
        return url
    }

    func importFromURLString(_ rawValue: String) async throws -> SubscriptionImportResult {
        let url = try validateURL(from: rawValue)
        return try await importFromURL(url)
    }

    func importFromURL(_ url: URL) async throws -> SubscriptionImportResult {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw map(error)
        } catch {
            throw SubscriptionImportError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse,
              let rawContent = String(data: data, encoding: .utf8) else {
            throw SubscriptionImportError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SubscriptionImportError.serverError(statusCode: httpResponse.statusCode)
        }

        let nodes = try parser.parseNodes(from: rawContent)
        return SubscriptionImportResult(sourceURL: url, rawContent: rawContent, nodes: nodes)
    }

    private func map(_ error: URLError) -> SubscriptionImportError {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .serverNotFound
        case .timedOut:
            return .timedOut
        case .notConnectedToInternet, .networkConnectionLost, .internationalRoamingOff:
            return .noInternet
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnectionFailed
        default:
            return .networkFailure
        }
    }
}
