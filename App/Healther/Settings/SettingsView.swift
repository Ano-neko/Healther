import HealtherCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings.load()
    @State private var apiKey = ""
    @State private var confirmClearChat = false
    @State private var confirmDeleteAll = false
    @State private var saved = false
    @State private var proactive = ProactiveSettings()
    /// Tapping the version seven times reveals the persona editor (kept out of sight on purpose).
    @State private var versionTaps = 0
    @State private var personaUnlocked = false

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

                Section {
                    Toggle("起床后打个招呼", isOn: $proactive.wake)
                    Toggle("饭点问问你", isOn: $proactive.meals)
                    if proactive.meals {
                        timeRow("早饭", $proactive.breakfast)
                        timeRow("午饭", $proactive.lunch)
                        timeRow("晚饭", $proactive.dinner)
                    }
                    Toggle("偶尔突然找你聊天", isOn: $proactive.random)
                } header: {
                    Text("\(model.assistantName)主动找你")
                } footer: {
                    Text("起床问候在手表同步了睡眠数据后发出。睡眠专注模式下通知会被静音。")
                }
                .onChange(of: proactive) { _, new in
                    Task { await model.updateProactiveSettings(new) }
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

                if personaUnlocked {
                    Section {
                        NavigationLink {
                            PersonaEditor()
                        } label: {
                            Label("\(model.assistantName)的核心设定", systemImage: "sparkles")
                        }
                    } footer: {
                        Text("身份核心与性格。改动会从下一句话开始生效。")
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.1.0")
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 7 && !personaUnlocked {
                                withAnimation(.snappy) { personaUnlocked = true }
                            }
                        }
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
            .onAppear {
                draft = model.settings
                proactive = model.proactiveSettings
                versionTaps = 0
            }
            .sensoryFeedback(.impact(weight: .light), trigger: personaUnlocked)
            .sensoryFeedback(.success, trigger: saved)
            .confirmationDialog("清空所有对话？", isPresented: $confirmClearChat, titleVisibility: .visible) {
                Button("清空", role: .destructive) { model.clearConversation() }
            }
            .confirmationDialog("删除全部本地数据？此操作不可撤销。", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("全部删除", role: .destructive) { model.deleteAllData() }
            }
        }
    }

    /// "HH:mm" strings edited as a time picker.
    func timeRow(_ label: String, _ value: Binding<String>) -> some View {
        let cal = Calendar.current
        let date = Binding<Date>(
            get: {
                let p = value.wrappedValue.split(separator: ":").compactMap { Int($0) }
                return cal.date(bySettingHour: p.first ?? 12, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = cal.dateComponents([.hour, .minute], from: d)
                value.wrappedValue = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            }
        )
        return DatePicker(label, selection: date, displayedComponents: .hourAndMinute)
    }
}

/// Who she is and how she talks. Reached only through the hidden entry in Settings.
struct PersonaEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var identity = ""
    @State private var personality = ""
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("名字") {
                TextField("名字", text: $name)
            }
            Section {
                TextEditor(text: $identity).frame(minHeight: 140)
            } header: {
                Text("身份核心")
            } footer: {
                Text("她是谁、和你是什么关系、为什么在这里。")
            }
            Section {
                TextEditor(text: $personality).frame(minHeight: 260)
            } header: {
                Text("性格与说话方式")
            } footer: {
                Text("语气、口头禅、爱好、小脾气、喜欢的颜文字……写得越具体越像。")
            }
            Section {
                Button("恢复默认设定", role: .destructive) { confirmReset = true }
            }
        }
        .font(.system(size: 15))
        .scrollContentBackground(.hidden)
        .background(AuroraBackground(intensity: 0.5))
        .navigationTitle("核心设定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    model.savePersona(name: name, profile: PersonaProfile(identity: identity, personality: personality))
                    dismiss()
                }
            }
        }
        .confirmationDialog("恢复默认的身份和性格？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("恢复默认", role: .destructive) {
                model.savePersona(name: name, profile: nil)
                dismiss()
            }
        }
        .onAppear {
            name = model.assistantName
            identity = model.persona.identity
            personality = model.persona.personality
        }
    }
}

/// First run: name → who she is (pre-filled, skippable) → API key → permissions.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var name = ""
    @State private var identity = ""
    @State private var personality = ""
    @State private var personaEdited = false
    @State private var key = ""
    @State private var finishing = false

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.1)
            VStack(spacing: 24) {
                Spacer(minLength: 20)
                AgentOrb(state: finishing ? .thinking : (step == 0 ? .idle : .speaking), size: step == 1 ? 90 : 150)
                    .animation(.snappy, value: step)
                header
                Group {
                    switch step {
                    case 0: nameStep
                    case 1: personaStep
                    case 2: keyStep
                    default: permissionStep
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                Spacer(minLength: 10)
                buttons
            }
            .padding(.bottom, 20)
        }
        .interactiveDismissDisabled()
        .onAppear {
            name = model.assistantName
            identity = model.persona.identity
            personality = model.persona.personality
            if model.hasAPIKey { key = "" }
        }
    }

    var header: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle)
                .multilineTextAlignment(.center)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 30)
    }

    var title: String {
        switch step {
        case 0: return "你好"
        case 1: return "她是谁"
        case 2: return "接上大脑"
        default: return "最后一步"
        }
    }

    var subtitle: String {
        switch step {
        case 0: return "一个懂你身体数据的伙伴。\n记饮食、看睡眠、聊心事，都可以找她。"
        case 1: return "给她一个身份和性格。不想写可以直接跳过，以后也能改。"
        case 2: return model.hasAPIKey ? "模型 API Key 已经配置好了。" : "她需要一个模型 API Key 来思考。\n只保存在这台手机的钥匙串里。"
        default: return "允许读取健康数据，她才看得到你的睡眠和活动；\n允许通知，她才能在你起床后、饭点时主动找你。"
        }
    }

    var nameStep: some View {
        VStack(spacing: 8) {
            Text("想怎么叫她？").font(.footnote).foregroundStyle(Theme.tertiaryText)
            TextField("给她起个名字", text: $name)
                .multilineTextAlignment(.center)
                .font(.system(size: 17, design: .rounded))
                .padding(14)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 50)
    }

    var personaStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                field("身份核心", text: $identity, height: 110)
                field("性格与说话方式", text: $personality, height: 200)
            }
            .padding(.horizontal, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    func field(_ label: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).sectionLabel()
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .font(.system(size: 14))
                .frame(height: height)
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .onChange(of: text.wrappedValue) { personaEdited = true }
        }
    }

    @ViewBuilder
    var keyStep: some View {
        if model.hasAPIKey {
            Label("已配置", systemImage: "checkmark.seal.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.blue)
        } else {
            SecureField("DeepSeek API Key（sk-…）", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, design: .monospaced))
                .padding(14)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 30)
        }
    }

    var permissionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple 健康：睡眠、活动、心率、体重", systemImage: "heart.text.square.fill")
            Label("通知：她主动找你的时候", systemImage: "bell.badge.fill")
        }
        .font(.system(size: 15))
        .foregroundStyle(Theme.secondaryText)
    }

    var buttons: some View {
        HStack(spacing: 12) {
            if step == 1 {
                Button {
                    personaEdited = false
                    next()
                } label: {
                    Text("跳过").font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glass)
            }
            Button {
                next()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .disabled(primaryDisabled)
        }
        .controlSize(.large)
        .padding(.horizontal, 30)
    }

    var primaryTitle: String {
        switch step {
        case 1: return "就这样"
        case 3: return finishing ? "她在醒来…" : "开始"
        default: return "继续"
        }
    }

    var primaryDisabled: Bool {
        if finishing { return true }
        if step == 2 && !model.hasAPIKey { return AppSettings.sanitizeKey(key).count < 10 }
        return false
    }

    func next() {
        if step < 3 {
            withAnimation(.snappy) { step += 1 }
            return
        }
        finishing = true
        let persona = personaEdited ? PersonaProfile(identity: identity, personality: personality) : nil
        Task {
            await model.finishOnboarding(name: name, persona: persona, apiKey: key.isEmpty ? nil : key)
            dismiss()
        }
    }
}
