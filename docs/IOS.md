# 构建 iOS App

需要：macOS + Xcode 26（iOS 26 SDK）、[XcodeGen](https://github.com/yonaskolb/XcodeGen)、一个 Apple ID（免费的 Personal Team 就够）。

```bash
brew install xcodegen
cd App
cp Config/Local.example.xcconfig Config/Local.xcconfig   # 填入你的 Team ID 和 Bundle ID
xcodegen                                                # 生成 Healther.xcodeproj（已被 git 忽略）
open Healther.xcodeproj
```

在 Xcode 里选择你的 iPhone，运行即可。首次启动会让你给伙伴起名字、填 API Key，并请求 Apple 健康权限。

## 关于免费账号

- 用免费 Apple ID 安装的 App 每 **7 天**需要重新从 Xcode 安装一次（证书到期），数据不会丢。
- 免费账号不支持 iCloud 等能力；Healther 本来就不用。
- 开启 HealthKit 能力需要在 Xcode 的 Signing & Capabilities 中能看到 HealthKit；如果免费账号无法签名，请在 Issue 中反馈。

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
