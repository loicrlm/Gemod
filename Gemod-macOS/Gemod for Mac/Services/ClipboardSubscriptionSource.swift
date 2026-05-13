import AppKit

struct ClipboardSubscriptionSource {
    func readURLString() throws -> String {
        let pasteboard = NSPasteboard.general
        guard let value = pasteboard.string(forType: .string) else {
            throw SubscriptionImportError.emptyClipboard
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SubscriptionImportError.emptyClipboard
        }
        return trimmed
    }
}
