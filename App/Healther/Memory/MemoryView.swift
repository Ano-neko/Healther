import HealtherCore
import SwiftUI

/// What the agent knows about you — fully visible and editable. Trust needs transparency.
struct MemoryView: View {
    @Environment(AppModel.self) private var model
    @State private var section = 0
    @State private var profile: [ProfileStore.Entry] = []
    @State private var memories: [MemoryStore.Memory] = []
    @State private var diary: [EpisodeStore.Episode] = []
    @State private var foods: [FoodCandidate] = []
    @State private var query = ""
    @State private var exportFile: ExportFile?

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(intensity: 0.6)
                ScrollView {
                    VStack(spacing: 14) {
                        Picker("", selection: $section) {
                            Text("档案").tag(0)
                            Text("记忆").tag(1)
                            Text("日记").tag(2)
                            Text("食物库").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom, 4)

                        switch section {
                        case 0: profileList
                        case 1: memoryList
                        case 2: diaryList
                        default: foodList
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("\(model.assistantName)记得的")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportFile = model.exportMemories().map(ExportFile.init)
                    } label: {
                        Label("导出为 Markdown", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .sheet(item: $exportFile) { file in
                ShareSheet(items: [file.url]).ignoresSafeArea().presentationDetents([.medium, .large])
            }
            .searchable(text: $query, prompt: "搜索记忆")
            .onChange(of: query) { _, _ in load() }
            .task { load() }
            .refreshable { load() }
        }
    }

    func load() {
        guard let s = model.services else { return }
        profile = (try? s.profile.all()) ?? []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            memories = (try? s.memories.active(limit: 300)) ?? []
        } else {
            memories = ((try? s.memories.recall(query, limit: 50, touch: false)) ?? []).map(\.memory)
        }
        diary = (try? s.episodes.recent(60, before: "9999")) ?? []
        foods = (try? s.personalFoods.all()) ?? []
    }

    // MARK: Profile

    @ViewBuilder
    var profileList: some View {
        if profile.isEmpty {
            empty("还不太了解你", "多聊聊，\(model.assistantName)会慢慢记住你是谁。")
        }
        ForEach(ProfileStore.Section.allCases, id: \.self) { sec in
            let entries = profile.filter { $0.section == sec }
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sec.title).sectionLabel()
                    ForEach(entries, id: \.key) { e in
                        HStack(alignment: .top) {
                            Text(e.key).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.blue).frame(width: 72, alignment: .leading)
                            Text(e.value).font(.system(size: 14))
                            Spacer()
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                try? model.services?.profile.set(e.section, e.key, nil)
                                load()
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                .glassCard()
            }
        }
    }

    // MARK: Memories

    @ViewBuilder
    var memoryList: some View {
        if memories.isEmpty {
            empty("还没有长期记忆", "重要的事、反复出现的情绪、你们的约定，会被记在这里。")
        }
        ForEach(memories) { m in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Chip(text: m.kind.title, color: color(m.kind))
                    HStack(spacing: 2) {
                        ForEach(0..<5) { i in
                            Circle().fill(i < m.importance ? color(m.kind) : Theme.hairline).frame(width: 4, height: 4)
                        }
                    }
                    Spacer()
                    Text(m.createdAt, format: .dateTime.month().day()).font(.metric(11, weight: .regular)).foregroundStyle(Theme.tertiaryText)
                }
                Text(m.content).font(.system(size: 14))
            }
            .glassCard(cornerRadius: 20, padding: 14)
            .contextMenu {
                Button(role: .destructive) {
                    try? model.services?.memories.erase(m.id)
                    load()
                } label: { Label("永久删除这条记忆", systemImage: "trash") }
            }
        }
    }

    // MARK: Diary

    @ViewBuilder
    var diaryList: some View {
        if diary.isEmpty {
            empty("日记还是空的", "每过一天，\(model.assistantName)会为你们的这一天写一篇。")
        }
        ForEach(diary, id: \.day) { e in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(e.day).font(.metric(13, weight: .bold)).foregroundStyle(Theme.lilac)
                    if let mood = e.mood { Chip(text: mood, color: Theme.lilac) }
                    Spacer()
                }
                Text(e.summary).font(.system(size: 14)).lineSpacing(3)
                if !e.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(e.highlights, id: \.self) { h in
                            Label(h, systemImage: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        }
                    }
                }
            }
            .glassCard(tint: Theme.lilac)
        }
    }

    // MARK: Personal foods

    @ViewBuilder
    var foodList: some View {
        if foods.isEmpty {
            empty("食物库是空的", "确认过的饮食会自动学进来，下次识别更准。")
        }
        ForEach(foods) { f in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.name).font(.system(size: 15, weight: .medium))
                    Text("\(Int(f.per100g.kcal.rounded())) kcal/100g · 常吃 \(f.typicalGrams.map { "\(Int($0.rounded()))g" } ?? "-")")
                        .font(.metric(12, weight: .regular)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text("×\(f.useCount ?? 0)").font(.metric(13)).foregroundStyle(Theme.pink)
            }
            .glassCard(cornerRadius: 18, padding: 14)
            .contextMenu {
                Button(role: .destructive) {
                    try? model.services?.personalFoods.delete(id: f.id)
                    load()
                } label: { Label("删除", systemImage: "trash") }
            }
        }
    }

    // MARK: Helpers

    func empty(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            AgentOrb(state: .idle, size: 64)
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 14)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }

    func color(_ k: MemoryStore.Kind) -> Color {
        switch k {
        case .fact: return Theme.blue
        case .preference: return Theme.pink
        case .health: return Theme.rose
        case .event: return Theme.amber
        case .emotion: return Theme.lilac
        case .insight: return Theme.protein
        case .commitment: return Theme.coral
        }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// System share sheet, so the export can go to Files, Notes, AirDrop or any other app.
struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
