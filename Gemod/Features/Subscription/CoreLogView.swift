import SwiftUI

struct CoreLogView: View {
    let lines: [String]
    let onRefresh: () -> Void
    let onClear: () -> Void
    @State private var isCopyNoticeVisible = false
    @State private var isShowingAbout = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(AppLanguage.useSimplifiedChinese ? "刷新" : "Refresh") {
                        onRefresh()
                    }
                    .buttonStyle(.bordered)

                    Button(AppLanguage.useSimplifiedChinese ? "清空" : "Clear") {
                        onClear()
                    }
                    .buttonStyle(.bordered)

                    Button(AppLanguage.useSimplifiedChinese ? "复制" : "Copy") {
                        copyAllLogs()
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding()
            .navigationTitle(AppLanguage.useSimplifiedChinese ? "核心日志" : "Core Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.body)
                            .accessibilityLabel(AppLanguage.useSimplifiedChinese ? "关于" : "About")
                    }
                }
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView()
            }
            .alert(AppLanguage.useSimplifiedChinese ? "提示" : "Notice", isPresented: $isCopyNoticeVisible) {
                Button(AppLanguage.useSimplifiedChinese ? "确定" : "OK", role: .cancel) {}
            } message: {
                Text(AppLanguage.useSimplifiedChinese ? "已复制到剪贴板" : "Copied to clipboard")
            }
        }
    }

    private func copyAllLogs() {
        let content = lines.joined(separator: "\n")
#if canImport(UIKit)
        UIPasteboard.general.string = content
#endif
        isCopyNoticeVisible = true
    }
}

