import Foundation
import NetworkExtension

struct TunnelEventStore {
    static let appGroupIdentifier = "group.com.gemod.Gemod"

    /// 与扩展共用；勿再用 `UserDefaults(suiteName: appGroup)`，会触发 cfprefsd 且 Container 未就绪时反复告警。
    private static let sharedStateFileName = "tunnel_app_group_state.json"

    private struct AppGroupSharedState: Codable {
        var userInitiatedStop: Bool
        var lastStopReasonRaw: Int
        var lastStopTimestamp: TimeInterval
        var pendingNotice: Bool

        static let initial = AppGroupSharedState(
            userInitiatedStop: false,
            lastStopReasonRaw: -1,
            lastStopTimestamp: 0,
            pendingNotice: false
        )
    }

    private static func appGroupContainerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static func sharedStateFileURL() -> URL? {
        appGroupContainerURL()?.appendingPathComponent(sharedStateFileName)
    }

    private static func loadSharedState() -> AppGroupSharedState {
        guard
            let url = sharedStateFileURL(),
            let data = try? Data(contentsOf: url)
        else { return .initial }
        return (try? JSONDecoder().decode(AppGroupSharedState.self, from: data)) ?? .initial
    }

    private static func saveSharedState(_ state: AppGroupSharedState) {
        guard let url = sharedStateFileURL() else { return }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    static func markUserInitiatedStop() {
        var s = loadSharedState()
        s.userInitiatedStop = true
        saveSharedState(s)
    }

    static func clearUserInitiatedStopFlag() {
        var s = loadSharedState()
        s.userInitiatedStop = false
        saveSharedState(s)
    }

    static func consumeUserInitiatedStopFlag() -> Bool {
        var s = loadSharedState()
        let flag = s.userInitiatedStop
        s.userInitiatedStop = false
        saveSharedState(s)
        return flag
    }

    static func saveLastStopReason(_ reason: NEProviderStopReason) {
        var s = loadSharedState()
        s.lastStopReasonRaw = reason.rawValue
        s.lastStopTimestamp = Date().timeIntervalSince1970
        s.pendingNotice = true
        saveSharedState(s)
    }

    static func consumeLastStopReason() -> NEProviderStopReason? {
        var s = loadSharedState()
        guard s.pendingNotice else { return nil }
        let raw = s.lastStopReasonRaw
        s.pendingNotice = false
        saveSharedState(s)
        return NEProviderStopReason(rawValue: raw)
    }

    private static let sharedLogFileName = "tunnel_diagnostics.log"
    private static let maxLogLines = 200

    /// 诊断用文件写入 App Group 容器。勿用 suite UserDefaults 存长诊断列表（易触发 cfprefsd 的 Container null 问题）。
    static func appendDiagnostic(_ message: String) {
        appendSharedLogLine(kind: "D", message)
    }

    static func latestDiagnostic() -> String? {
        for line in readSharedLogLines().reversed() {
            let marker = " | D|"
            if let range = line.range(of: marker) {
                return String(line[range.upperBound...])
            }
        }
        return nil
    }

    static func latestExtensionDiagnostic() -> String? {
        for line in readSharedLogLines().reversed() {
            let marker = " | D|"
            guard let range = line.range(of: marker) else { continue }
            let message = String(line[range.upperBound...])
            if message.contains("[ext]") {
                return message
            }
        }
        return nil
    }

    static func recentExtensionDiagnostics(limit: Int = 3, containing needle: String? = nil) -> String {
        let marker = " | D|"
        let matches: [String] = readSharedLogLines().compactMap { line in
            guard let range = line.range(of: marker) else { return nil }
            let message = String(line[range.upperBound...])
            guard message.contains("[ext]") else { return nil }
            if let needle, !needle.isEmpty, !message.localizedCaseInsensitiveContains(needle) {
                return nil
            }
            return message
        }
        let recent = matches.suffix(limit)
        return recent.isEmpty ? "-" : recent.joined(separator: " || ")
    }

    static func recentLibboxDiagnostics(limit: Int = 3) -> String {
        recentExtensionDiagnostics(limit: limit, containing: "libbox:")
    }

    static func recentLibboxDiagnosticLines(limit: Int = 200) -> [String] {
        let marker = " | D|"
        let matches: [String] = readSharedLogLines().compactMap { line in
            guard let range = line.range(of: marker) else { return nil }
            let message = String(line[range.upperBound...])
            guard message.contains("[ext]"), message.localizedCaseInsensitiveContains("libbox:") else {
                return nil
            }
            return line
        }
        return Array(matches.suffix(limit))
    }

    static func appendStatusTimeline(_ status: NEVPNStatus, source: String) {
        let body = "[\(source)] \(statusText(status))"
        appendSharedLogLine(kind: "T", body)
    }

    static func latestStatusTimeline(limit: Int = 8) -> String {
        let marker = " | T|"
        let tLines: [String] = readSharedLogLines().compactMap { line in
            guard let r = line.range(of: marker) else { return nil }
            return String(line[r.upperBound...])
        }
        return tLines.suffix(limit).joined(separator: " | ")
    }

    static func clearDiagnostics() {
        guard
            let url = sharedLogFileURL(),
            FileManager.default.fileExists(atPath: url.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func sharedLogFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(sharedLogFileName)
    }

    private static func appendSharedLogLine(kind: String, _ message: String) {
        guard let url = sharedLogFileURL() else {
            NSLog("[Gemod] app group 容器不可用，请检查 entitlements 与描述文件: \(appGroupIdentifier)")
            return
        }
        var lines = readSharedLogLines()
        lines.append("\(timestamp()) | \(kind)|\(message)")
        if lines.count > maxLogLines {
            lines = Array(lines.suffix(maxLogLines))
        }
        if let data = lines.joined(separator: "\n").data(using: .utf8) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func readSharedLogLines() -> [String] {
        guard
            let url = sharedLogFileURL(),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func statusText(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
