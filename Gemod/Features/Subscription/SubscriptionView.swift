import SwiftUI

struct SubscriptionView: View {
    @StateObject var viewModel: SubscriptionViewModel
    @State private var isShowingImportSheet = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Group {
                        if let error = viewModel.errorMessage {
                            Text(error)
                                .foregroundStyle(.red)
                        } else {
                            Text("")
                        }
                    }
                    .font(.footnote)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Circle()
                        .fill(viewModel.isCoreHealthy ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(viewModel.isCoreHealthy ? "core-ok" : "core-failed")

                    Button {
                        isShowingImportSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle()
                                    .fill(Color(.secondarySystemBackground))
                            )
                            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoading)
                }

                Divider()

                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displaySubscriptionText(from: viewModel.savedSubscriptionURL))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(displaySelectedNode())
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        Task {
                            await viewModel.testAllLatencies()
                        }
                    } label: {
                        Text(latencyButtonText)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.savedSubscriptionURL.isEmpty || viewModel.selectedNode == nil || viewModel.isTestingLatency)
                    Menu {
                        ForEach(ProxyMode.allCases, id: \.self) { mode in
                            Button(mode.displayName) {
                                viewModel.setMode(mode)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(viewModel.mode.displayName)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(width: 74, alignment: .leading)
                    }
                    Spacer()
                    Button(viewModel.isConnected ? disconnectText : connectText) {
                        viewModel.connectSelectedNode()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.savedSubscriptionURL.isEmpty || viewModel.selectedNode == nil)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                List(viewModel.nodes, id: \.self) { node in
                    Button {
                        viewModel.selectNode(node)
                    } label: {
                        HStack {
                            ZStack {
                                if viewModel.selectedNode == node {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .frame(width: 18, height: 18)
                            Text(node)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(viewModel.latencyText(for: node) ?? "-")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(width: 58, alignment: .trailing)
                                .padding(.trailing, 15)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .listStyle(.plain)
            }
            .padding()
            .overlay {
                if viewModel.isLoading {
                    ProgressView(importingText)
                        .padding(16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .sheet(isPresented: $isShowingImportSheet) {
                ImportSubscriptionView(
                    onImportURL: { url in
                        Task {
                            await viewModel.importSubscription(from: url)
                        }
                    },
                    onImportFromClipboard: {
                        Task {
                            await viewModel.importFromClipboard()
                        }
                    }
                )
            }
            .task {
                await viewModel.refreshCoreHealth()
            }
            .navigationBarHidden(true)
            .alert(AppLanguage.useSimplifiedChinese ? "提示" : "Notice", isPresented: Binding(
                get: { viewModel.interruptionNoticeMessage != nil },
                set: { if !$0 { viewModel.clearInterruptionNotice() } }
            ), actions: {
                Button(AppLanguage.useSimplifiedChinese ? "确定" : "OK") {
                    viewModel.clearInterruptionNotice()
                }
            }, message: {
                Text(viewModel.interruptionNoticeMessage ?? "")
            })
        }
    }

    private func displaySubscriptionText(from rawURL: String) -> String {
        guard !rawURL.isEmpty else { return noSubscriptionText }
        if let range = rawURL.range(of: "sub/") {
            return String(rawURL[range.upperBound...])
        }
        return rawURL
    }

    private func displaySelectedNode() -> String {
        guard !viewModel.savedSubscriptionURL.isEmpty else { return "-" }
        return viewModel.selectedNode ?? "-"
    }

    private var noSubscriptionText: String {
        AppLanguage.useSimplifiedChinese ? "还没有导入订阅" : "No subscription yet"
    }

    private var connectText: String {
        AppLanguage.useSimplifiedChinese ? "连接" : "Connect"
    }

    private var disconnectText: String {
        AppLanguage.useSimplifiedChinese ? "断开" : "Disconnect"
    }

    private var importingText: String {
        AppLanguage.useSimplifiedChinese ? "正在导入..." : "Importing..."
    }

    private var latencyButtonText: String {
        if viewModel.isTestingLatency {
            return AppLanguage.useSimplifiedChinese ? "测试中..." : "Testing..."
        }
        return AppLanguage.useSimplifiedChinese ? "延迟测试" : "Latency Test"
    }
}

#Preview {
    SubscriptionView(viewModel: SubscriptionViewModel())
}
