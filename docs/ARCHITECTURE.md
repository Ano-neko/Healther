# 架构

## 原则

1. **核心逻辑与平台解耦**：Agent、记忆、营养、存储全部在 `HealtherCore`，可以在 Linux 上编译和测试。苹果平台专属的部分（HealthKit、SwiftUI）只在边缘。
2. **本地优先**：唯一的“服务器”是你自己配置的模型 API。没有账号，没有后端。
3. **数字由程序算，判断由模型做**：模型负责识别、估计克数、选数据库条目、和你沟通；营养计算、汇总、写入都由代码完成。

## 分层

```
┌──────────────────────────── iOS App (SwiftUI) ────────────────────────────┐
│ ChatView · TodayView · MemoryView · Settings          HealthKitDataSource  │
└───────────────────────────────────┬────────────────────────────────────────┘
                                    │
┌───────────────────────────── HealtherCore ─────────────────────────────────┐
│ HealtherAgent (actor)                                                      │
│   ├─ ContextAssembler   L0–L4 → messages                                   │
│   ├─ ToolRegistry       health · food · wellbeing · memory tools           │
│   └─ MemoryCurator      compaction · daily reflection                      │
│                                                                            │
│ Stores (SQLite)         Profile · Memory · Episode · Conversation          │
│                         Meal · PersonalFood · Wellbeing · KV               │
│ Food sources            Personal → Bundled(TW+USDA) → OpenFoodFacts        │
│ HealthDataSource        HealthKit (Apple) | Mock (Linux/dev)               │
│ LLMClient               OpenAICompatibleClient (DeepSeek)                  │
└────────────────────────────────────────────────────────────────────────────┘
```

## 一轮对话

1. 保存用户消息；照片写到 `attachments/`。
2. 计算一次「此刻」状态块（本轮内保持不变，保证缓存命中）。
3. 循环（最多 10 步）：组装上下文 → 流式调用模型 → 保存助手消息 → 依次执行工具调用并保存结果。没有工具调用时结束。
4. 回复发出之后做维护：补写日记、按需压缩、清理过期草稿。

照片只在它所在的那一轮以图片形式发送，之后的轮次里替换成“（附了 N 张照片）”。模型对照片的描述已经写在回复和餐食记录里了。

## 饮食记录

```
照片/描述 → search_food（中英文各一个查询词）→ [追问 1–2 个关键问题]
         → draft_meal（food_id 或估算的 per100g + 克数）→ 草稿卡片
         → 用户确认 → confirm_meal → 本地记录 + Apple 健康 + 学习进个人食物库
```

食物 id 带命名空间：`personal:12`、`tw:J0200201`、`usda:167512`、`off:6901234567890`。

## 数据存储

- `healther.sqlite`（用户数据，WAL 模式）：表结构见 `UserDatabase.swift`，用 `PRAGMA user_version` 做迁移。
- 身体资料：kv `body.profile`（手动填写）与 `body.health`（Apple 健康特征的缓存），手动优先；手动体重在 `weight_entries`，同时尽量写入 Apple 健康。
- `foods.sqlite`（只读，随包分发）：由 `scripts/build_food_db.py` 生成。
- Apple 健康：体重、体脂、血压、饮食（`HKCorrelation` food，带 `HealtherMealID` 元数据，便于更新和删除）、饮水、心理状态（`HKStateOfMind`）。

### 升级兼容

从 v0.1 起，每次更新都必须能直接读用户手机上已有的数据：

- 数据库只追加迁移步骤（`if v < N`），不改已有步骤，只做加法（新表、新列、新索引）。
- kv 里的 JSON：新字段要么是可选类型，要么用 `decodeIfPresent` 给默认值（参考 `ProactiveSettings`）；已存储的取值（`GoalKind`、`ProfileStore.Section`、记忆类型、`HealthMetric`、kv 键名）只加不改名。
- 读取 Apple 健康的类型变多时，提高 `AppModel.healthTypesVersion`，iOS 只会就新增的类型再问一次。
- 存储格式变化要配一个迁移或解码测试（见 `BodyTests`）。

## 模型

`ModelConfig` 按用途区分：聊天（含识图与工具调用，默认开启 low 档思考），以及后台整理（关闭思考，使用 JSON 输出）。DeepSeek 的特殊处理：思考模式下本轮的 `reasoning_content` 会回传，跨轮丢弃；图片只能放在 user 消息里。

## 平台边界

| 组件 | Linux | iOS |
|---|---|---|
| SQLite | 系统 `libsqlite3` 通过 `CSQLite` 模块 | 系统 `SQLite3` |
| 网络流式 | `URLSessionDataDelegate`（Linux 没有 `bytes(for:)`） | 同左 |
| 健康数据 | `MockHealthDataSource`（确定性的假数据） | `HealthKitDataSource` |
| 界面 | 终端 `healther` | SwiftUI |

## 人设与主动消息

- **人设分两层**：`PersonaProfile`（身份核心 + 性格，用户可改，存在用户库 `kv` 里）拼进系统提示词开头；其后是固定的规矩（数据真实、工具用法、记饮食流程、记忆、边界），任何人设都不能覆盖。
- **主动消息**（`Agent/Proactive.swift`）：
  - `hello`：首次设置完成后的第一句话，档案里还没有称呼时会问怎么称呼。
  - `wake`：HealthKit 后台推送（`HKObserverQuery` + background delivery）在睡眠样本同步后唤醒 App；睡眠结束在 4 小时内且今天还没问候过，就写一条并立刻发通知。
  - `breakfast` / `lunch` / `dinner` / `random`：每天第一次有机会时（起床、后台刷新或打开 App）用一次模型调用把当天剩下的消息都写好，作为本地通知排程；到点后进入对话记录。对应那顿饭已经记录了，就撤回那条。
  - 模型在历史里看到的是「（时间，你主动给 TA 发了下面这条消息）」加上一条 assistant 消息。
- **导出**：`MemoryExporter.markdown` 输出档案、目标、长期记忆、前情提要、日记、常吃的食物和人设。
