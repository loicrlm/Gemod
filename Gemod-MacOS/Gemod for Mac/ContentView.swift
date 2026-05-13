//
//  ContentView.swift
//  Gemod for Mac
//
//  Created by Loic on 2026/5/12.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isAboutSheetPresented = false

    var body: some View {
        mainSplit
            .frame(minWidth: 780, minHeight: 700)
            .sheet(isPresented: $viewModel.isImportSheetPresented) {
                ImportSubscriptionSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isCoreLogSheetPresented) {
                CoreLogSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $isAboutSheetPresented) {
                AboutSheet()
            }
            .alert(
                "Notice",
                isPresented: alertPresentedBinding,
                actions: {
                    Button("OK", role: .cancel) {
                        Task { @MainActor in
                            viewModel.clearAlert()
                        }
                    }
                },
                message: {
                    Text(viewModel.alertMessage ?? "")
                }
            )
    }

    private var mainSplit: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                nodeListCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var alertPresentedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.alertMessage != nil },
            set: { newValue in
                if !newValue {
                    Task { @MainActor in
                        viewModel.clearAlert()
                    }
                }
            }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            sidebarBlock {
                Picker("Mode", selection: Binding(
                    get: { viewModel.mode },
                    set: { newMode in
                        Task { @MainActor in
                            viewModel.updateMode(newMode)
                        }
                    }
                )) {
                    ForEach(TunnelMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            sidebarBlock {
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.selectedNodeName ?? "No Node Selected")
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.toggleConnection()
                    } label: {
                        Label(
                            viewModel.connectionState.isConnected ? "Disconnect" : "Connect",
                            systemImage: viewModel.connectionState.isConnected ? "bolt.slash.fill" : "bolt.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.connectionState.isConnected ? .green : .accentColor)
                    .disabled(!viewModel.canConnect && !viewModel.connectionState.isConnected)

                    if let detail = viewModel.connectionState.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            appLogsSidebar

            Spacer()

            sidebarSubscriptionBar
        }
        .padding(24)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarSubscriptionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    viewModel.disconnectThenTryImportFromClipboardOrPresentSheet()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderedProminent)

                Text(viewModel.subscriptionShortcut)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer()
                sidebarTrailingTextButtons
            }
        }
    }

    private var sidebarTrailingTextButtons: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.toggleCoreLogSheet()
            } label: {
                Label("Core Logs", systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Core Logs")
            .accessibilityLabel("Core Logs")

            Button {
                isAboutSheetPresented = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("About")
            .accessibilityLabel("About")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var appLogsSidebar: some View {
        sidebarBlock {
            HStack {
                Text("App Logs")
                    .font(.headline)
            }

            if viewModel.appLogs.isEmpty {
                Text("No app logs yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(viewModel.appLogs.prefix(3)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .lineLimit(2)
                        Text(timeString(entry.timestamp))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var nodeListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(String.localizedStringWithFormat(NSLocalizedString("%d nodes", comment: "Node count"), viewModel.nodes.count))
                    .font(.headline)
                Spacer()
                Button {
                    viewModel.testAllLatency()
                } label: {
                    Label(viewModel.isTestingLatency ? "Testing..." : "Latency Test", systemImage: "speedometer")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.nodes.isEmpty || viewModel.isTestingLatency)
            }

            if viewModel.nodes.isEmpty {
                unavailableState(
                    "No nodes yet",
                    systemImage: "list.bullet.rectangle",
                    description: "Click the plus button at the bottom-left to import a subscription."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.nodes.enumerated()), id: \.element.id) { index, node in
                            nodeListRow(index: index, node: node)
                        }
                    }
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
    }

    @ViewBuilder
    private func nodeListRow(index: Int, node: NodeItem) -> some View {
        Button {
            viewModel.selectNode(node.id)
        } label: {
            nodeListRowLabel(node: node)
        }
        .buttonStyle(.plain)

        if index < viewModel.nodes.count - 1 {
            Divider()
                .padding(.leading, 12)
        }
    }

    @ViewBuilder
    private func nodeListRowLabel(node: NodeItem) -> some View {
        let isSelected = viewModel.selectedNodeID == node.id
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.green)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 18, alignment: .center)

            Text(node.name)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(.primary)

            if node.source == .selector {
                Text("Group")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18), in: Capsule())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            latencyText(for: node)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.11) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func latencyText(for node: NodeItem) -> some View {
        if let latency = node.latencyMilliseconds {
            Text("\(latency) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
        } else if node.lastTestedAt != nil {
            Text("Timeout")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func sidebarBlock<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func unavailableState(_ title: String, systemImage: String, description: String) -> some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        }
    }

}

private struct CoreLogSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Core Logs")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Copy All") {
                    copyToPasteboard(viewModel.coreLogsPlainText)
                }
                .buttonStyle(.bordered)

                Button("Clear", role: .destructive) {
                    viewModel.clearCoreLogs()
                }
                .buttonStyle(.bordered)

                Button("Refresh") {
                    viewModel.refreshDiagnostics()
                }
                .buttonStyle(.bordered)

                Button {
                    Task { @MainActor in
                        viewModel.isCoreLogSheetPresented = false
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }

            if viewModel.coreLogs.isEmpty {
                unavailableState(
                    "No core logs yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: "Logs from connect, probe, and import will appear here."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.coreLogs) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(entry.category.rawValue)] \(entry.message)")
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Text(timeString(entry.timestamp))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @ViewBuilder
    private func unavailableState(_ title: String, systemImage: String, description: String) -> some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        }
    }
}

private struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("About")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Group {
                        Text("Libbox Runtime Version")
                            .font(.headline)
                        Text("Local macOS build based on sing-box v1.14.0-alpha.23")
                            .foregroundStyle(.secondary)
                        Text("Source revision: b4d2d89")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Text("Independence")
                            .font(.headline)
                        Text("Gemod is an independent client application. It is not affiliated with, sponsored by, or endorsed by the sing-box project or its operators.")
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Text("Source Code")
                            .font(.headline)
                        Text("Gemod source code is hosted on GitHub. Redistribution is subject to this app's license and upstream sing-box licensing terms.")
                            .foregroundStyle(.secondary)
                        linkRow(title: "Gemod on GitHub", urlString: "https://github.com/loicrlm/gemod")
                    }

                    Group {
                        Text("Open Source Components")
                            .font(.headline)
                        Text("The Network Extension integrates sing-box functionality via Libbox. sing-box is licensed under GNU GPL v3 (or later).")
                            .foregroundStyle(.secondary)
                        linkRow(title: "sing-box License", urlString: "https://github.com/SagerNet/sing-box/blob/testing/LICENSE")
                        linkRow(title: "GNU GPL v3 Full Text", urlString: "https://www.gnu.org/licenses/gpl-3.0.html")
                        linkRow(title: "sing-box Repository", urlString: "https://github.com/SagerNet/sing-box")
                    }

                    Text("If additional compliance documents are required, contact the developer. Please have legal counsel review GPL obligations before release.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private func linkRow(title: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    ContentView(viewModel: AppViewModel())
}
