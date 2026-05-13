import Foundation

struct TunnelDiagnosticsStore {
    private let appGroupID = "group.com.gemod.shared"
    private let legacyDefaultsKey = "gemod.tunnel.diagnostics"
    private let fileName = "tunnel-diagnostics.json"

    private var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// See main app `TunnelDiagnosticsStore` — avoids `UserDefaults(suiteName:)` and CFPrefs warnings.
    private func legacyPlistDiagnosticsData() -> Data? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        let plistURL = container
            .appendingPathComponent("Library/Preferences/\(appGroupID).plist", isDirectory: false)
        guard FileManager.default.fileExists(atPath: plistURL.path),
              let dict = NSDictionary(contentsOf: plistURL) as? [String: Any],
              let data = dict[legacyDefaultsKey] as? Data else {
            return nil
        }
        return data
    }

    func append(_ category: String, _ message: String) {
        let entry = DiagnosticLogEntry(category: category, message: message)
        let existing = load()
        let merged = Array(([entry] + existing).prefix(50))
        saveToFile(merged)
    }

    func load() -> [DiagnosticLogEntry] {
        if let url = fileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           !data.isEmpty,
           let logs = try? JSONDecoder().decode([DiagnosticLogEntry].self, from: data) {
            return logs
        }

        if let data = legacyPlistDiagnosticsData(),
           let logs = try? JSONDecoder().decode([DiagnosticLogEntry].self, from: data) {
            saveToFile(logs)
            return logs
        }

        return []
    }

    private func saveToFile(_ logs: [DiagnosticLogEntry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(logs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
