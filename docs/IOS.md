# 构建 iOS App

需要：macOS + Xcode 26（iOS 26 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、一个 Apple ID（免费的 Personal Team 就够）。

```bash
brew install xcodegen      # 或从 GitHub Releases 下载 xcodegen.zip
cd App
cp Config/Local.example.xcconfig Config/Local.xcconfig   # 填入你的 Team ID 和 Bundle ID
xcodegen                                                # 生成 Healther.xcodeproj（已被 git 忽略）
open Healther.xcodeproj
```

在 Xcode 里选择你的 iPhone，运行即可。首次启动会让你给伙伴起名字、填 API Key，并请求 Apple 健康权限。

## 关于免费账号

- 用免费 Apple ID 安装的 App 每 **7 天**需要重新从 Xcode 安装一次（证书到期），数据不会丢。
- 免费账号不支持 iCloud 等能力；Healther 本来就不用。
- 免费账号可以签出带 HealthKit 能力的描述文件（已在 Xcode 27 / iOS 26 上验证）。
- Bundle ID 必须全局唯一，请在 `Local.xcconfig` 里换成你自己的。
- 通过 SSH 用 `xcodebuild` 签名时若报 `errSecInternalComponent`，是登录钥匙串在 SSH 会话里处于锁定状态，先执行 `security unlock-keychain ~/Library/Keychains/login.keychain-db`。

## 模拟器

模拟器里 Apple 健康没有数据，可以在“设置 → 使用模拟数据”中切换到内置的模拟数据源。

## 目录

```
App/
  project.yml            XcodeGen 配置
  Config/                签名配置（Local.xcconfig 不入库）
  Healther/
    HealtherApp.swift    入口、Tab 结构
    Core/                AppModel（连接 HealtherCore）、设置、钥匙串、图片处理
    Design/              主题、Agent 光球、圆环和图表组件
    Chat/                对话、输入栏、餐食卡片
    Today/               今日仪表盘
    Memory/              档案 / 记忆 / 日记 / 食物库
    Settings/            设置、首次引导
```
