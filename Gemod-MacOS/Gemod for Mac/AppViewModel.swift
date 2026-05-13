import Combine
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
    @Published private(set) var subscription: SubscriptionRecord?
    @Published private(set) var mode: TunnelMode
    @Published private(set) var connectionState: ConnectionState
    @Published private(set) var healthStatus: HealthStatus
    @Published private(set) var diagnostics: [DiagnosticLogEntry]
    @Published private(set) var isImporting = false
    @Published private(set) var isTestingLatency = false
    @Published var importURLText: String = ""
    @Published var alertMessage: String?
    @Published var isImportSheetPresented = false
    @Published var isScannerPresented = false
    @Published var isCoreLogSheetPresented = false

    private let stateStore: AppStateStore
    private let importer: SubscriptionImporter
    private let clipboardSource: ClipboardSubscriptionSource
    private let realEngine: CoreEngine
    private let tunnelDiagnosticsStore: TunnelDiagnosticsStore

    init() {
        let stateStore = AppStateStore()
        let importer = SubscriptionImporter()
        let clipboardSource = ClipboardSubscriptionSource()
        let realEngine: CoreEngine = SingboxRealEngine()
        let tunnelDiagnosticsStore = TunnelDiagnosticsStore()

        self.stateStore = stateStore
        self.importer = importer
        self.clipboardSource = clipboardSource
        self.realEngine = realEngine
        self.tunnelDiagnosticsStore = tunnelDiagnosticsStore

        let snapshot = stateStore.load()
        self.subscription = snapshot.subscription
        self.mode = snapshot.mode
        self.connectionState = snapshot.connectionState
        self.healthStatus = snapshot.healthStatus
        self.diagnostics = Self.deduplicateDiagnosticsPreservingOrder(snapshot.diagnostics)
    }

    var selectedNodeID: UUID? {
        subscription?.selectedNodeID
    }

    var nodes: [NodeItem] {
        subscription?.nodes ?? []
    }

    var selectedNodeName: String? {
        subscription?.selectedNode?.name
    }

    var canConnect: Bool {
        subscription?.selectedNode != nil && !connectionState.isBusy
    }

    var statusSummary: String {
        connectionState.title
    }

    var subscriptionShortcut: String {
        guard let url = subscription?.sourceURL else {
            return NSLocalizedString("Not Imported", comment: "Subscription shortcut when none imported")
        }
        return Self.makeSubscriptionShortcut(from: url)
    }

    var appLogs: [DiagnosticLogEntry] {
        Self.deduplicateDiagnosticsPreservingOrder(diagnostics.filter { $0.category == .app })
    }

    var coreLogs: [DiagnosticLogEntry] {
        Self.deduplicateDiagnosticsPreservingOrder(diagnostics.filter { $0.category != .app })
    }

    func updateMode(_ newMode: TunnelMode) {
        guard mode != newMode else { return }
        mode = newMode
        appendDiagnostic(
            .app,
            String(format: NSLocalizedString("Mode switched to %@.", comment: "Mode switched log"), newMode.rawValue)
        )
        persist()

        // 热切换：已连接时在切换模式后立即重载连接配置。
        if connectionState.isConnected {
            appendDiagnostic(
                .tunnel,
                NSLocalizedString("Applying mode change to active tunnel...", comment: "Hot switch mode log")
            )
            Task { @MainActor in
                await connect()
            }
        }
    }

    func selectNode(_ nodeID: UUID) {
        guard var subscription else { return }
        subscription.selectedNodeID = nodeID
        self.subscription = subscription
        appendDiagnostic(
            .app,
            String(
                format: NSLocalizedString("Switched node to %@.", comment: "Node switched log"),
                subscription.selectedNode?.name ?? NSLocalizedString("Unknown Node", comment: "Unknown node fallback")
            )
        )
        persist()
    }

    func importFromManualURL() {
        let rawValue = importURLText
        Task {
            _ = await performImport(from: rawValue, silently: false)
        }
    }

    func importFromClipboard() {
        Task {
            do {
                let value = try clipboardSource.readURLString()
                importURLText = value
                _ = await performImport(from: value, silently: false)
            } catch {
                present(error)
            }
        }
    }

    func tryImportFromClipboardOrPresentSheet() {
        Task {
            let shouldPresentSheet = await tryImportFromClipboardSilently()
            if shouldPresentSheet {
                isImportSheetPresented = true
            }
        }
    }

    func disconnectThenTryImportFromClipboardOrPresentSheet() {
        Task {
            if connectionState.isBusy {
                appendDiagnostic(.importFlow, NSLocalizedString("Connection is busy. Import skipped for now.", comment: "Busy import log"))
                return
            }
            if connectionState.isConnected {
                appendDiagnostic(.importFlow, NSLocalizedString("Disconnecting current session before import.", comment: "Disconnect before import log"))
                await disconnect()
            }
            let shouldPresentSheet = await tryImportFromClipboardSilently()
            if shouldPresentSheet {
                isImportSheetPresented = true
            }
        }
    }

    func importFromScannedCode(_ payload: String) {
        Task {
            importURLText = payload
            isScannerPresented = false
            _ = await performImport(from: payload, silently: false)
        }
    }

    func toggleConnection() {
        switch connectionState {
        case .idle, .failed:
            Task { await connect() }
        case .connected:
            Task { await disconnect() }
        case .connecting, .disconnecting:
            break
        }
    }

    func testAllLatency() {
        guard !isTestingLatency, let subscription else { return }
        isTestingLatency = true
        appendDiagnostic(.latency, NSLocalizedString("Starting latency test for all nodes.", comment: "Latency test start log"))

        Task {
            let measurements = await currentEngine.testLatency(
                for: subscription.nodes,
                rawSubscription: subscription.rawContent
            )
            await MainActor.run {
                self.applyLatency(measurements)
                self.isTestingLatency = false
                self.persist()
            }
        }
    }

    func refreshDiagnostics() {
        Task {
            let health = await currentEngine.probeConnectivity()
            let logs = await currentEngine.fetchDiagnostics()
            await MainActor.run {
                self.healthStatus = health
                self.mergeDiagnostics(logs)
                self.mergeDiagnostics(self.tunnelDiagnosticsStore.load())
                self.persist()
            }
        }
    }

    func clearAlert() {
        alertMessage = nil
    }

    func toggleCoreLogSheet() {
        isCoreLogSheetPresented.toggle()
    }

    func clearCoreLogs() {
        diagnostics = diagnostics.filter { $0.category == .app }
        tunnelDiagnosticsStore.clear()
        persist()
    }

    var coreLogsPlainText: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return coreLogs.map { entry in
            let time = formatter.string(from: entry.timestamp)
            return "[\(entry.category.rawValue)] \(entry.message)\n\(time)"
        }.joined(separator: "\n\n")
    }

    private var currentEngine: CoreEngine {
        realEngine
    }

    private func performImport(from rawValue: String, silently: Bool) async -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        appendDiagnostic(.importFlow, NSLocalizedString("Starting subscription import.", comment: "Import start log"))

        do {
            try await disconnectBeforeImportIfNeeded()
            let result = try await importer.importFromURLString(rawValue)
            let record = SubscriptionRecord(
                sourceURL: result.sourceURL,
                rawContent: result.rawContent,
                nodes: result.nodes
            )
            subscription = record
            healthStatus = .unknown
            connectionState = .idle
            isImportSheetPresented = false
            isScannerPresented = false
            appendDiagnostic(
                .importFlow,
                String(
                    format: NSLocalizedString("Subscription imported successfully, %d nodes.", comment: "Import success log"),
                    record.nodes.count
                )
            )
            persist()
            isImporting = false
            return true
        } catch {
            if !silently {
                present(error)
            }
        }

        isImporting = false
        return false
    }

    private func tryImportFromClipboardSilently() async -> Bool {
        guard !isImporting else { return false }
        do {
            let value = try clipboardSource.readURLString()
            _ = try importer.validateURL(from: value)
            importURLText = value
            let imported = await performImport(from: value, silently: true)
            return !imported
        } catch {
            return true
        }
    }

    private func connect() async {
        guard !connectionState.isBusy else { return }
        guard let subscription, let selectedNode = subscription.selectedNode else {
            present(AppViewModelError.missingNode)
            return
        }

        connectionState = .connecting
        persist()

        do {
            let snapshot = try await currentEngine.connect(
                using: TunnelRuntimeConfiguration(
                    rawSubscription: subscription.rawContent,
                    selectedNodeName: selectedNode.name,
                    mode: mode
                )
            )
            connectionState = snapshot.connectionState
            healthStatus = snapshot.healthStatus
            if let message = snapshot.diagnosticMessage {
                appendDiagnostic(.tunnel, message)
            }
            let logs = await currentEngine.fetchDiagnostics()
            mergeDiagnostics(logs)
            mergeDiagnostics(tunnelDiagnosticsStore.load())
            persist()
        } catch {
            connectionState = .failed(message: error.localizedDescription)
            healthStatus = .offline
            mergeDiagnostics(tunnelDiagnosticsStore.load())
            present(error)
            persist()
        }
    }

    private func disconnect() async {
        guard !connectionState.isBusy else { return }
        connectionState = .disconnecting
        persist()

        do {
            let snapshot = try await currentEngine.disconnect()
            connectionState = snapshot.connectionState
            healthStatus = snapshot.healthStatus
            if let message = snapshot.diagnosticMessage {
                appendDiagnostic(.tunnel, message)
            }
            let logs = await currentEngine.fetchDiagnostics()
            mergeDiagnostics(logs)
            mergeDiagnostics(tunnelDiagnosticsStore.load())
            persist()
        } catch {
            connectionState = .failed(message: error.localizedDescription)
            healthStatus = .degraded
            mergeDiagnostics(tunnelDiagnosticsStore.load())
            present(error)
            persist()
        }
    }

    private func disconnectBeforeImportIfNeeded() async throws {
        guard connectionState.isConnected else { return }
        appendDiagnostic(.importFlow, NSLocalizedString("Disconnecting current session before import.", comment: "Disconnect before import log"))
        _ = try await currentEngine.disconnect()
        connectionState = .idle
    }

    private func applyLatency(_ measurements: [LatencyMeasurement]) {
        guard var subscription else { return }
        subscription.nodes = subscription.nodes.map { node in
            guard let measurement = measurements.first(where: { $0.nodeID == node.id }) else {
                return node
            }
            var updated = node
            updated.latencyMilliseconds = measurement.valueMilliseconds
            updated.lastTestedAt = measurement.testedAt
            return updated
        }
        self.subscription = subscription
        appendDiagnostic(.latency, NSLocalizedString("Latency test completed.", comment: "Latency test completion log"))
    }

    private static func deduplicateDiagnosticsPreservingOrder(_ entries: [DiagnosticLogEntry]) -> [DiagnosticLogEntry] {
        var seen = Set<UUID>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    private func mergeDiagnostics(_ logs: [DiagnosticLogEntry]) {
        guard !logs.isEmpty else { return }
        var seen = Set<UUID>()
        var merged: [DiagnosticLogEntry] = []
        for entry in logs + diagnostics where seen.insert(entry.id).inserted {
            merged.append(entry)
            if merged.count >= 50 { break }
        }
        diagnostics = merged
    }

    private func appendDiagnostic(_ category: DiagnosticCategory, _ message: String) {
        diagnostics.insert(DiagnosticLogEntry(category: category, message: message), at: 0)
        diagnostics = Array(diagnostics.prefix(50))
    }

    private func present(_ error: Error) {
        let message = error.localizedDescription
        alertMessage = message
        appendDiagnostic(.app, message)
    }

    private func persist() {
        stateStore.save(
            AppSnapshot(
                subscription: subscription,
                mode: mode,
                connectionState: connectionState,
                healthStatus: healthStatus,
                diagnostics: diagnostics
            )
        )
    }

    private static func makeSubscriptionShortcut(from url: URL) -> String {
        let normalizedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let subRange = normalizedPath.range(of: "sub/") {
            let suffix = String(normalizedPath[subRange.upperBound...])
            let firstPathComponent = suffix.split(separator: "/").first.map(String.init)
            if let firstPathComponent, !firstPathComponent.isEmpty {
                return firstPathComponent
            }
        }

        if !normalizedPath.isEmpty {
            return normalizedPath
        }

        if let host = url.host {
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }

        return url.absoluteString
    }
}

private enum AppViewModelError: LocalizedError {
    case missingNode

    var errorDescription: String? {
        switch self {
        case .missingNode:
            return NSLocalizedString("Please select a node first.", comment: "Missing node error")
        }
    }
}
