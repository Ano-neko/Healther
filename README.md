# Healther

> 一个住在 iPhone 里、懂你全部健康数据的 AI 陪伴伙伴。
> An on-device-first iOS health companion: an LLM agent that reads your Apple Health data, logs meals from photos, and remembers you.

Healther 把 Apple Watch / Apple 健康的数据（睡眠、活动、心率、HRV、体重……）、饮食记录、情绪和你们的聊天记忆交给一个 Agent 来统合：它会解读、规划，也可以只是陪你闲聊——而且聊多久都不会忘记自己是来照顾你身心健康的。

**状态：v0.1 开发中。** 核心 Agent 已可在 Linux / macOS 终端运行；iOS App 见 [docs/IOS.md](docs/IOS.md)。

## 特点

- **拍照记饮食，像朋友一样追问**：识别 → 查营养库 → 只对影响大的地方追问一两句 → 生成草稿卡片 → 你确认后记入 Apple 健康。热量来自营养数据库而不是模型瞎猜，中餐的烹调油会单独计入。
- **读得到 Apple 健康里的全部数据**：睡眠、活动与静息能量、心率、HRV、血氧、腕温、血压、血糖、步行指标、日照、噪音、心率提醒、经期……有数据的她都能看、能查趋势。
- **没有体重秤也行**：「设置 → 我的身体」可以填身高、出生年份、性别，手动记体重（同时写进 Apple 健康）。
- **越用越懂你**：确认过的食物进入个人食物库，记住你常吃的东西和你的真实份量。
- **分层记忆**：档案 / 实时状态 / 长期记忆 / 每日日记 / 对话摘要，聊嗨了也不会“忘本”。详见 [docs/MEMORY.md](docs/MEMORY.md)。
- **她会主动找你**：手表同步了睡眠、发现你起床后打个招呼；饭点问问你吃了没；偶尔没来由地找你聊两句。都是本地通知，没有服务器。
- **人设可自定义**：首次进入时可以设定她的身份核心和性格（也可以跳过用默认的）。之后的修改入口藏在「设置 → 关于 → 连点 7 次版本号」。
- **记忆可导出**：在「记忆」页一键导出档案、长期记忆、日记为 Markdown 文件，分享给任何 App。
- **数据只在本地**：没有服务器。所有记录存在手机的 SQLite 和 Apple 健康里；只有对话所需的上下文会发给你自己配置的模型 API。
- **自带 Key**：默认 DeepSeek（`deepseek-flash`，支持图片），任何 OpenAI 兼容接口都能接。

## 营养数据

内置离线食物库（约 10,000 条）：台湾食品营养成分资料库（中文，已转简体）+ USDA FoodData Central；包装食品通过 Open Food Facts 联网查条码。来源与许可见 [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md)。

## 在终端里试用（Linux / macOS）

需要 Swift 6.2+（Linux 可用 [swiftly](https://www.swift.org/install/) 安装）。

```bash
mkdir -p ~/.config/healther
echo "DEEPSEEK_API_KEY=sk-..." > ~/.config/healther/env && chmod 600 ~/.config/healther/env

swift build
.build/debug/healther                      # 交互聊天（使用模拟的 Apple Watch 数据）
.build/debug/healther ask "午饭吃了这个" --photo lunch.jpg
swift test
```

个人数据默认存放在 `~/.local/share/healther/`（可用 `HEALTHER_DATA_DIR` 修改），**永远不在仓库里**。聊天中输入 `/help` 查看调试命令（`/context` 可以看到模型实际收到的完整上下文）。

## 项目结构

```
Sources/HealtherCore/   核心库（Linux 可编译、可测试）
  Agent/                Agent 循环、人设、上下文组装
  Memory/               档案、长期记忆、日记、对话、记忆整理
  Nutrition/            食物库、个人食物库、餐食
  Health/               健康数据接口；HealthKit 实现（仅 Apple 平台）与模拟实现
  Tools/                Agent 可调用的工具
  LLM/                  OpenAI 兼容客户端（流式、工具调用、图片）
Sources/healther-cli/   终端客户端
App/                    iOS App（SwiftUI）
scripts/                数据构建脚本
docs/                   设计文档
```

架构说明见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 参与开发

```bash
git config core.hooksPath .githooks   # 启用提交前密钥扫描（需要 gitleaks）
```

请不要提交任何 API Key、真实的餐食照片或健康数据导出。

## 免责声明

Healther 不是医疗器械，不提供医疗诊断或治疗建议。AI 的营养估算存在误差。身体不适请咨询医生。

## 许可

[MIT](LICENSE)。内置数据集遵循各自的许可，见 [docs/DATA_SOURCES.md](docs/DATA_SOURCES.md)。
