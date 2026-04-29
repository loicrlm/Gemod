import Foundation
import NetworkExtension

enum SingboxRealEngineError: LocalizedError {
    case providerRejected(String)

    var errorDescription: String? {
        switch self {
        case .providerRejected(let message):
            if message.isEmpty {
                return AppLanguage.useSimplifiedChinese ? "核心命令执行失败" : "Core command failed"
            }
            return message
        }
    }
}

final class SingboxRealEngine: CoreEngine, @unchecked Sendable {
    var requiresPacketTunnel: Bool { true }

    private let tunnelController: TunnelController
    private let store: SubscriptionStore

    init(
        tunnelController: TunnelController = TunnelController(),
        store: SubscriptionStore = UserDefaultsSubscriptionStore()
    ) {
        self.tunnelController = tunnelController
        self.store = store
    }

    func healthCheck() async -> Bool {
        let status = try? await tunnelController.currentStatus()
        guard status == .connected || status == .reasserting else {
            return true
        }
        do {
            let response = try await tunnelController.sendProviderCommand(["command": "health"])
            return response["status"] == "ok"
        } catch {
            return false
        }
    }

    func connect(node: String, mode: ProxyMode) async throws {
        var lastError: Error?
        for attempt in 0...1 {
            do {
                do {
                    try await preflightBackendReadinessIfNeeded()
                } catch {
                    // Sequence hardening: status preflight is informative, but should not
                    // block the real connect command when provider channel is recovering.
                    if !shouldIgnorePreflightError(error) {
                        throw error
                    }
                }
                let response = try await sendProviderCommandWithRetry([
                    "command": "connect",
                    "node": node,
                    "mode": mode.rawValue,
                    "transport": "tun",
                    "subscription_content": store.load()?.rawSubscriptionContent ?? ""
                ])
                guard response["status"] == "ok" else {
                    throw SingboxRealEngineError.providerRejected(response["message"] ?? "connect rejected")
                }
                return
            } catch {
                lastError = error
                guard shouldRetryError(error), attempt < 1 else {
                    throw error
                }
                try? await tunnelController.startTunnel()
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw lastError ?? SingboxRealEngineError.providerRejected("connect failed")
    }

    func disconnect() async throws {
        let response = try await sendProviderCommandWithRetry([
            "command": "disconnect"
        ])
        guard response["status"] == "ok" else {
            throw SingboxRealEngineError.providerRejected(response["message"] ?? "disconnect rejected")
        }
    }

    func testLatency(node: String, timeout: TimeInterval) async -> Int? {
        let status = try? await tunnelController.currentStatus()
        guard status == .connected || status == .reasserting else {
            return nil
        }
        let timeoutMs = Int(max(0.8, min(timeout, 6.0)) * 1000)
        do {
            let response = try await sendProviderCommandWithRetry([
                "command": "latency",
                "node": node,
                "timeout_ms": String(timeoutMs)
            ], maxRetries: 0)
            if response["status"] != "ok" {
                if let message = response["message"], !message.isEmpty {
                    let probeURLs = response["probe_urls"] ?? response["probe_url"] ?? "-"
                    TunnelEventStore.appendDiagnostic("latency failed node=\(node) message=\(message) probe_urls=\(probeURLs)")
                }
                return nil
            }
            if let text = response["latency_ms"], let value = Int(text), value > 0 {
                return value
            }
            TunnelEventStore.appendDiagnostic("latency missing value node=\(node)")
            return nil
        } catch {
            TunnelEventStore.appendDiagnostic("latency request error node=\(node) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func preflightBackendReadinessIfNeeded() async throws {
        let status: [String: String]
        do {
            status = try await tunnelController.sendProviderCommand([
                "command": "status"
            ])
        } catch {
            guard shouldRetryError(error) else {
                throw error
            }
            // Tunnel/provider channel may still be recovering from a recent transition.
            try? await tunnelController.startTunnel()
            try await Task.sleep(nanoseconds: 300_000_000)
            status = try await tunnelController.sendProviderCommand([
                "command": "status"
            ])
        }
        guard status["status"] == "ok" else { return }
        let backend = (status["backend"] ?? "").lowercased()
        if backend == "singbox" {
            let ready = (status["ready"] ?? "false").lowercased() == "true"
            let phase = (status["startup_phase"] ?? "").lowercased()
            if !ready {
                // Do not block first connect at idle/failed phase.
                // The actual start flow lives in provider connect command.
                if phase == "idle" || phase == "failed" || phase.isEmpty {
                    return
                }
                let rawMessage = status["message"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let message: String
                if rawMessage.isEmpty {
                    if phase == "preparing" {
                        message = AppLanguage.useSimplifiedChinese
                            ? "sing-box 正在启动中，请稍后重试"
                            : "Sing-box is starting up, please retry shortly"
                    } else {
                        message = AppLanguage.useSimplifiedChinese
                            ? "sing-box 后端未就绪，请稍后重试"
                            : "Sing-box backend is not ready yet, please retry shortly"
                    }
                } else {
                    message = rawMessage
                }
                throw SingboxRealEngineError.providerRejected(message)
            }
        }
    }

    private func sendProviderCommandWithRetry(
        _ payload: [String: String],
        maxRetries: Int = 2
    ) async throws -> [String: String] {
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let response = try await tunnelController.sendProviderCommand(payload)
                guard response["status"] != "ok" else {
                    return response
                }

                let message = response["message"] ?? ""
                if shouldRetryProviderRejection(message: message), attempt < maxRetries {
                    let delayMs = Int(response["retry_after_ms"] ?? "") ?? 250
                    try await Task.sleep(nanoseconds: UInt64(max(delayMs, 80)) * 1_000_000)
                    continue
                }
                throw SingboxRealEngineError.providerRejected(message.isEmpty ? "provider rejected" : message)
            } catch {
                lastError = error
                if shouldRetryError(error), attempt < maxRetries {
                    if let tunnelError = error as? TunnelControllerError,
                       tunnelError == .providerNotConnected || tunnelError == .providerMessageFailed {
                        try? await tunnelController.startTunnel()
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                throw error
            }
        }
        throw lastError ?? SingboxRealEngineError.providerRejected("provider command failed")
    }

    private func shouldRetryProviderRejection(message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("busy") || lower.contains("retry")
    }

    private func shouldRetryError(_ error: Error) -> Bool {
        guard let tunnelError = error as? TunnelControllerError else { return false }
        switch tunnelError {
        case .providerMessageTimeout, .providerNotConnected, .providerMessageFailed:
            return true
        default:
            return false
        }
    }

    private func shouldIgnorePreflightError(_ error: Error) -> Bool {
        guard let tunnelError = error as? TunnelControllerError else { return false }
        switch tunnelError {
        case .providerNotConnected, .providerMessageFailed, .providerMessageTimeout:
            return true
        default:
            return false
        }
    }
}
