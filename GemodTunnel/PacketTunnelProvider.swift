//
//  PacketTunnelProvider.swift
//  GemodTunnel
//
//  Created by Loic on 2026/4/24.
//

import Foundation
import NetworkExtension
import Network

class PacketTunnelProvider: NEPacketTunnelProvider {
    private var mockController: MockControllerServer?
    private var selectedNode: String?
    private var selectedMode: String = "rule"
    private var isProxyConnected = false

    override func startTunnel(options: [String : NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        _ = options
        SharedTunnelEventStore.appendDiagnostic("startTunnel invoked")
        SharedTunnelEventStore.clearUserInitiatedStopFlag()
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.8.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard error == nil else {
                let ns = error as NSError?
                let msg = "setTunnelNetworkSettings failed domain=\(ns?.domain ?? "-") code=\(ns?.code ?? -1) desc=\(ns?.localizedDescription ?? "unknown")"
                SharedTunnelEventStore.appendDiagnostic(msg)
                completionHandler(error)
                return
            }

            do {
                let server = try MockControllerServer(host: "127.0.0.1", port: 9090)
                server.start()
                self?.mockController = server
                completionHandler(nil)
            } catch {
                let ns = error as NSError
                let msg = "mock controller start failed domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)"
                SharedTunnelEventStore.appendDiagnostic(msg)
                completionHandler(error)
            }
        }
    }
    
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let isUserInitiated = SharedTunnelEventStore.consumeUserInitiatedStopFlag()
        if !isUserInitiated && reason != .none {
            SharedTunnelEventStore.saveLastStopReason(reason)
        }
        SharedTunnelEventStore.appendDiagnostic("stopTunnel reason=\(reason.rawValue)")
        mockController?.stop()
        mockController = nil
        completionHandler()
    }
    
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let payload = (try? JSONSerialization.jsonObject(with: messageData)) as? [String: String],
              let command = payload["command"] else {
            completionHandler?(encodeResponse(["status": "error", "message": "invalid message"]))
            return
        }

        switch command {
        case "health":
            completionHandler?(encodeResponse(["status": "ok"]))
        case "connect":
            selectedNode = payload["node"]
            selectedMode = payload["mode"] ?? "rule"
            isProxyConnected = true
            completionHandler?(encodeResponse([
                "status": "ok",
                "node": selectedNode ?? "",
                "mode": selectedMode
            ]))
        case "disconnect":
            isProxyConnected = false
            completionHandler?(encodeResponse(["status": "ok"]))
        case "status":
            completionHandler?(encodeResponse([
                "status": "ok",
                "connected": isProxyConnected ? "true" : "false",
                "node": selectedNode ?? "",
                "mode": selectedMode
            ]))
        default:
            completionHandler?(encodeResponse(["status": "error", "message": "unsupported command"]))
        }
    }
    
    override func sleep(completionHandler: @escaping () -> Void) {
        // Add code here to get ready to sleep.
        completionHandler()
    }
    
    override func wake() {
        // Add code here to wake up.
    }

    private func encodeResponse(_ payload: [String: String]) -> Data? {
        try? JSONSerialization.data(withJSONObject: payload)
    }
}

private enum SharedTunnelEventStore {
    private static let appGroupIdentifier = "group.com.gemod.Gemod"
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

    private static let sharedLogFileName = "tunnel_diagnostics.log"
    private static let maxLogLines = 200

    private static func sharedStateFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(sharedStateFileName)
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

    static func appendDiagnostic(_ message: String) {
        appendSharedLogLine("D|[ext] \(message)")
    }

    private static func sharedLogFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(sharedLogFileName)
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

    private static func appendSharedLogLine(_ message: String) {
        guard let url = sharedLogFileURL() else {
            NSLog("[GemodTunnel] app group 容器不可用: \(appGroupIdentifier)")
            return
        }
        var lines = readSharedLogLines()
        lines.append("\(timestamp()) | \(message)")
        if lines.count > maxLogLines {
            lines = Array(lines.suffix(maxLogLines))
        }
        if let data = lines.joined(separator: "\n").data(using: .utf8) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

private final class MockControllerServer {
    private let listener: NWListener

    init(host: String, port: UInt16) throws {
        _ = host
        let portValue = NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 9090)
        listener = try NWListener(using: .tcp, on: portValue)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                let msg = "mock controller listener failed error=\(error.localizedDescription)"
                SharedTunnelEventStore.appendDiagnostic(msg)
            case .ready, .waiting(_):
                break
            default:
                break
            }
        }
    }

    func start() {
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
            let requestLine = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let body: String
            if requestLine.hasPrefix("GET /version") {
                body = #"{"version":"mock-singbox-controller"}"#
            } else {
                body = #"{"message":"not found"}"#
            }

            let status = requestLine.hasPrefix("GET /version") ? "200 OK" : "404 Not Found"
            let response =
                "HTTP/1.1 \(status)\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: \(body.utf8.count)\r\n" +
                "Connection: close\r\n\r\n" +
                body

            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
