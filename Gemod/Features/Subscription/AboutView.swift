import SwiftUI

/// Legal / attribution disclosure for bundled third‑party components (sing-box via Libbox).
/// Final wording should be reviewed before App Store submission.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(AppLanguage.useSimplifiedChinese ? "关于 Gemod" : "About Gemod")
                        .font(.title2.weight(.semibold))

                    Text(AppLanguage.useSimplifiedChinese
                        ? "版本 \(appVersion)"
                        : "Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Group {
                        Text(AppLanguage.useSimplifiedChinese ? "独立性说明" : "Independence")
                            .font(.headline)
                        Text(AppLanguage.useSimplifiedChinese
                            ? "Gemod 为独立开发的客户端应用，与 sing-box 项目或其运营方无隶属、赞助或官方合作关系；名称与图标不代表上游项目。"
                            : "Gemod is an independent client app. It is not affiliated with, sponsored by, or endorsed by the sing-box project or its operators.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Group {
                        Text(AppLanguage.useSimplifiedChinese ? "开源组件" : "Open source components")
                            .font(.headline)
                        Text(AppLanguage.useSimplifiedChinese
                            ? "网络扩展内集成 sing-box 能力（通过 Libbox）。sing-box 以 GNU 通用公共许可证第 3 版（GPL v3 或更高版本）授权；完整许可证文本见下方链接。请勿将本应用误认为 sing-box “官方”客户端。"
                            : "The Network Extension integrates sing-box functionality (via Libbox). sing-box is licensed under the GNU General Public License v3 (or later). See the links below. Do not mistake this app for an “official” sing-box client.")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 10) {
                            linkRow(
                                title: AppLanguage.useSimplifiedChinese ? "sing-box 许可证（GitHub）" : "sing-box license (GitHub)",
                                urlString: "https://github.com/SagerNet/sing-box/blob/main/LICENSE"
                            )
                            linkRow(
                                title: AppLanguage.useSimplifiedChinese ? "GNU GPL v3 全文" : "GNU GPL v3 full text",
                                urlString: "https://www.gnu.org/licenses/gpl-3.0.html"
                            )
                            linkRow(
                                title: AppLanguage.useSimplifiedChinese ? "sing-box 项目仓库" : "sing-box repository",
                                urlString: "https://github.com/SagerNet/sing-box"
                            )
                        }
                        .padding(.top, 4)
                    }

                    Text(AppLanguage.useSimplifiedChinese
                        ? "若需源码合规副本或授权细节，请联系开发者；建议在正式上线前由法律顾问复核 GPLv3 分发义务。"
                        : "For source-compliance correspondence or licensing questions, contact the developer. Have legal counsel review GPLv3 distribution obligations before release.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(AppLanguage.useSimplifiedChinese ? "关于" : "About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLanguage.useSimplifiedChinese ? "完成" : "Done") {
                        dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func linkRow(title: String, urlString: String) -> some View {
        if let url = URL(string: urlString) {
            Link(destination: url) {
                HStack {
                    Text(title)
                        .font(.body)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview {
    AboutView()
}
