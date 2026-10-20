import Foundation

/// Everything she knows about you, as one Markdown document you can keep or hand to another app.
public enum MemoryExporter {
    public static func markdown(_ s: HealtherServices, now: Date = Date()) throws -> String {
        let clock = s.clock
        var out: [String] = []
        out.append("# \(s.config.assistantName) 记得的你")
        out.append("> 导出于 \(clock.stamp(now))（\(clock.utcOffsetString(now))）· Healther")

        out.append("## 档案")
        let entries = try s.profile.all()
        if entries.isEmpty {
            out.append("（还没有）")
        } else {
            for section in ProfileStore.Section.allCases {
                let items = entries.filter { $0.section == section }
                guard !items.isEmpty else { continue }
                out.append("### \(section.title)\n" + items.map { "- **\($0.key)**：\($0.value)" }.joined(separator: "\n"))
            }
        }

        let goals = try s.wellbeing.goals()
        if !goals.isEmpty {
            out.append("## 目标\n" + goals.map { g in
                "- \(g.kind.title)：\(fmt(g.target, 1))\(g.kind.unit)" + (g.note.map { "（\($0)）" } ?? "")
            }.joined(separator: "\n"))
        }

        out.append("## 长期记忆")
        let memories = try s.memories.active()
        if memories.isEmpty {
            out.append("（还没有）")
        } else {
            for kind in MemoryStore.Kind.allCases {
                let items = memories.filter { $0.kind == kind }.sorted { $0.createdAt < $1.createdAt }
                guard !items.isEmpty else { continue }
                out.append("### \(kind.title)\n" + items.map { m in
                    "- \(m.content)  \n  <sub>\(clock.dayKey(m.createdAt)) · 重要度 \(m.importance)\(m.tags.isEmpty ? "" : " · " + m.tags.joined(separator: " "))</sub>"
                }.joined(separator: "\n"))
            }
        }

        if let summary = s.conversation.rollingSummary, !summary.isEmpty {
            out.append("## 前情提要\n" + summary)
        }

        let diary = try s.episodes.range(from: "0000-00-00", to: clock.dayKey(now))
        if !diary.isEmpty {
            out.append("## 日记")
            for e in diary.sorted(by: { $0.day > $1.day }) {
                var block = "### \(e.day)" + (e.mood.map { " · \($0)" } ?? "") + "\n" + e.summary
                if !e.highlights.isEmpty { block += "\n" + e.highlights.map { "- \($0)" }.joined(separator: "\n") }
                out.append(block)
            }
        }

        let foods = try s.personalFoods.all()
        if !foods.isEmpty {
            out.append("## 常吃的食物\n" + foods.map { f in
                var line = "- \(f.name)：\(fmt(f.per100g.kcal)) kcal/100g"
                if let g = f.typicalGrams { line += "，常吃 \(fmt(g))g" }
                return line
            }.joined(separator: "\n"))
        }

        let persona = s.persona.current
        out.append("## 附：\(s.config.assistantName) 的设定\n### 身份核心\n\(persona.identity)\n\n### 性格与说话方式\n\(persona.personality)")
        return out.joined(separator: "\n\n") + "\n"
    }

    public static func fileName(_ s: HealtherServices, now: Date = Date()) -> String {
        "Healther-记忆-\(s.clock.dayKey(now)).md"
    }
}
