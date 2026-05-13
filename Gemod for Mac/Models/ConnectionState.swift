import Foundation

enum ConnectionState: Codable, Equatable {
    case idle
    case connecting
    case connected(since: Date)
    case disconnecting
    case failed(message: String)

    var isBusy: Bool {
        switch self {
        case .connecting, .disconnecting:
            return true
        case .idle, .connected, .failed:
            return false
        }
    }

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }

    var title: String {
        switch self {
        case .idle:
            return NSLocalizedString("Not Connected", comment: "Connection state idle")
        case .connecting:
            return NSLocalizedString("Connecting", comment: "Connection state connecting")
        case .connected:
            return NSLocalizedString("Connected", comment: "Connection state connected")
        case .disconnecting:
            return NSLocalizedString("Disconnecting", comment: "Connection state disconnecting")
        case .failed:
            return NSLocalizedString("Connection Failed", comment: "Connection state failed")
        }
    }

    var detail: String? {
        switch self {
        case .connected(let since):
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return String(
                format: NSLocalizedString("Started at %@", comment: "Connection start time"),
                formatter.string(from: since)
            )
        case .failed(let message):
            return message
        case .idle, .connecting, .disconnecting:
            return nil
        }
    }
}
