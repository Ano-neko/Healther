import HealtherCore
import SwiftUI

/// The draft / confirmed meal card shown inline in the chat.
struct MealCard: View {
    var meal: Meal
    var interactive: Bool
    var onConfirm: () -> Void
    var onEdit: () -> Void

    var isDraft: Bool { meal.status == .draft }

    var body: some View {
        if meal.items.isEmpty {
            Label("已删除这条\(meal.type.displayName)记录", systemImage: "trash")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            card
        }
    }

    var card: some View {
        let t = meal.totals
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon).foregroundStyle(Theme.amber)
                Text(meal.type.displayName).font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(meal.eatenAt, format: .dateTime.hour().minute())
                    .font(.metric(13, weight: .regular)).foregroundStyle(Theme.secondaryText)
                Spacer()
                if isDraft {
                    Chip(text: "待确认", color: Theme.amber, systemImage: "hourglass")
                } else {
                    Chip(text: "已记录", color: Theme.pink, systemImage: "checkmark")
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text("\(Int(t.kcal.rounded()))")
                    .font(.metric(40, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Theme.amber, Theme.coral], startPoint: .leading, endPoint: .trailing))
                    .contentTransition(.numericText())
                Text("kcal").font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }

            VStack(spacing: 8) {
                MacroBar(protein: t.protein, fat: t.fat, carbs: t.carbs)
                MacroLegend(protein: t.protein, fat: t.fat, carbs: t.carbs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(Theme.hairline)

            VStack(spacing: 9) {
                ForEach(meal.items) { item in
                    HStack(spacing: 8) {
                        Circle().fill(sourceColor(item.source)).frame(width: 6, height: 6)
                        Text(item.name).font(.system(size: 14))
                        if item.confidence == .low {
                            Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(Theme.amber)
                        }
                        Spacer()
                        Text("\(Int(item.grams.rounded()))g").font(.metric(13, weight: .regular)).foregroundStyle(Theme.secondaryText)
                        Text("\(Int(item.nutrients.kcal.rounded()))").font(.metric(14)).frame(width: 44, alignment: .trailing)
                    }
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(Set(meal.items.map(\.source))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { s in
                    HStack(spacing: 4) {
                        Circle().fill(sourceColor(s)).frame(width: 5, height: 5)
                        Text(s.displayName)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiaryText)
                }
            }

            if isDraft {
                HStack(spacing: 10) {
                    Button(action: onEdit) {
                        Label("修改", systemImage: "pencil").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button(action: onConfirm) {
                        Label("确认记录", systemImage: "checkmark").frame(maxWidth: .infinity).fontWeight(.semibold)
                            .foregroundStyle(Theme.background)
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
                .disabled(!interactive)
            }
        }
        .glassCard(cornerRadius: 26, padding: 18, tint: isDraft ? Theme.amber : Theme.pink)
        .animation(.snappy, value: meal)
    }

    var icon: String {
        switch meal.type {
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "cup.and.saucer.fill"
        }
    }

    func sourceColor(_ s: FoodSource) -> Color {
        switch s {
        case .personal: return Theme.pink
        case .taiwanFDA: return Theme.blue
        case .usdaSR, .usdaFoundation: return Theme.lilac
        case .openFoodFacts: return Theme.amber
        case .estimate: return Theme.coral
        }
    }
}
