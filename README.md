# Gemod

iOS 客户端，使用 [sing-box](https://github.com/SagerNet/sing-box) 能力（经 [Libbox](https://github.com/SagerNet/sing-box/tree/testing/libbox)）在 Network Extension 中处理网络流量。与 sing-box 项目及其运营方**无隶属、赞助或官方关系**；名称与图标不代表上游项目。

**English:** An iOS app that uses sing-box (via Libbox) inside a Network Extension. Not affiliated with the sing-box project.

## 要求

- **Xcode**（与工程 `IPHONEOS_DEPLOYMENT_TARGET` 一致或更高）
- **Apple 开发者账号**（用于 Network Extension / App ID 与描述文件）
- **真机**调试/测试：含 Packet Tunnel 的扩展无法在模拟器上完整按 VPN 流程验证；本仓库中的 Libbox 亦**仅包含真机 `ios-arm64` slice**（见下）

## 构建

1. 用 Xcode 打开 `Gemod.xcodeproj`。
2. 为主 App 与 `GemodTunnel` 等扩展配置好 **Team、Bundle ID、App Groups、Network Extension 权利** 等（与你在本机开发时一致）。
3. 选择**真机**为运行目标，编译并运行。

### Libbox 与仓库体积

为符合 GitHub 单文件 100MB 限制，本仓库内 `GemodTunnel/Frameworks/Libbox.xcframework` **仅含设备用 `ios-arm64`**。若你本地需要完整 `xcframework`（含模拟器 slice），请自行用构建产物替换，说明见 `GemodTunnel/Frameworks/README.txt`。

## 许可证

本仓库以 **GNU 通用公共许可证第 3 版（GPL-3.0）** 发布，见根目录 [LICENSE](LICENSE)。  
应用内集成的 sing-box 相关组件遵循其上游许可证；请在分发或二次开发前理解 GPL-3.0 下的义务，必要时咨询法律顾问。

## 相关链接

- [sing-box 许可证](https://github.com/SagerNet/sing-box/blob/testing/LICENSE)（`main` 分支无此文件，见仓库默认分支 `testing`）  
- [GPL-3.0 全文](https://www.gnu.org/licenses/gpl-3.0.html)

---

**免责声明：** 本 README 不构成法律意见。上架 App Store 与出口管制、隐私政策等以 Apple 与适用法律为准。
