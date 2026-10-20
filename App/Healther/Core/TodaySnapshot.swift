import Foundation
import HealtherCore

/// Everything the Today screen shows, loaded in one pass.
struct TodaySnapshot: Equatable {
    var date = Date()
    var health: DailyHealthSummary?
    var nutrition = Nutrients.zero
    var meals: [Meal] = []
    var waterML: Double = 0
    var goals: [WellbeingStore.GoalKind: Double] = [:]
    var trends: [HealthMetric: [SparkPointValue]] = [:]
    var isMock = false
    var note: DayNote?

    var isToday: Bool { Calendar.current.isDateInToday(date) }

    struct SparkPointValue: Equatable {
        var day: Date
        var value: Double
    }

    var kcalGoal: Double { goals[.dailyKcal] ?? 2000 }
    var proteinGoal: Double { goals[.proteinG] ?? 100 }
    var stepsGoal: Double { goals[.steps] ?? 8000 }
    var exerciseGoal: Double { goals[.exerciseMinutes] ?? 30 }
    var sleepGoal: Double { goals[.sleepHours] ?? 7.5 }
    var waterGoal: Double { goals[.waterML] ?? 2000 }

    /// Loads any day; `day` defaults to today. Trends end on that day.
    static func load(from s: HealtherServices, day: Date = Date()) async -> TodaySnapshot {
        var snap = TodaySnapshot()
        let clock = s.clock
        let now = Calendar.current.isDateInToday(day) ? Date() : clock.endOfDay(day).addingTimeInterval(-1)
        let start = clock.startOfDay(now), end = clock.endOfDay(now)
        snap.date = now
        snap.note = s.dayNotes.note(for: clock.dayKey(now))
        snap.isMock = s.health.isMock
        snap.health = try? await s.health.dailySummary(for: now)
        snap.nutrition = (try? s.meals.totals(from: start, to: end)) ?? .zero
        snap.meals = (try? s.meals.meals(from: start, to: end)) ?? []
        snap.waterML = (try? s.wellbeing.water(from: start, to: end)) ?? 0
        for g in (try? s.wellbeing.goals()) ?? [] { snap.goals[g.kind] = g.target }
        for metric in [HealthMetric.restingHeartRate, .heartRateVariability, .bodyMass, .sleepHours, .respiratoryRate] {
            let values = (try? await s.health.dailyValues(metric, days: 7, endingAt: now)) ?? []
            snap.trends[metric] = values.compactMap { v in v.value.map { SparkPointValue(day: v.day, value: $0) } }
        }
        return snap
    }
}
