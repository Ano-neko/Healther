import HealtherCore
import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @State private var photos: [UIImage] = []
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 0.8)
            VStack(spacing: 0) {
                header
                transcript
            }
        }
        .safeAreaInset(edge: .bottom) {
            Composer(text: $draft, photos: $photos, focused: $focused) {
                model.send(text: draft, images: photos)
                draft = ""
                photos = []
            }
        }
    }

    // MARK: Header

    var header: some View {
        HStack(spacing: 12) {
            AgentOrb(state: model.orb, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.assistantName).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(model.status.isEmpty ? (model.hasAPIKey ? "在你身边" : "未连接") : model.status)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(model.isResponding ? Theme.pink : Theme.secondaryText)
                    .contentTransition(.opacity)
                    .animation(.easeInOut, value: model.status)
            }
            Spacer()
            if model.isResponding {
                Button { model.cancel() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: Transcript

    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if model.items.isEmpty && !model.isResponding {
                        EmptyChat { suggestion in model.send(text: suggestion) }
                            .padding(.top, 40)
                    }
                    ForEach(model.items) { item in
                        row(item).id(item.id)
                    }
                    if !model.streamingText.isEmpty {
                        AssistantBubble(text: model.streamingText, streaming: true).id("streaming")
                    } else if model.isResponding && model.orb == .thinking {
                        TypingIndicator().frame(maxWidth: .infinity, alignment: .leading).id("typing")
                    }
                    if let err = model.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Theme.coral)
                            .glassCard(cornerRadius: 16, padding: 12, tint: Theme.coral)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.items.count) { _, _ in withAnimation(.snappy) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.streamingText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    func row(_ item: ChatItem) -> some View {
        switch item {
        case .user(let id, let text, let files, _):
            UserBubble(text: text, files: files, pending: model.pendingPhotos[id] ?? [])
                .transition(.move(edge: .bottom).combined(with: .opacity))
        case .assistant(_, let text, _):
            AssistantBubble(text: text)
                .transition(.opacity)
        case .meal(_, let mealID):
            if let meal = model.meals[mealID] {
                MealCard(meal: meal, interactive: !model.isResponding) {
                    model.confirmMealFromCard(meal)
                } onEdit: {
                    draft = "改一下："
                    focused = true
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        case .activity(_, let steps):
            ToolActivity(steps: steps)
        }
    }
}

// MARK: - Bubbles

struct UserBubble: View {
    @Environment(AppModel.self) private var model
    var text: String
    var files: [String]
    var pending: [UIImage]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !files.isEmpty || !pending.isEmpty {
                HStack(spacing: 6) {
                    ForEach(files, id: \.self) { f in
                        if let url = model.photoURL(f), let img = UIImage(contentsOfFile: url.path) { photo(img) }
                    }
                    ForEach(pending.indices, id: \.self) { i in photo(pending[i]) }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 16))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(colors: [Theme.pink.opacity(0.55), Theme.blue.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: .rect(cornerRadius: 20)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    func photo(_ img: UIImage) -> some View {
        Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: 150, height: 150)
            .clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.15)))
    }
}

struct AssistantBubble: View {
    var text: String
    var streaming = false

    var body: some View {
        HStack(alignment: .top) {
            Text("\(Self.markdown(text))\(Text(streaming ? " ▍" : "").foregroundStyle(Theme.pink))")
                .font(.system(size: 16))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            Spacer(minLength: 36)
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Theme.pink)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

struct ToolActivity: View {
    var steps: [ToolStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    ZStack {
                        if step.done {
                            Image(systemName: step.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(step.isError ? Theme.coral : Theme.pink)
                        } else {
                            ProgressView().controlSize(.mini).tint(Theme.amber)
                        }
                    }
                    .frame(width: 16)
                    Text(step.summary ?? step.title + "…")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface, in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: steps)
    }
}

struct EmptyChat: View {
    @Environment(AppModel.self) private var model
    var onSuggestion: (String) -> Void

    struct Suggestion: Identifiable {
        var icon: String
        var text: String
        var id: String { text }
    }

    let suggestions = [
        Suggestion(icon: "camera.fill", text: "拍一下这顿饭，帮我记"),
        Suggestion(icon: "bed.double.fill", text: "我昨晚睡得怎么样？"),
        Suggestion(icon: "target", text: "帮我定一个减脂计划"),
        Suggestion(icon: "heart.text.square.fill", text: "今天状态怎么样？"),
    ]

    var body: some View {
        VStack(spacing: 22) {
            AgentOrb(state: model.orb, size: 130)
                .padding(.bottom, 10)
            VStack(spacing: 6) {
                Text("嗨，我是\(model.assistantName)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("吃了什么、睡得怎样、心情如何，\n都可以跟我说。")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(spacing: 10) {
                ForEach(suggestions) { s in
                    Button { onSuggestion(s.text) } label: {
                        HStack {
                            Image(systemName: s.icon).foregroundStyle(Theme.pink).frame(width: 22)
                            Text(s.text).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Theme.tertiaryText)
                        }
                        .font(.system(size: 15))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
            }
            .padding(.horizontal, 8)
        }
    }
}
