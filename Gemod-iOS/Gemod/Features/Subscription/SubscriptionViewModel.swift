import Foundation
import Combine
import UIKit
import NetworkExtension

@MainActor
final class SubscriptionViewModel: ObservableObject {
    enum ConnectionPhase: Equatable {
        case idle
        case connecting
        case connected
        case disconnecting
        case failed
    }

    @Published var subscriptionURL: String = ""
    @Published private(set) var nodes: [String] = []
    @Published private(set) var savedSubscriptionURL: String = ""
    @Published private(set) var selectedNode: String?
    @Published private(set) var rawSubscriptionContent: String?
    @Published private(set) var mode: ProxyMode = .rule
    @Published private(set) var isConnected = false
    @Published private(set) var isCoreHealthy = true
    @Published private(set) var isLoading = false
    @Published private(set) var isPreparingImport = false
    @Published private(set) var isTestingLatency = false
    @Published private(set) var nodeLatencyText: [String: String] = [:]
    @Published private(set) var coreLogLines: [String] = []
    @Published private(set) var connectionPhase: ConnectionPhase = .idle
    @Published var errorMessage: String?
    @Published var interruptionNoticeMessage: String?
    private let service: SubscriptionService
    private let store: SubscriptionStore
    private let engine: CoreEngine
    private let tunnelController: TunnelController
    private var cancellables = Set<AnyCancellable>()
    private var userInitiatedDisconnectInFlight = false

    init(
        service: SubscriptionService,
        store: SubscriptionStore,
        engine: CoreEngine,
        tunnelController: TunnelController
    ) {
        self.service = service
        self.store = store
        self.engine = engine
        self.tunnelController = tunnelController
        restoreLocalState()

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.refreshCoreHealth()
                    await self.refreshConnectionState()
                    self.checkTunnelInterruptionNotice()
                }
            }
            .store(in: &cancellables)

#if !targetEnvironment(simulator)
        NotificationCenter.default.publisher(for: Notification.Name("NEVPNStatusDidChange"))
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.refreshCoreHealth()
                    await self.refreshConnectionState()
                    self.checkTunnelInterruptionNotice()
                }
            }
            .store(in: &cancellables)
#endif

        Task {
            await refreshCoreHealth()
            await refreshConnectionState()
            checkTunnelInterruptionNotice()
        }
    }

    convenience init(engine: CoreEngine) {
        self.init(
            service: MihomoSubscriptionService(),
            store: UserDefaultsSubscriptionStore(),
            engine: engine,
            tunnelController: TunnelController()
        )
    }

    convenience init() {
        self.init(engine: SingboxMockEngine())
    }

    func importSubscription() async {
        await importSubscription(from: subscriptionURL)
    }

    func importSubscription(from inputURL: String) async {
        let cleanedURL = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedURL.isEmpty else {
            errorMessage = AppLanguage.useSimplifiedChinese ? "请输入订阅链接" : "Please enter subscription URL"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fetched = try await service.fetchSubscription(from: cleanedURL)
            let normalizedNodes = uniqueValues(fetched.nodes)
            let newSelectedNode = normalizedNodes.first

            let newState = SubscriptionState(
                url: cleanedURL,
                nodes: normalizedNodes,
                selectedNode: newSelectedNode,
                rawSubscriptionContent: fetched.rawText,
                mode: mode,
                isConnected: false
            )
            try store.save(newState)
            subscriptionURL = cleanedURL
            savedSubscriptionURL = cleanedURL
            nodes = normalizedNodes
            selectedNode = newSelectedNode
            rawSubscriptionContent = fetched.rawText
            isConnected = false
            connectionPhase = .idle
            nodeLatencyText = [:]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFromClipboard() async {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            errorMessage = AppLanguage.useSimplifiedChinese ? "剪切板中没有有效订阅链接" : "No valid subscription URL in clipboard"
            return
        }
        await importSubscription(from: value)
    }

    func prepareForImport() async {
        guard !isPreparingImport else { return }
        isPreparingImport = true
        errorMessage = nil
        defer { isPreparingImport = false }
        do {
            try await ensureDisconnectedBeforeImport()
        } catch {
            errorMessage = buildConnectionErrorMessage(error)
        }
    }

    func selectNode(_ node: String) {
        guard nodes.contains(node) else { return }
        guard selectedNode != node else { return }
        guard !isConnectionBusy else { return }
        let previousNode = selectedNode
        selectedNode = node
        persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存节点选择失败" : "Failed to save selected node")
        guard isConnected else { return }
        Task {
            errorMessage = nil
            connectionPhase = .connecting
            do {
                try await engine.connect(node: node, mode: mode)
                isConnected = true
                connectionPhase = .connected
                await refreshCoreHealth()
                await refreshConnectionState()
                await syncSelectedNodeWithRuntimeIfNeeded(source: "selectNode")
                _ = await verifyInternetReachabilityIfNeeded()
                persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存节点选择失败" : "Failed to save selected node")
            } catch {
                let rollbackSucceeded: Bool
                if let previousNode {
                    rollbackSucceeded = (try? await engine.connect(node: previousNode, mode: mode)) != nil
                } else {
                    rollbackSucceeded = false
                }
                selectedNode = previousNode
                if rollbackSucceeded {
                    isConnected = true
                    connectionPhase = .connected
                    errorMessage = AppLanguage.useSimplifiedChinese
                        ? "切换节点失败，已自动回退到原节点"
                        : "Node switch failed and was rolled back to previous node"
                } else {
                    isConnected = false
                    connectionPhase = .failed
                    errorMessage = buildConnectionErrorMessage(error)
                }
                persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存节点选择失败" : "Failed to save selected node")
            }
        }
    }

    func setMode(_ newMode: ProxyMode) {
        mode = newMode
        persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存模式失败" : "Failed to save mode")
    }

    func connectSelectedNode() {
        guard selectedNode != nil else {
            errorMessage = AppLanguage.useSimplifiedChinese ? "请先选择节点" : "Please select a node first"
            return
        }
        guard !isConnectionBusy else { return }
        Task {
            errorMessage = nil
            var didStartConnectFlow = false
            var didStartUserInitiatedDisconnect = false
            defer {
                if didStartUserInitiatedDisconnect {
                    userInitiatedDisconnectInFlight = false
                }
            }
            do {
                if isConnected {
                    didStartUserInitiatedDisconnect = true
                    userInitiatedDisconnectInFlight = true
                    connectionPhase = .disconnecting
                    try await engine.disconnect()
                    if engine.requiresPacketTunnel {
                        try await tunnelController.stopTunnel()
                    }
                    if !engine.requiresPacketTunnel {
                        isConnected = false
                        connectionPhase = .idle
                    }
                } else if let node = selectedNode {
                    didStartConnectFlow = true
                    connectionPhase = .connecting
                    if engine.requiresPacketTunnel {
                        try await tunnelController.startTunnel()
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    try await engine.connect(node: node, mode: mode)
                    if !engine.requiresPacketTunnel {
                        isConnected = true
                        connectionPhase = .connected
                    }
                }
                await refreshCoreHealth()
                await refreshConnectionState()
                await syncSelectedNodeWithRuntimeIfNeeded(source: "connectSelectedNode")
                await verifyInternetReachabilityIfNeeded()
                persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存连接状态失败" : "Failed to save connection state")
            } catch {
                if didStartConnectFlow && engine.requiresPacketTunnel {
                    // If connect flow fails (e.g. sing-box backend not ready), force tunnel teardown
                    // so UI state does not remain "connected" while connect action already failed.
                    try? await tunnelController.stopTunnel()
                    await refreshConnectionState()
                } else if didStartConnectFlow {
                    isConnected = false
                }
                connectionPhase = .failed
                errorMessage = buildConnectionErrorMessage(error)
            }
        }
    }

    func testAllLatencies() async {
        guard !nodes.isEmpty else {
            errorMessage = AppLanguage.useSimplifiedChinese ? "暂无可测试节点" : "No nodes to test"
            return
        }
        guard !isConnectionBusy else { return }

        isTestingLatency = true
        nodeLatencyText = [:]
        defer { isTestingLatency = false }

        let testingNodes = nodes
        let useChinese = AppLanguage.useSimplifiedChinese
        let timeoutText = useChinese ? "超时" : "timeout"

        if engine.requiresPacketTunnel {
            do {
                if !isConnected {
                    try await ensureConnectedForLatencyTest()
                }
            } catch {
                connectionPhase = .failed
                errorMessage = buildConnectionErrorMessage(error)
                return
            }
        }

        await withTaskGroup(of: (String, String).self) { group in
            var nextIndex = 0
            let maxConcurrent = engine.requiresPacketTunnel
                ? min(4, testingNodes.count)
                : min(6, testingNodes.count)

            for _ in 0..<maxConcurrent {
                let node = testingNodes[nextIndex]
                nextIndex += 1
                group.addTask {
                    let latency = await Self.measureLatencyText(for: node, engine: self.engine, timeoutText: timeoutText)
                    return (node, latency)
                }
            }

            while let (node, latency) = await group.next() {
                nodeLatencyText[node] = latency
                if nextIndex < testingNodes.count {
                    let nextNode = testingNodes[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        let nextLatency = await Self.measureLatencyText(for: nextNode, engine: self.engine, timeoutText: timeoutText)
                        return (nextNode, nextLatency)
                    }
                }
            }
        }

        if engine.requiresPacketTunnel {
            let allTimeoutNodes = testingNodes.filter { nodeLatencyText[$0] == timeoutText }
            let fallbackNodes = Array(allTimeoutNodes.prefix(4))
            if !fallbackNodes.isEmpty {
                await testLatenciesViaActiveTunnelFallback(nodes: fallbackNodes, timeoutText: timeoutText)
            }
            if allTimeoutNodes.count > fallbackNodes.count {
                TunnelEventStore.appendDiagnostic(
                    "latency fallback limited processed=\(fallbackNodes.count) skipped=\(allTimeoutNodes.count - fallbackNodes.count)"
                )
            }
        }

        let timeoutCount = nodeLatencyText.values.filter { $0 == timeoutText }.count
        if timeoutCount == testingNodes.count {
            let diagnostic = TunnelEventStore.latestDiagnostic() ?? "-"
            let ext = TunnelEventStore.latestExtensionDiagnostic() ?? "-"
            let libbox = compactDiagnosticPart(TunnelEventStore.recentLibboxDiagnostics(limit: 1), maxLength: 120)
            let delayAPIRejected = diagnostic.contains("status=503") || ext.contains("status=503")
            if delayAPIRejected {
                errorMessage = AppLanguage.useSimplifiedChinese
                    ? "延迟测试接口返回 503（不是普通超时） | 诊断: \(diagnostic) | 扩展: \(ext) | libbox: \(libbox)"
                    : "Latency API returned 503 (not a plain timeout) | Diagnostic: \(diagnostic) | Extension: \(ext) | libbox: \(libbox)"
            } else {
                errorMessage = AppLanguage.useSimplifiedChinese
                    ? "延迟测试全部超时 | 诊断: \(diagnostic) | 扩展: \(ext) | libbox: \(libbox)"
                    : "All latency tests timed out | Diagnostic: \(diagnostic) | Extension: \(ext) | libbox: \(libbox)"
            }
        } else {
            errorMessage = nil
        }
    }

    func latencyText(for node: String) -> String? {
        nodeLatencyText[node]
    }

    func refreshCoreHealth() async {
        isCoreHealthy = await engine.healthCheck()
    }

    func refreshCoreLogs() {
        coreLogLines = TunnelEventStore.recentLibboxDiagnosticLines(limit: 200)
    }

    func clearCoreLogs() {
        TunnelEventStore.clearDiagnostics()
        coreLogLines = []
    }

    func refreshConnectionState() async {
        guard engine.requiresPacketTunnel else {
            connectionPhase = isConnected ? .connected : .idle
            return
        }
        do {
            let status = try await tunnelController.currentStatus()
            switch status {
            case .connected, .reasserting:
                isConnected = true
                connectionPhase = .connected
                await syncSelectedNodeWithRuntimeIfNeeded(source: "refreshConnectionState")
            case .connecting:
                isConnected = false
                connectionPhase = .connecting
            case .disconnecting:
                isConnected = false
                connectionPhase = .disconnecting
            default:
                isConnected = false
                if connectionPhase != .failed {
                    connectionPhase = .idle
                }
            }
        } catch {
            isConnected = false
            if connectionPhase != .failed {
                connectionPhase = .idle
            }
        }
    }

    func clearInterruptionNotice() {
        interruptionNoticeMessage = nil
    }

    private static func measureLatencyText(for node: String, engine: CoreEngine, timeoutText: String) async -> String {
        guard let ms = await engine.testLatency(node: node, timeout: 6.0) else {
            return timeoutText
        }
        return "\(ms)ms"
    }

    private func testLatenciesViaActiveTunnelFallback(nodes fallbackNodes: [String], timeoutText: String) async {
        let originalNode = selectedNode
        for node in fallbackNodes {
            if let ms = await measureActiveTunnelHTTPLatency(for: node, timeout: 2.8) {
                nodeLatencyText[node] = "\(ms)ms"
            } else {
                nodeLatencyText[node] = timeoutText
            }
        }

        guard let originalNode, isConnected else { return }
        do {
            try await engine.connect(node: originalNode, mode: mode)
            await syncSelectedNodeWithRuntimeIfNeeded(source: "latencyFallbackRestore")
        } catch {
            TunnelEventStore.appendDiagnostic("latency fallback restore failed node=\(originalNode) error=\(error.localizedDescription)")
            await syncSelectedNodeWithRuntimeIfNeeded(source: "latencyFallbackRestoreFailed")
            errorMessage = buildConnectionErrorMessage(error)
        }
    }

    private func measureActiveTunnelHTTPLatency(for node: String, timeout: TimeInterval) async -> Int? {
        do {
            try await engine.connect(node: node, mode: mode)
            try await Task.sleep(nanoseconds: 150_000_000)
        } catch {
            TunnelEventStore.appendDiagnostic("latency fallback switch failed node=\(node) error=\(error.localizedDescription)")
            return nil
        }

        guard let url = URL(string: "https://www.google.com.hk") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
                TunnelEventStore.appendDiagnostic("latency fallback http status invalid node=\(node)")
                return nil
            }
            let latency = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            TunnelEventStore.appendDiagnostic("latency fallback ok node=\(node) url=https://www.google.com.hk ms=\(latency)")
            return max(1, latency)
        } catch {
            TunnelEventStore.appendDiagnostic("latency fallback request failed node=\(node) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func uniqueValues(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private func compactDiagnosticPart(_ text: String, maxLength: Int) -> String {
        guard maxLength > 8 else { return text }
        guard text.count > maxLength else { return text }
        let headCount = maxLength / 2 - 1
        let tailCount = maxLength - headCount - 3
        return "\(text.prefix(headCount))...\(text.suffix(max(1, tailCount)))"
    }

    private func ensureDisconnectedBeforeImport() async throws {
        if engine.requiresPacketTunnel {
            let status = try? await tunnelController.currentStatus()
            let shouldStopTunnel =
                isConnected ||
                status == .connected ||
                status == .reasserting ||
                status == .connecting ||
                status == .disconnecting

            if shouldStopTunnel {
                userInitiatedDisconnectInFlight = true
                defer { userInitiatedDisconnectInFlight = false }
                connectionPhase = .disconnecting
                do {
                    try await engine.disconnect()
                } catch {
                    // If proxy command fails, still try to stop tunnel from system side.
                }
                try await tunnelController.stopTunnel()
            }
        } else if isConnected {
            connectionPhase = .disconnecting
            try await engine.disconnect()
        }

        isConnected = false
        connectionPhase = .idle
    }

    private func checkTunnelInterruptionNotice() {
        if let notice = TunnelEventStore.consumeInterruptionNotice() {
            interruptionNoticeMessage = localizedInterruptionMessage(for: notice)
            return
        }
        if let reason = TunnelEventStore.consumeLastStopReason() {
            interruptionNoticeMessage = localizedInterruptionMessage(for: reason)
            return
        }
        checkUnexpectedTunnelTerminationFallback()
    }

    private func checkUnexpectedTunnelTerminationFallback() {
        guard engine.requiresPacketTunnel else { return }
        guard !userInitiatedDisconnectInFlight else { return }
        guard !isConnected, connectionPhase != .disconnecting else { return }
        guard let storedState = store.load(), storedState.isConnected else { return }

        interruptionNoticeMessage = AppLanguage.useSimplifiedChinese
            ? "检测到 VPN 隧道意外停止，可能是系统回收后台或扩展异常退出，请重新连接。"
            : "Detected that the VPN tunnel stopped unexpectedly. The system may have reclaimed the extension or the extension may have exited unexpectedly. Please reconnect."
        persistUnexpectedDisconnectState()
    }

    private func persistUnexpectedDisconnectState() {
        do {
            let state = SubscriptionState(
                url: savedSubscriptionURL,
                nodes: nodes,
                selectedNode: selectedNode,
                rawSubscriptionContent: rawSubscriptionContent,
                mode: mode,
                isConnected: false
            )
            try store.save(state)
        } catch {
            TunnelEventStore.appendDiagnostic("persist unexpected disconnect state failed: \(error.localizedDescription)")
        }
    }

    private func localizedInterruptionMessage(for notice: TunnelEventStore.InterruptionNotice) -> String {
        let detail = notice.message.trimmingCharacters(in: .whitespacesAndNewlines)
        switch notice.source.lowercased() {
        case "core":
            if AppLanguage.useSimplifiedChinese {
                return detail.isEmpty
                    ? "检测到核心后台已停止，请重新连接。"
                    : "检测到核心后台已停止（\(detail)），请重新连接。"
            }
            return detail.isEmpty
                ? "Core backend stopped. Please reconnect."
                : "Core backend stopped (\(detail)). Please reconnect."
        case "tunnel":
            if AppLanguage.useSimplifiedChinese {
                return detail.isEmpty
                    ? "检测到隧道后台已停止，请重新连接。"
                    : "检测到隧道后台已停止（\(detail)），请重新连接。"
            }
            return detail.isEmpty
                ? "Tunnel backend stopped. Please reconnect."
                : "Tunnel backend stopped (\(detail)). Please reconnect."
        default:
            if AppLanguage.useSimplifiedChinese {
                return detail.isEmpty
                    ? "检测到代理后台已停止，请重新连接。"
                    : "检测到代理后台已停止（\(detail)），请重新连接。"
            }
            return detail.isEmpty
                ? "Proxy backend stopped. Please reconnect."
                : "Proxy backend stopped (\(detail)). Please reconnect."
        }
    }

    private func localizedInterruptionMessage(for reason: NEProviderStopReason) -> String {
        if AppLanguage.useSimplifiedChinese {
            return "检测到代理后台已停止（\(localizedReasonText(reason))），请重新连接。"
        }
        return "Proxy backend stopped (\(localizedReasonText(reason))). Please reconnect."
    }

    private func localizedReasonText(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .noNetworkAvailable:
            return AppLanguage.useSimplifiedChinese ? "无可用网络" : "No network"
        case .providerFailed, .connectionFailed:
            return AppLanguage.useSimplifiedChinese ? "代理服务异常" : "Provider failure"
        case .idleTimeout:
            return AppLanguage.useSimplifiedChinese ? "空闲超时" : "Idle timeout"
        case .sleep:
            return AppLanguage.useSimplifiedChinese ? "设备休眠" : "Device sleep"
        case .appUpdate:
            return AppLanguage.useSimplifiedChinese ? "应用更新" : "App update"
        case .superceded:
            return AppLanguage.useSimplifiedChinese ? "被新配置替代" : "Superseded"
        default:
            return AppLanguage.useSimplifiedChinese ? "系统回收后台" : "Stopped by system"
        }
    }

    private func restoreLocalState() {
        guard let state = store.load() else { return }
        subscriptionURL = state.url
        savedSubscriptionURL = state.url
        nodes = state.nodes
        selectedNode = state.selectedNode.flatMap { state.nodes.contains($0) ? $0 : state.nodes.first } ?? state.nodes.first
        rawSubscriptionContent = state.rawSubscriptionContent
        mode = state.mode
        isConnected = state.isConnected
        connectionPhase = state.isConnected ? .connected : .idle
    }

    var connectionStatusText: String {
        switch connectionPhase {
        case .idle:
            return AppLanguage.useSimplifiedChinese ? "未连接" : "Disconnected"
        case .connecting:
            return AppLanguage.useSimplifiedChinese ? "连接中" : "Connecting"
        case .connected:
            return AppLanguage.useSimplifiedChinese ? "已连接" : "Connected"
        case .disconnecting:
            return AppLanguage.useSimplifiedChinese ? "断开中" : "Disconnecting"
        case .failed:
            return AppLanguage.useSimplifiedChinese ? "连接失败" : "Connection Failed"
        }
    }

    var isConnectionBusy: Bool {
        connectionPhase == .connecting || connectionPhase == .disconnecting
    }

    var connectionButtonText: String {
        switch connectionPhase {
        case .connecting:
            return AppLanguage.useSimplifiedChinese ? "连接中..." : "Connecting..."
        case .disconnecting:
            return AppLanguage.useSimplifiedChinese ? "断开中..." : "Disconnecting..."
        case .connected:
            return AppLanguage.useSimplifiedChinese ? "断开" : "Disconnect"
        case .idle, .failed:
            return AppLanguage.useSimplifiedChinese ? "连接" : "Connect"
        }
    }

    var isDisconnectActionActive: Bool {
        connectionPhase == .connected || connectionPhase == .disconnecting
    }

    private func persistState(errorText: String) {
        do {
            let state = SubscriptionState(
                url: savedSubscriptionURL,
                nodes: nodes,
                selectedNode: selectedNode,
                rawSubscriptionContent: rawSubscriptionContent,
                mode: mode,
                isConnected: isConnected
            )
            try store.save(state)
        } catch {
            errorMessage = errorText
        }
    }

    private func ensureConnectedForLatencyTest() async throws {
        let targetNode = selectedNode ?? nodes.first
        guard let targetNode else {
            throw SingboxRealEngineError.providerRejected(
                AppLanguage.useSimplifiedChinese ? "请先选择节点" : "Please select a node first"
            )
        }
        if selectedNode == nil {
            selectedNode = targetNode
            persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存节点选择失败" : "Failed to save selected node")
        }

        connectionPhase = .connecting
        if engine.requiresPacketTunnel {
            try await tunnelController.startTunnel()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try await engine.connect(node: targetNode, mode: mode)
        await refreshCoreHealth()
        await refreshConnectionState()
        await syncSelectedNodeWithRuntimeIfNeeded(source: "ensureConnectedForLatencyTest")
        await verifyInternetReachabilityIfNeeded()
        persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存连接状态失败" : "Failed to save connection state")
    }

    private func syncSelectedNodeWithRuntimeIfNeeded(source: String) async {
        guard engine.requiresPacketTunnel, isConnected, !isConnectionBusy else { return }
        guard !nodes.isEmpty else { return }
        guard let status = try? await tunnelController.sendProviderCommand(["command": "status"]) else { return }
        guard status["status"] == "ok" else { return }
        guard let runtimeNode = resolveRuntimeNode(from: status) else { return }
        guard runtimeNode != selectedNode else { return }

        selectedNode = runtimeNode
        TunnelEventStore.appendDiagnostic("sync selected node from runtime source=\(source) runtime=\(runtimeNode)")
        persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存节点选择失败" : "Failed to save selected node")
    }

    private func resolveRuntimeNode(from status: [String: String]) -> String? {
        // Prefer backend `node` (RealSingboxProxyBackend.currentNode / connect result) over Clash
        // `selector_current`, which reads `/proxies/gemod-active` and can lag briefly after a switch
        // or disagree with subscription tag spelling — that mismatch caused the UI to snap back.
        let candidates: [String?] = [
            status["node"],
            status["selector_current"]
        ]
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            if value == "gemod-active" { continue }
            if let exact = nodes.first(where: { $0 == value }) {
                return exact
            }
            let normalized = normalizeNodeTag(value)
            if let normalizedMatch = nodes.first(where: { normalizeNodeTag($0) == normalized }) {
                return normalizedMatch
            }
        }
        return nil
    }

    private func normalizeNodeTag(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
    }

    @discardableResult
    private func verifyInternetReachabilityIfNeeded() async -> Bool {
        guard engine.requiresPacketTunnel, isConnected else { return true }
        if let node = selectedNode {
            let latency = await engine.testLatency(node: node, timeout: 4.0)
            if latency != nil {
                return true
            }
        }
        var detail = ""
        if let status = try? await tunnelController.sendProviderCommand(["command": "status"]) {
            let node = status["node"] ?? "-"
            let phase = status["startup_phase"] ?? "-"
            let backend = status["backend"] ?? "-"
            let ready = status["ready"] ?? "-"
            let outbound = status["active_outbound"] ?? "-"
            let outboundType = status["active_outbound_type"] ?? "-"
            let tls = status["active_tls"] ?? "-"
            let sni = status["active_sni"] ?? "-"
            let server = status["active_server"] ?? "-"
            let routeFinal = status["route_final"] ?? "-"
            let source = status["config_source"] ?? "-"
            let selectedPath = status["selected_path"] ?? "-"
            let selectorCurrent = status["selector_current"] ?? "-"
            let dnsFinal = status["dns_final"] ?? "-"
            let dnsServers = status["dns_servers"] ?? "-"
            let dnsRuleServers = status["dns_rule_servers"] ?? "-"
            let dnsProbe = status["dns_probe"] ?? "-"
            let routeRulesMode = status["route_rules_mode"] ?? "-"
            let routeRulesCount = status["route_rules_count"] ?? "-"
            let rulesetMode = status["ruleset_mode"] ?? "-"
            let rulesetLocal = status["ruleset_local_count"] ?? "0"
            let rulesetDownloaded = status["ruleset_downloaded_count"] ?? "0"
            let rulesetCached = status["ruleset_cached_count"] ?? "0"
            let rulesetRemoved = status["ruleset_removed_count"] ?? "0"
            let compactDNSServers = compactDiagnosticPart(dnsServers, maxLength: 90)
            let compactDNSRules = compactDiagnosticPart(dnsRuleServers, maxLength: 60)
            let compactDNSProbe = compactDiagnosticPart(dnsProbe, maxLength: 80)
            let libbox = compactDiagnosticPart(TunnelEventStore.recentLibboxDiagnostics(limit: 1), maxLength: 120)
            detail = " | backend=\(backend) node=\(node) phase=\(phase) ready=\(ready) source=\(source) path=\(selectedPath) selector=\(selectorCurrent) route=\(routeFinal) route.rules=\(routeRulesMode)/\(routeRulesCount) outbound=\(outbound)/\(outboundType) tls=\(tls) sni=\(sni) server=\(server) dns.final=\(dnsFinal) dns.servers=\(compactDNSServers) dns.rules=\(compactDNSRules) dns.probe=\(compactDNSProbe) ruleset=\(rulesetMode) local=\(rulesetLocal) dl=\(rulesetDownloaded) cache=\(rulesetCached) rm=\(rulesetRemoved) libbox=\(libbox)"
        }
        errorMessage = AppLanguage.useSimplifiedChinese
            ? "已连接，但 sing-box 延迟接口验证失败（不等同于网站一定无法打开）\(detail)"
            : "Connected, but sing-box delay API check failed (websites may still work)\(detail)"
        return false
    }

    private func buildConnectionErrorMessage(_ error: Error) -> String {
        let base: String
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            base = localized
        } else {
            base = "\(AppLanguage.useSimplifiedChinese ? "连接操作失败" : "Connection operation failed"): \(error.localizedDescription)"
        }
        let diagnostic = TunnelEventStore.latestDiagnostic() ?? "-"
        let extensionDiagnostic = TunnelEventStore.latestExtensionDiagnostic() ?? "-"
        let libboxDiagnostic = compactDiagnosticPart(TunnelEventStore.recentLibboxDiagnostics(limit: 1), maxLength: 120)
        let timeline = TunnelEventStore.latestStatusTimeline(limit: 6)
        let hint = buildTunnelRecoveryHint(error: error, diagnostic: diagnostic, timeline: timeline)
        if AppLanguage.useSimplifiedChinese {
            if let hint {
                return "\(base)（建议：\(hint)） | 诊断: \(diagnostic) | 扩展: \(extensionDiagnostic) | libbox: \(libboxDiagnostic) | 状态轨迹: \(timeline)"
            }
            return "\(base) | 诊断: \(diagnostic) | 扩展: \(extensionDiagnostic) | libbox: \(libboxDiagnostic) | 状态轨迹: \(timeline)"
        }
        if let hint {
            return "\(base) (Suggestion: \(hint)) | Diagnostic: \(diagnostic) | Extension: \(extensionDiagnostic) | libbox: \(libboxDiagnostic) | Timeline: \(timeline)"
        }
        return "\(base) | Diagnostic: \(diagnostic) | Extension: \(extensionDiagnostic) | libbox: \(libboxDiagnostic) | Timeline: \(timeline)"
    }

    private func buildTunnelRecoveryHint(error: Error, diagnostic: String, timeline: String) -> String? {
        guard engine.requiresPacketTunnel else { return nil }

        if diagnostic.contains("appGroupContainer=nil") {
            return AppLanguage.useSimplifiedChinese
                ? "App Group 未生效；请检查主 App/扩展的 App Group 一致，并删除 App 后重装"
                : "App Group is unavailable; ensure app/extension use the same App Group, then reinstall the app"
        }

        if diagnostic.contains("manager connection is not NETunnelProviderSession") {
            return AppLanguage.useSimplifiedChinese
                ? "未拿到可用隧道会话；请检查扩展 Bundle ID 与 providerBundleIdentifier 是否一致"
                : "No valid tunnel session; verify extension bundle ID matches providerBundleIdentifier"
        }

        if diagnostic.contains("startVPNTunnel failed") {
            if diagnostic.contains("NEVPNErrorDomain") && diagnostic.contains("code=1") {
                return AppLanguage.useSimplifiedChinese
                    ? "VPN 配置无效；请检查 Network Extension 能力与描述文件"
                    : "VPN configuration is invalid; check Network Extension capability and provisioning profile"
            }
            if diagnostic.contains("NEVPNErrorDomain") && diagnostic.contains("code=2") {
                return AppLanguage.useSimplifiedChinese
                    ? "VPN 配置被禁用；请在系统 VPN 设置里确认已允许"
                    : "VPN configuration is disabled; confirm VPN permission is allowed in system settings"
            }
            return AppLanguage.useSimplifiedChinese
                ? "系统拒绝启动隧道；请确认已允许 VPN 权限并重试"
                : "System rejected tunnel startup; confirm VPN permission is granted and retry"
        }

        if diagnostic.contains("setTunnelNetworkSettings failed") {
            return AppLanguage.useSimplifiedChinese
                ? "扩展在设置系统隧道参数时失败；请检查 Network Extension 权限与签名描述文件"
                : "Provider failed while applying tunnel network settings; check Network Extension permission and signing profile"
        }

        if let tunnelError = error as? TunnelControllerError {
            switch tunnelError {
            case .simulatorUnsupported:
                return AppLanguage.useSimplifiedChinese
                    ? "模拟器不支持 Packet Tunnel，请改用真机"
                    : "Packet Tunnel is unsupported on simulator; run on a real device"
            case .managerUnavailable:
                return AppLanguage.useSimplifiedChinese
                    ? "隧道管理器不可用；请重启 App 并重试"
                    : "Tunnel manager unavailable; restart app and retry"
            case .invalidConfiguration:
                return AppLanguage.useSimplifiedChinese
                    ? "隧道配置无效；请检查扩展能力与签名"
                    : "Tunnel configuration is invalid; check extension capability and code signing"
            case .startFailed:
                return AppLanguage.useSimplifiedChinese
                    ? "隧道启动失败；请确认系统已授予 VPN 权限"
                    : "Tunnel failed to start; verify VPN permission is granted"
            case .providerNotConnected:
                return AppLanguage.useSimplifiedChinese
                    ? "隧道尚未连接；可等待几秒后重试"
                    : "Tunnel is not connected yet; wait a few seconds and retry"
            case .providerMessageFailed:
                return AppLanguage.useSimplifiedChinese
                    ? "扩展消息通道异常；建议断开后重连"
                    : "Provider message channel failed; disconnect and reconnect"
            case .providerMessageTimeout:
                return AppLanguage.useSimplifiedChinese
                    ? "扩展响应超时；请稍后重试或重新连接"
                    : "Provider response timed out; retry or reconnect"
            case .permissionDenied:
                return AppLanguage.useSimplifiedChinese
                    ? "系统拒绝保存 VPN 配置；请在系统设置允许 VPN，确认主 App/扩展的 Network Extension 与 App Group 能力一致，必要时删除 App 后重装"
                    : "System denied saving VPN configuration; allow VPN in system settings, ensure Network Extension/App Group capabilities match between app and extension, and reinstall app if needed"
            case .tunnelStartTimeout:
                if timeline.contains("connecting") {
                    return AppLanguage.useSimplifiedChinese
                        ? "隧道已进入连接中但握手超时；请切换网络后再试"
                        : "Tunnel reached connecting but handshake timed out; switch network and retry"
                }
                return AppLanguage.useSimplifiedChinese
                    ? "隧道一直停留在 disconnected；通常是权限未授权或签名能力不完整"
                    : "Tunnel stayed disconnected; typically caused by missing permission or signing capability"
            }
        }

        return nil
    }
}
