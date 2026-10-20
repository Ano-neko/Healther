import HealtherCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings.load()
    @State private var apiKey = ""
    @State private var confirmClearChat = false
    @State private var confirmDeleteAll = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AgentOrb(state: model.orb, size: 44)
                        TextField("名字", text: $draft.assistantName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                    }
                } header: { Text("你的伙伴") }

                Section {
                    SecureField(model.hasAPIKey ? "已保存（输入以替换）" : "sk-…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("接口地址", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("模型", text: $draft.chatModel)
                        .textInputAutocapitalization(.never)
                    Picker("思考深度", selection: $draft.effort) {
                        Text("关闭").tag(ReasoningEffort.off)
                        Text("轻度").tag(ReasoningEffort.low)
                        Text("深度").tag(ReasoningEffort.high)
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("Key 只保存在本机钥匙串中，请求直接从手机发往模型服务商，不经过任何中间服务器。")
                }

                Section {
                    Button("保存") {
                        model.applySettings(draft, apiKey: apiKey.isEmpty ? nil : apiKey)
                        apiKey = ""
                        saved = true
                    }
                    .disabled(draft == model.settings && apiKey.isEmpty)
                }

                Section("Apple 健康") {
                    Button {
                        Task { await model.requestHealthAccess() }
                    } label: {
                        Label("授权读取与写入健康数据", systemImage: "heart.text.square")
                    }
                    Toggle("使用模拟数据（开发调试）", isOn: $draft.useMockHealth)
                }

                if let s = model.services {
                    Section("用量") {
                        let u = s.totalUsage
                        LabeledContent("输入 tokens", value: u.promptTokens.formatted())
                        LabeledContent("其中缓存命中", value: u.cacheHitTokens.formatted())
                        LabeledContent("输出 tokens", value: u.completionTokens.formatted())
                    }
                }

                Section {
                    Button("清空对话记录", role: .destructive) { confirmClearChat = true }
                    Button("删除全部数据", role: .destructive) { confirmDeleteAll = true }
                } header: {
                    Text("数据")
                } footer: {
                    Text("清空对话不会删除档案、记忆和饮食记录。删除全部数据不会影响已写入 Apple 健康的记录。")
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.1.0")
                    Text("营养数据来自台湾食品营养成分资料库（卫福部食药署，政府资料开放授权）、USDA FoodData Central 与 Open Food Facts。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Healther 不是医疗器械，不提供诊断或治疗建议。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://github.com/Ano-neko/Healther")!) {
                        Label("开源代码（MIT）", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AuroraBackground(intensity: 0.5))
            .navigationTitle("设置")
            .onAppear { draft = model.settings }
            .sensoryFeedback(.success, trigger: saved)
            .confirmationDialog("清空所有对话？", isPresented: $confirmClearChat, titleVisibility: .visible) {
                Button("清空", role: .destructive) { model.clearConversation() }
            }
            .confirmationDialog("删除全部本地数据？此操作不可撤销。", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) { model.deleteAllData() }
            }
        }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var name = "小禾"
    @State private var step = 0

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.1)
            VStack(spacing: 28) {
                Spacer()
                AgentOrb(state: step == 0 ? .idle : .speaking, size: 150)
                VStack(spacing: 10) {
                    Text(step == 0 ? "你好，我是\(name)" : "最后一步")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(step == 0
                         ? "一个懂你身体数据的伙伴。\n记饮食、看睡眠、聊心事，都可以找我。"
                         : "我需要一个模型 API Key 来思考。\n它只会保存在这台手机的钥匙串里。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.secondaryText)
                }
                if step == 0 {
                    TextField("给我起个名字", text: $name)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 17, design: .rounded))
                        .padding(14)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 50)
                } else {
                    SecureField("DeepSeek API Key（sk-…）", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 16, design: .monospaced))
                        .padding(14)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.horizontal, 30)
                }
                Spacer()
                Button {
                    if step == 0 {
                        withAnimation(.snappy) { step = 1 }
                    } else {
                        var s = model.settings
                        s.assistantName = name.isEmpty ? "小禾" : name
                        model.applySettings(s, apiKey: key)
                        Task { await model.requestHealthAccess() }
                        dismiss()
                    }
                } label: {
                    Text(step == 0 ? "继续" : "开始")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(step == 1 && key.trimmingCharacters(in: .whitespaces).count < 10)
                .padding(.horizontal, 30)
                .padding(.bottom, 20)
            }
        }
        .interactiveDismissDisabled()
    }
}
