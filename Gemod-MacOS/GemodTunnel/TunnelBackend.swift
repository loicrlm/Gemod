import Foundation

struct TunnelProviderEnvironment: Equatable {
    var appGroup: String?
    var backend: String
    var transport: String
}

struct TunnelBackendSnapshot: Equatable {
    var connectionState: ConnectionState
    var healthStatus: HealthStatus
}

struct TunnelLatencyResult: Equatable {
    var snapshot: TunnelBackendSnapshot
    var latencyMilliseconds: Int?
}

protocol TunnelBackend: Actor {
    func reset(
        environment: TunnelProviderEnvironment,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelBackendSnapshot

    func connect(
        using configuration: TunnelRuntimeConfiguration,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelBackendSnapshot

    func disconnect(diagnosticsStore: TunnelDiagnosticsStore) async -> TunnelBackendSnapshot
    func probe(diagnosticsStore: TunnelDiagnosticsStore) async -> TunnelBackendSnapshot
    func status() async -> TunnelBackendSnapshot
    func latency(
        using configuration: TunnelRuntimeConfiguration,
        timeoutMilliseconds: Int,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelLatencyResult
}

actor PlaceholderSingboxBackend: TunnelBackend {
    private var environment = TunnelProviderEnvironment(appGroup: nil, backend: "singbox", transport: "tun")
    private var currentConfiguration: TunnelRuntimeConfiguration?
    private var connectionState: ConnectionState = .idle
    private var healthStatus: HealthStatus = .unknown

    func reset(
        environment: TunnelProviderEnvironment,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelBackendSnapshot {
        self.environment = environment
        currentConfiguration = nil
        connectionState = .idle
        healthStatus = .unknown
        diagnosticsStore.append(
            "tunnel",
            "backend 已重置：backend=\(environment.backend), transport=\(environment.transport), appGroup=\(environment.appGroup ?? "未提供")。"
        )
        return snapshot
    }

    func connect(
        using configuration: TunnelRuntimeConfiguration,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelBackendSnapshot {
        if connectionState.isBusy {
            return snapshot
        }

        if let currentConfiguration, connectionState.isConnected {
            if currentConfiguration == configuration {
                diagnosticsStore.append("tunnel", "backend 已连接，复用现有会话。")
                return snapshot
            }

            diagnosticsStore.append(
                "tunnel",
                "占位 backend 记录节点切换：\(currentConfiguration.selectedNodeName ?? "未选择") -> \(configuration.selectedNodeName ?? "未选择")。"
            )
            self.currentConfiguration = configuration
            healthStatus = evaluateHealth(for: configuration)
            return snapshot
        }

        connectionState = .connecting
        diagnosticsStore.append(
            "tunnel",
            "占位 backend 开始连接：节点=\(configuration.selectedNodeName ?? "未选择"), 模式=\(configuration.mode.rawValue)。"
        )
        try? await Task.sleep(nanoseconds: 120_000_000)
        currentConfiguration = configuration
        connectionState = .connected(since: Date())
        healthStatus = evaluateHealth(for: configuration)
        diagnosticsStore.append("tunnel", "占位 backend 已连接。")
        return snapshot
    }

    func disconnect(diagnosticsStore: TunnelDiagnosticsStore) async -> TunnelBackendSnapshot {
        guard !connectionState.isBusy else { return snapshot }
        guard connectionState.isConnected else {
            connectionState = .idle
            healthStatus = .unknown
            return snapshot
        }

        connectionState = .disconnecting
        diagnosticsStore.append("tunnel", "占位 backend 开始断开。")
        try? await Task.sleep(nanoseconds: 80_000_000)
        currentConfiguration = nil
        connectionState = .idle
        healthStatus = .unknown
        diagnosticsStore.append("tunnel", "占位 backend 已断开。")
        return snapshot
    }

    func probe(diagnosticsStore: TunnelDiagnosticsStore) async -> TunnelBackendSnapshot {
        if let currentConfiguration {
            healthStatus = evaluateHealth(for: currentConfiguration)
        } else if !connectionState.isConnected {
            healthStatus = .offline
        }
        diagnosticsStore.append("connectivity", "backend 探针结果：\(healthStatus.rawValue)。")
        return snapshot
    }

    func status() async -> TunnelBackendSnapshot {
        snapshot
    }

    func latency(
        using configuration: TunnelRuntimeConfiguration,
        timeoutMilliseconds: Int,
        diagnosticsStore: TunnelDiagnosticsStore
    ) async -> TunnelLatencyResult {
        let simulated = evaluateHealth(for: configuration) == .healthy ? 120 : nil
        diagnosticsStore.append(
            "latency",
            "占位 backend 延迟测试：节点=\(configuration.selectedNodeName ?? "未选择"), 结果=\(simulated.map { "\($0)ms" } ?? "超时")。"
        )
        return TunnelLatencyResult(snapshot: snapshot, latencyMilliseconds: simulated)
    }

    private var snapshot: TunnelBackendSnapshot {
        TunnelBackendSnapshot(connectionState: connectionState, healthStatus: healthStatus)
    }

    private func evaluateHealth(for configuration: TunnelRuntimeConfiguration) -> HealthStatus {
        if configuration.rawSubscription.isEmpty {
            return .offline
        }
        if configuration.selectedNodeName == nil {
            return .degraded
        }
        return .healthy
    }
}
