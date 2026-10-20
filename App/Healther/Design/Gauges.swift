import Charts
import SwiftUI

/// Activity-ring style gauge. Over 100% draws a second lap in a warning tint.
struct RingGauge<Center: View>: View {
    var progress: Double
    var lineWidth: CGFloat = 14
    var colors: [Color]
    var overColor: Color = Theme.rose
    @ViewBuilder var center: () -> Center

    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(colors[0].opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(shown, 1))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.5), radius: lineWidth * 0.5)
            if shown > 1 {
                Circle()
                    .trim(from: 0, to: min(shown - 1, 1))
                    .stroke(overColor, style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center()
        }
        .onAppear { withAnimation(.spring(duration: 1.2, bounce: 0.15)) { shown = progress } }
        .onChange(of: progress) { _, new in withAnimation(.spring(duration: 0.8)) { shown = new } }
    }
}

/// Horizontal stacked bar of protein / fat / carbs energy share.
struct MacroBar: View {
    var protein: Double
    var fat: Double
    var carbs: Double

    var body: some View {
        let p = protein * 4, f = fat * 9, c = carbs * 4
        let total = max(p + f + c, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                Capsule().fill(Theme.protein).frame(width: max(2, geo.size.width * p / total))
                Capsule().fill(Theme.fat).frame(width: max(2, geo.size.width * f / total))
                Capsule().fill(Theme.carbs)
            }
        }
        .frame(height: 6)
    }
}

struct MacroLegend: View {
    var protein: Double
    var fat: Double
    var carbs: Double

    var body: some View {
        HStack(spacing: 14) {
            item("蛋白", protein, Theme.protein)
            item("脂肪", fat, Theme.fat)
            item("碳水", carbs, Theme.carbs)
        }
    }

    func item(_ label: String, _ grams: Double, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            Text("\(Int(grams.rounded()))g").font(.metric(12))
        }
    }
}

struct SparkPoint: Identifiable {
    var id: Date { day }
    var day: Date
    var value: Double
}

struct Sparkline: View {
    var points: [SparkPoint]
    var color: Color

    var body: some View {
        Chart(points) { p in
            AreaMark(x: .value("日", p.day), y: .value("值", p.value))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("日", p.day), y: .value("值", p.value))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: yDomain)
    }

    var yDomain: ClosedRange<Double> {
        let vs = points.map(\.value)
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.25, 0.5)
        return (lo - pad)...(hi + pad)
    }
}
