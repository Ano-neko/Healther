import HealtherCore
import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var pickingDate = false
    /// The pinned card shows three lines until tapped.
    @State private var expanded = false
    private let fonts = CardFonts.shared

    var snap: TodaySnapshot { model.today }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(intensity: 0.7)
                ScrollView {
                    VStack(spacing: 16) {
                        greeting
                        energyHero
                        HStack(spacing: 12) {
                            miniRing("步数", value: snap.health?.steps ?? 0, goal: snap.stepsGoal, unit: "", colors: [Theme.blue, Theme.lilac])
                            miniRing("锻炼", value: snap.health?.exerciseMinutes ?? 0, goal: snap.exerciseGoal, unit: "分", colors: [Theme.lilac, Theme.pink])
                            miniRing("饮水", value: snap.waterML, goal: snap.waterGoal, unit: "ml", colors: [Theme.protein, Theme.blue])
                        }
                        sleepCard
                        vitalsGrid
                        mealsCard
                        if snap.isMock {
                            Label("当前显示的是模拟健康数据", systemImage: "flask")
                                .font(.footnote).foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                }
                .refreshable { await model.refreshToday() }
            }
            .navigationTitle(snap.isToday ? "今日" : "回顾")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                if !snap.isToday {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("回到今天") { model.showDay(Date()) }
                    }
                }
            }
            .sheet(isPresented: $pickingDate) { datePicker }
        }
    }

    // MARK: Sections

    var greeting: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                dayStepper
                VStack(alignment: .leading, spacing: 4) {
                    ClampedText(text: headline.title, font: fonts.uiFont(cardFont, size: 22, bold: true), lines: 2, expanded: expanded)
                    ClampedText(text: headline.detail, font: fonts.uiFont(cardFont, size: cardFont == nil ? 13 : 13.5, bold: false),
                                lines: 3, expanded: expanded)
                        .foregroundStyle(Theme.secondaryText)
                }
                .contentTransition(.opacity)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard snap.note != nil else { return }
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .contextMenu {
                    if let note = snap.note {
                        Picker("字体", selection: Binding(get: { CardFont(rawValue: note.font ?? "") ?? .system },
                                                          set: { model.setNoteFont($0) })) {
                            ForEach(CardFont.allCases, id: \.self) { Text($0.menuTitle).tag($0) }
                        }
                    }
                }
                if snap.note != nil {
                    Label("\(model.assistantName) 钉的", systemImage: "pin.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.pink)
                        .padding(.top, 2)
                }
            }
            Spacer()
            AgentOrb(state: .idle, size: 56)
        }
        .padding(.top, 4)
        .onChange(of: snap.note) { expanded = false }
    }

    /// nil keeps the built-in look for the automatic headline and notes without a font.
    var cardFont: CardFont? {
        snap.note?.font.flatMap(CardFont.init(rawValue:))
    }

    /// ‹ 10月19日 星期一 › — tap the date for a calendar.
    var dayStepper: some View {
        let cal = Calendar.current
        return HStack(spacing: 6) {
            Button {
                model.showDay(cal.date(byAdding: .day, value: -1, to: model.todayDay) ?? model.todayDay)
            } label: { Image(systemName: "chevron.left") }
            Button { pickingDate = true } label: {
                Text(snap.date, format: .dateTime.month().day().weekday(.wide))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
            }
            Button {
                model.showDay(cal.date(byAdding: .day, value: 1, to: model.todayDay) ?? model.todayDay)
            } label: { Image(systemName: "chevron.right") }
            .disabled(snap.isToday)
            .opacity(snap.isToday ? 0.3 : 1)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.secondaryText)
        .buttonStyle(.plain)
    }

    var datePicker: some View {
        NavigationStack {
            DatePicker("日期", selection: Binding(get: { model.todayDay }, set: { model.showDay($0); pickingDate = false }),
                       in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding()
                .navigationTitle("看看哪一天")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { pickingDate = false } } }
        }
        .presentationDetents([.medium])
    }

    /// The agent's pinned card wins; otherwise a rule-based read of the day.
    var headline: (title: String, detail: String) {
        if let n = snap.note { return (n.title, n.detail) }
        if !snap.isToday { return ("回顾这一天", "左右切换日期，或者问问\(model.assistantName)那天过得怎么样") }
        return readiness
    }

    var energyHero: some View {
        let eaten = snap.nutrition.kcal
        let goal = snap.kcalGoal
        let burned = snap.health?.activeEnergy ?? 0
        return HStack(spacing: 20) {
            RingGauge(progress: eaten / max(goal, 1), lineWidth: 16, colors: [Theme.amber, Theme.coral, Theme.rose]) {
                VStack(spacing: 0) {
                    if !snap.isToday && snap.meals.isEmpty {
                        Text("—").font(.metric(30, weight: .bold)).foregroundStyle(Theme.tertiaryText)
                        Text("没有饮食记录").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    } else {
                        Text("\(Int(abs(goal - eaten).rounded()))")
                            .font(.metric(30, weight: .bold))
                            .contentTransition(.numericText())
                        Text(eaten > goal ? "已超出" : snap.isToday ? "还可以吃" : "低于目标").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .frame(width: 136, height: 136)

            VStack(alignment: .leading, spacing: 12) {
                stat("已摄入", "\(Int(eaten.rounded()))", "kcal", Theme.amber)
                stat("目标", "\(Int(goal.rounded()))", "kcal", Theme.secondaryText)
                stat("活动消耗", "\(Int(burned.rounded()))", "kcal", Theme.blue)
                VStack(alignment: .leading, spacing: 6) {
                    MacroBar(protein: snap.nutrition.protein, fat: snap.nutrition.fat, carbs: snap.nutrition.carbs)
                    Text("蛋白 \(Int(snap.nutrition.protein))/\(Int(snap.proteinGoal))g")
                        .font(.metric(11, weight: .regular)).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .glassCard(cornerRadius: 28, padding: 20)
    }

    func stat(_ label: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value).font(.metric(19, weight: .bold)).foregroundStyle(color)
                Text(unit).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    func miniRing(_ label: String, value: Double, goal: Double, unit: String, colors: [Color]) -> some View {
        VStack(spacing: 10) {
            // Beating an activity goal is good news: the second lap keeps the ring's own color.
            RingGauge(progress: value / max(goal, 1), lineWidth: 8, colors: colors, overColor: colors.last ?? Theme.blue) {
                Text("\(Int((min(value / max(goal, 1), 9.99) * 100).rounded()))%").font(.metric(13, weight: .bold))
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 1) {
                Text(label).font(.system(size: 12, weight: .medium))
                Text("\(compact(value))\(unit)").font(.metric(11, weight: .regular)).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    @ViewBuilder
    var sleepCard: some View {
        if let s = snap.health?.sleep {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(snap.isToday ? "昨晚睡眠" : "前一晚睡眠", systemImage: "moon.zzz.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.lilac)
                    Spacer()
                    Text("\(s.start.formatted(date: .omitted, time: .shortened)) → \(s.end.formatted(date: .omitted, time: .shortened))")
                        .font(.metric(12, weight: .regular)).foregroundStyle(Theme.secondaryText)
                }
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(hoursText(s.asleepHours)).font(.metric(32, weight: .bold))
                    Text("/ 目标 \(hoursText(snap.sleepGoal))").font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
                }
                SleepStagesBar(sleep: s)
                if let trend = snap.trends[.sleepHours], trend.count > 1 {
                    Sparkline(points: trend.map { SparkPoint(day: $0.day, value: $0.value) }, color: Theme.lilac).frame(height: 36)
                }
            }
            .glassCard(tint: Theme.lilac)
        } else if snap.health != nil {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 20)).foregroundStyle(Theme.lilac)
                VStack(alignment: .leading, spacing: 3) {
                    Text(snap.isToday ? "昨晚没有睡眠记录" : "那晚没有睡眠记录").font(.system(size: 14, weight: .semibold))
                    Text("戴着 Apple Watch 入睡，并在「健康 → 睡眠」里打开睡眠追踪")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
            }
            .glassCard(tint: Theme.lilac)
        }
    }

    var vitalsGrid: some View {
        let h = snap.health
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            VitalTile(title: "静息心率", value: h?.restingHeartRate.map { "\(Int($0.rounded()))" }, unit: "bpm",
                      icon: "heart.fill", color: Theme.rose, trend: snap.trends[.restingHeartRate])
            VitalTile(title: "HRV", value: h?.hrv.map { "\(Int($0.rounded()))" }, unit: "ms",
                      icon: "waveform.path.ecg", color: Theme.lilac, trend: snap.trends[.heartRateVariability])
            VitalTile(title: "体重", value: h?.bodyMass.map { String(format: "%.1f", $0) }, unit: "kg",
                      icon: "scalemass.fill", color: Theme.blue, trend: snap.trends[.bodyMass])
            VitalTile(title: "呼吸频率", value: h?.respiratoryRate.map { String(format: "%.1f", $0) }, unit: "次/分",
                      icon: "lungs.fill", color: Theme.amber, trend: snap.trends[.respiratoryRate])
        }
    }

    var mealsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snap.isToday ? "今天吃了" : "这天吃了").sectionLabel()
            if snap.meals.isEmpty {
                Text(snap.isToday ? "还没有记录。去对话里拍一张吧 📷" : "这天没有饮食记录").font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
            }
            ForEach(snap.meals) { meal in
                HStack(spacing: 12) {
                    Text(meal.type.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.amber)
                        .frame(width: 34, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.items.map(\.name).joined(separator: "、")).font(.system(size: 14)).lineLimit(1)
                        Text(meal.eatenAt, format: .dateTime.hour().minute()).font(.metric(11, weight: .regular)).foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer()
                    Text("\(Int(meal.totals.kcal.rounded()))").font(.metric(16, weight: .bold))
                    Text("kcal").font(.system(size: 10)).foregroundStyle(Theme.tertiaryText)
                }
            }
        }
        .glassCard()
    }

    // MARK: Helpers

    /// A one-line read of the day from sleep + HRV, without a model call.
    var readiness: (title: String, detail: String) {
        guard let h = snap.health else { return ("你好", "连接 Apple 健康后，这里会显示你的状态") }
        let sleep = h.sleep?.asleepHours ?? 0
        let hrvTrend = snap.trends[.heartRateVariability]?.map(\.value) ?? []
        let hrvAvg = hrvTrend.isEmpty ? nil : hrvTrend.reduce(0, +) / Double(hrvTrend.count)
        let hrvLow = (h.hrv ?? 0) > 0 && hrvAvg.map { (h.hrv ?? 0) < $0 * 0.85 } == true
        if sleep > 0 && sleep < 6 || hrvLow { return ("今天悠着点", "睡眠或 HRV 偏低，身体在要求休息") }
        if sleep >= 7 { return ("状态不错", "睡得够，今天适合动一动") }
        return ("平稳的一天", "保持节奏，记得喝水")
    }

    func hoursText(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        return "\(m / 60)h\(String(format: "%02d", m % 60))m"
    }

    func compact(_ v: Double) -> String {
        v >= 10_000 ? String(format: "%.1f万", v / 10_000) : "\(Int(v.rounded()))"
    }
}

struct VitalTile: View {
    var title: String
    var value: String?
    var unit: String
    var icon: String
    var color: Color
    var trend: [TodaySnapshot.SparkPointValue]?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value ?? "--").font(.metric(24, weight: .bold))
                Text(unit).font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
            }
            .foregroundStyle(value == nil ? Theme.tertiaryText : .primary)
            if let trend, trend.count > 1 {
                Sparkline(points: trend.map { SparkPoint(day: $0.day, value: $0.value) }, color: color).frame(height: 28)
            } else {
                Text(value == nil ? "暂无数据" : "数据积累中")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
                    .frame(height: 28, alignment: .bottomLeading)
            }
        }
        .glassCard(cornerRadius: 22, padding: 14)
    }
}

struct SleepStagesBar: View {
    var sleep: SleepSummary

    struct Stage: Identifiable {
        var name: String
        var hours: Double
        var color: Color
        var id: String { name }
    }

    var stages: [Stage] {
        let core = sleep.coreHours ?? max(0, sleep.asleepHours - (sleep.deepHours ?? 0) - (sleep.remHours ?? 0))
        return [
            Stage(name: "深睡", hours: sleep.deepHours ?? 0, color: Theme.deepBlue),
            Stage(name: "核心", hours: core, color: Theme.lilac),
            Stage(name: "REM", hours: sleep.remHours ?? 0, color: Theme.blue),
            Stage(name: "清醒", hours: sleep.awakeHours ?? 0, color: Theme.coral),
        ]
    }

    var body: some View {
        let total = max(stages.reduce(0) { $0 + $1.hours }, 0.01)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(stages) { st in
                        RoundedRectangle(cornerRadius: 3).fill(st.color).frame(width: max(0, geo.size.width * st.hours / total - 2))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(stages) { st in
                    HStack(spacing: 4) {
                        Circle().fill(st.color).frame(width: 6, height: 6)
                        Text(st.name).foregroundStyle(Theme.secondaryText)
                        Text(String(format: "%.1fh", st.hours))
                    }
                    .font(.metric(11, weight: .regular))
                }
            }
        }
    }
}
