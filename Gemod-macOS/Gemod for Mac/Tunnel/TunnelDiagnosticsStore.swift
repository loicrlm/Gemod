import Foundation

struct TunnelDiagnosticsStore {
    private let appGroupID = "group.com.gemod.shared"
    private let legacyDefaultsKey = "gemod.tunnel.diagnostics"
    private let fileName = "tunnel-diagnostics.json"

    private var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Reads legacy data written by older builds via `UserDefaults(suiteName:)` **without** calling
    /// `UserDefaults`, to avoid CFPrefs / `kCFPreferencesAnyUser` console noise.
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
            persistToFile(logs)
            return logs
        }

        return []
    }

    func clear() {
        guard let url = fileURL else { return }
        try? Data().write(to: url, options: .atomic)
    }

    private func persistToFile(_ logs: [DiagnosticLogEntry]) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(logs) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
