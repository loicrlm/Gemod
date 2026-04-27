import Foundation
import Combine
import UIKit
import NetworkExtension

@MainActor
final class SubscriptionViewModel: ObservableObject {
    @Published var subscriptionURL: String = ""
    @Published private(set) var nodes: [String] = []
    @Published private(set) var savedSubscriptionURL: String = ""
    @Published private(set) var selectedNode: String?
    @Published private(set) var mode: ProxyMode = .rule
    @Published private(set) var isConnected = false
    @Published private(set) var isCoreHealthy = true
    @Published private(set) var isLoading = false
    @Published private(set) var isTestingLatency = false
    @Published private(set) var nodeLatencyText: [String: String] = [:]
    @Published var errorMessage: String?
    @Published var interruptionNoticeMessage: String?

    private let service: SubscriptionService
    private let store: SubscriptionStore
    private let engine: CoreEngine
    private let tunnelController: TunnelController
    private var cancellables = Set<AnyCancellable>()

    init(
        service: SubscriptionService = MihomoSubscriptionService(),
        store: SubscriptionStore = UserDefaultsSubscriptionStore(),
        engine: CoreEngine = SingboxMockEngine(),
        tunnelController: TunnelController = TunnelController()
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

        Task {
            await refreshCoreHealth()
            await refreshConnectionState()
            checkTunnelInterruptionNotice()
        }
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
            if isConnected {
                isConnected = false
                persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存连接状态失败" : "Failed to save connection state")
            }
            let fetchedNodes = try await service.fetchNodes(from: cleanedURL)
            let preservedNode = selectedNode.flatMap { fetchedNodes.contains($0) ? $0 : nil }
            let newSelectedNode = preservedNode ?? fetchedNodes.first
            let newState = SubscriptionState(
                url: cleanedURL,
                nodes: fetchedNodes,
                selectedNode: newSelectedNode,
                mode: mode,
                isConnected: false
            )
            try store.save(newState)
            subscriptionURL = cleanedURL
            savedSubscriptionURL = cleanedURL
            nodes = fetchedNodes
            selectedNode = newSelectedNode
            isConnected = false
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

    func selectNode(_ node: String) {
        guard nodes.contains(node) else { return }
        selectedNode = node
        persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存节点选择失败" : "Failed to save selected node")
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
        Task {
            errorMessage = nil
            do {
                if isConnected {
                    try await engine.disconnect()
                    if engine.requiresPacketTunnel {
                        try await tunnelController.stopTunnel()
                    }
                    if !engine.requiresPacketTunnel {
                        isConnected = false
                    }
                } else if let node = selectedNode {
                    if engine.requiresPacketTunnel {
                        try await tunnelController.startTunnel()
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    try await engine.connect(node: node, mode: mode)
                    if !engine.requiresPacketTunnel {
                        isConnected = true
                    }
                }
                await refreshCoreHealth()
                await refreshConnectionState()
                persistState(errorText: AppLanguage.useSimplifiedChinese ? "保存连接状态失败" : "Failed to save connection state")
            } catch {
                errorMessage = buildConnectionErrorMessage(error)
            }
        }
    }

    func testAllLatencies() async {
        guard !nodes.isEmpty else {
            errorMessage = AppLanguage.useSimplifiedChinese ? "暂无可测试节点" : "No nodes to test"
            return
        }

        isTestingLatency = true
        nodeLatencyText = [:]
        defer { isTestingLatency = false }

        let testingNodes = nodes
        let useChinese = AppLanguage.useSimplifiedChinese
        let timeoutText = useChinese ? "超时" : "timeout"

        await withTaskGroup(of: (String, String).self) { group in
            var nextIndex = 0
            let maxConcurrent = min(4, testingNodes.count)

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
        errorMessage = nil
    }

    func latencyText(for node: String) -> String? {
        nodeLatencyText[node]
    }

    func refreshCoreHealth() async {
        isCoreHealthy = await engine.healthCheck()
    }

    func refreshConnectionState() async {
        guard engine.requiresPacketTunnel else { return }
        do {
            let status = try await tunnelController.currentStatus()
            switch status {
            case .connected, .connecting, .reasserting:
                isConnected = true
            default:
                isConnected = false
            }
        } catch {
            isConnected = false
        }
    }

    func clearInterruptionNotice() {
        interruptionNoticeMessage = nil
    }

    private static func measureLatencyText(for node: String, engine: CoreEngine, timeoutText: String) async -> String {
        guard let ms = await engine.testLatency(node: node, timeout: 8) else {
            return timeoutText
        }
        return "\(ms)ms"
    }

    private func checkTunnelInterruptionNotice() {
        guard let reason = TunnelEventStore.consumeLastStopReason() else { return }
        interruptionNoticeMessage = localizedInterruptionMessage(for: reason)
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
        mode = state.mode
        isConnected = state.isConnected
    }

    private func persistState(errorText: String) {
        do {
            let state = SubscriptionState(
                url: savedSubscriptionURL,
                nodes: nodes,
                selectedNode: selectedNode,
                mode: mode,
                isConnected: isConnected
            )
            try store.save(state)
        } catch {
            errorMessage = errorText
        }
    }

    private func buildConnectionErrorMessage(_ error: Error) -> String {
        let base: String
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            base = localized
        } else {
            base = "\(AppLanguage.useSimplifiedChinese ? "连接操作失败" : "Connection operation failed"): \(error.localizedDescription)"
        }
        let diagnostic = TunnelEventStore.latestDiagnostic() ?? "-"
        let timeline = TunnelEventStore.latestStatusTimeline(limit: 6)
        let hint = buildTunnelRecoveryHint(error: error, diagnostic: diagnostic, timeline: timeline)
        if AppLanguage.useSimplifiedChinese {
            if let hint {
                return "\(base)（建议：\(hint)） | 诊断: \(diagnostic) | 状态轨迹: \(timeline)"
            }
            return "\(base) | 诊断: \(diagnostic) | 状态轨迹: \(timeline)"
        }
        if let hint {
            return "\(base) (Suggestion: \(hint)) | Diagnostic: \(diagnostic) | Timeline: \(timeline)"
        }
        return "\(base) | Diagnostic: \(diagnostic) | Timeline: \(timeline)"
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

        if diagnostic.contains("mock controller start failed") ||
            diagnostic.contains("mock controller listener failed") {
            return AppLanguage.useSimplifiedChinese
                ? "扩展内本地控制器启动失败；请检查扩展内 127.0.0.1:9090 监听逻辑"
                : "Provider local controller failed to start; inspect 127.0.0.1:9090 listener logic in extension"
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
