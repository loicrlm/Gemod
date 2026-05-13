import Foundation

enum HealthStatus: String, Codable, Equatable {
    case unknown
    case healthy
    case degraded
    case offline

    var title: String {
        switch self {
        case .unknown:
            return NSLocalizedString("Pending", comment: "Health status unknown")
        case .healthy:
            return NSLocalizedString("Healthy", comment: "Health status healthy")
        case .degraded:
            return NSLocalizedString("Degraded", comment: "Health status degraded")
        case .offline:
            return NSLocalizedString("Offline", comment: "Health status offline")
        }
    }
}
