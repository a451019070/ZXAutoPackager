# ZXAutoPackager

ZXAutoPackager 是一款 macOS SwiftUI 图形化打包工具，用于为 Xcode 项目选择 Scheme、构建配置与导出目录，执行归档、导出，并按需完成分支合并、上传和通知。支持将 **iOS 应用导出为 IPA**，或将 **macOS 应用打包为 ZIP**。

## 功能

- 选择包含 `.xcworkspace` 或 `.xcodeproj` 的项目文件夹，读取 Scheme；可切换 iOS / macOS 和 Debug / Release（默认 Release）。存在 workspace 时优先使用 workspace。
- 自定义版本号与 Build 号；留空时使用目标工程的 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。iOS 还可按蒲公英上同版本的历史记录获取下一个 Build 号。
- 使用独立 Git worktree 从 `origin` 远程分支打包，按指定顺序合并其他远程分支；支持在临时目录中处理冲突，并可选运行 `pod install`。
- iOS 可沿用工程签名，或选择 / 导入描述文件进行手动签名；打包后可选上传蒲公英，获取下载链接及二维码。
- 打包完成后可选发送飞书机器人通知；界面提供实时日志、任务停止、产物定位和打包历史。

## 环境要求

- macOS 和 Xcode，且 Xcode 命令行工具可使用 `xcrun xcodebuild`。当前工程的 `MACOSX_DEPLOYMENT_TARGET` 设置为 **26.4**；其他系统版本的兼容性未验证。
- 打包目标项目需要可正常构建的 Xcode 工程、对应 Scheme，以及目标平台所需的签名环境。
- 使用多分支功能时，需要 Git、可用的 `origin` 远程分支；若开启 worktree 中的 `pod install`，还需要目标项目的 `Podfile` 和可执行的 `pod`。普通打包不依赖 CocoaPods。
- 使用蒲公英或飞书功能时，需要相应服务的凭据与网络连接。

## 从源码运行

使用 Xcode 打开 `ZXAutoPackager.xcodeproj`，选择 `ZXAutoPackager` Scheme，点击运行。也可以在仓库根目录执行：

```sh
open ZXAutoPackager.xcodeproj
xcodebuild -project ZXAutoPackager.xcodeproj -scheme ZXAutoPackager -configuration Debug build
```

仓库目前提供 Xcode 工程，未提供预编译安装包或单独的安装脚本。

## 使用方法

1. 选择目标项目文件夹（其顶层应包含 `.xcworkspace` 或 `.xcodeproj`）及导出目录，刷新并选择 Scheme。
2. 选择目标平台和构建环境；按需填写版本号、Build 号。留空时使用 Xcode 工程中的值。
3. 按需打开「高级选项」，配置 worktree、签名、蒲公英或飞书。选择了需要合并的分支时，先点击「准备并合并」，完成后再开始打包；如遇冲突，在临时目录解决并执行 `git add`，然后点击「检查并继续」。
4. 点击「开始打包」，在状态区查看进度与日志；完成后可定位产物或在「打包历史」中查看记录。

> iOS 上传蒲公英和从蒲公英查询 Build 号需要配置 API Key；查询 Build 号还需要 App Key。飞书通知需要群自定义机器人 Webhook。飞书可以独立于蒲公英使用，但没有蒲公英上传结果时不会有公网下载链接；卡片图片需要预先取得 `imageKey`，应用不会自动上传二维码。

## 输出与数据

- 每次打包会在所选导出目录创建带时间戳的子目录，保存 `Build.log` 与打包产物。iOS 导出 IPA，并复制 dSYM；macOS 导出 ZIP。归档文件另存于 `~/Library/Developer/Xcode/Archives/`。
- 打包历史保存在用户的 `Application Support/ZXAutoPackager/package-history.json`。
- 界面设置及蒲公英 / 飞书凭据保存在本机 `UserDefaults`，**不是钥匙串**；请注意当前 macOS 账户及设备的数据安全。

## 注意事项

- iOS 手动签名目前仅支持**不含 Extension 的单个 App**；描述文件必须与 Bundle ID 匹配，钥匙串中需有对应的签名证书及私钥。该流程可能临时修改目标工程的 `project.pbxproj`，结束后会尝试恢复，建议打包前保持工程修改已妥善保存。
- iOS 导出依赖归档中的 `embedded.mobileprovision` 及 dSYM。未选择手动描述文件时使用内置的开发导出选项，不保证适用于所有分发方式。
- 多分支模式使用 `origin`，合并发生在临时 worktree 中，不会直接合并到原工作目录。若目标项目没有 `Podfile` 或未安装 CocoaPods，请关闭「临时 Worktree 中执行 pod install」。

## 测试

在仓库根目录运行：

```sh
xcodebuild -project ZXAutoPackager.xcodeproj -scheme ZXAutoPackager -destination 'platform=macOS' test
```

项目包含 Swift Testing 单元测试和 XCTest UI 测试。

## 项目结构

| 路径 | 说明 |
| --- | --- |
| `ZXAutoPackager/` | SwiftUI 界面、打包流程、Git worktree、签名与集成服务 |
| `ZXAutoPackager.xcodeproj/` | Xcode 工程与共享 Scheme |
| `ZXAutoPackagerTests/` | 单元测试 |
| `ZXAutoPackagerUITests/` | UI 测试 |

## 许可证

本项目采用 [MIT License](LICENSE)。