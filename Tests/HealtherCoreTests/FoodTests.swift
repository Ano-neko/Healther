import Foundation
import Testing
@testable import HealtherCore

@Suite struct BundledFoodDatabaseTests {
    let db = try! BundledFoodDatabase.bundled()

    @Test func hasAllSources() {
        #expect(db.count > 10_000)
    }

    @Test func chineseQueriesFindTaiwanEntries() async throws {
        let rice = try await db.search("白饭", limit: 5)
        #expect(rice.first?.source == .taiwanFDA)
        #expect(rice.contains { $0.name.contains("饭") })

        let egg = try await db.search("番茄炒蛋", limit: 5)
        #expect(egg.contains { $0.name.contains("蛋") })
    }

    @Test func englishQueriesFindUSDA() async throws {
        let r = try await db.search("chicken breast", limit: 5)
        #expect(r.contains { $0.source == .usdaSR || $0.source == .usdaFoundation })
        #expect(r.first.map { $0.name.lowercased().contains("chicken") } == true)
    }

    @Test func lookupRoundTrips() async throws {
        let first = try #require(try await db.search("苹果", limit: 1).first)
        let again = try await db.lookup(id: first.id)
        #expect(again?.per100g == first.per100g)
    }
}

@Suite struct NutritionMathTests {
    @Test func mealTotalsScaleByGrams() {
        let item = MealItem(name: "饭", grams: 150, foodID: nil, source: .estimate,
                            per100g: Nutrients(kcal: 200, protein: 4, fat: 1, carbs: 40), confidence: .medium)
        let meal = Meal(type: .lunch, eatenAt: Date(), items: [item, item])
        #expect(meal.totals.kcal == 600)
        #expect(meal.totals.carbs == 120)
        #expect(meal.totals.fiber == nil)
    }

    @Test func personalLibraryAveragesPortions() throws {
        let lib = PersonalFoodLibrary(db: try UserDatabase.inMemory())
        let n = Nutrients(kcal: 180)
        try lib.upsert(name: "公司鸡腿饭", per100g: n, grams: 400, countUse: true)
        let f = try lib.upsert(name: "公司 鸡腿饭", per100g: n, grams: 300, countUse: true)
        #expect(f.useCount == 2)
        #expect(f.typicalGrams == 360)  // 400*0.6 + 300*0.4
    }

    @Test func dayClockParsesModelTimes() {
        let clock = DayClock(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let now = clock.calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9))!
        #expect(clock.stamp(clock.parse("12:30", relativeTo: now)!) == "2026-10-20 12:30")
        #expect(clock.stamp(clock.parse("2026-10-19 21:05", relativeTo: now)!) == "2026-10-19 21:05")
        #expect(clock.dayKey(clock.parse("2026-10-18", relativeTo: now)!) == "2026-10-18")
        #expect(clock.parse("whenever", relativeTo: now) == nil)
    }
}
