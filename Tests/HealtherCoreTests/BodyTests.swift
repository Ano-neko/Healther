import Foundation
import Testing
@testable import HealtherCore

@Suite struct BodyTests {
    @Test func upgradingAVersion1DatabaseKeepsEverything() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.executeScript(UserDatabase.schemaV1)
        try db.setUserVersion(1)
        try db.execute("INSERT INTO profile(section, key, value, updated_at) VALUES ('basics', '称呼', '小林', 0)")
        try db.execute("INSERT INTO kv(key, value, updated_at) VALUES ('persona.profile', '{}', 0)")
        try db.execute("INSERT INTO messages(turn_id, created_at, role, content) VALUES ('t', 0, 'user', 'hi')")

        try UserDatabase.migrate(db)
        #expect(db.userVersion == UserDatabase.currentVersion)
        #expect(try db.queryOne("SELECT value FROM profile WHERE key = '称呼'")?.string("value") == "小林")
        #expect(try db.queryOne("SELECT count(*) n FROM messages")?.int("n") == 1)
        #expect(KeyValueStore(db: db).get("persona.profile") == "{}")

        let body = BodyStore(db: db, kv: KeyValueStore(db: db))
        try body.addWeight(kg: 61.5, at: Date())
        #expect(try body.weights(from: .distantPast, to: .distantFuture).map(\.kg) == [61.5])
        try UserDatabase.migrate(db)  // idempotent
    }

    @Test func storedSettingsFromOlderVersionsStillDecode() throws {
        let settings = try JSONDecoder().decode(ProactiveSettings.self, from: Data(#"{"wake":false,"lunch":"11:40"}"#.utf8))
        #expect(settings.wake == false && settings.lunch == "11:40" && settings.dinner == ProactiveSettings().dinner)
        let body = try JSONDecoder().decode(BodyProfile.self, from: Data(#"{"sex":"something-new"}"#.utf8))
        #expect(body.heightCm == nil && body.sex == "something-new")
    }

    @Test func manualFieldsWinOverAppleHealth() throws {
        let s = try makeServices(ScriptedLLM([]))
        try s.body.setFromHealth(HealthCharacteristics(birthYear: 1995, sex: "female", heightCm: 160))
        try s.body.setManual(BodyProfile(heightCm: 163))
        #expect(s.body.current == BodyProfile(heightCm: 163, birthYear: 1995, sex: "female"))
        let now = try #require(s.clock.parse("2026-10-20 09:00", relativeTo: Date()))
        let text = ContextAssembler(s: s).renderBody(now: now)
        #expect(text.contains("身高 163cm") && !text.contains("身高 163cm（来自"))
        #expect(text.contains("今年 31 岁（来自 Apple 健康）") || text.contains("（今年 31 岁）（来自 Apple 健康）"))
    }

    @Test func handLoggedWeightShowsUpInSummariesAndTrends() async throws {
        let s = try makeServices(ScriptedLLM([]))
        let now = Date()
        try s.body.addWeight(kg: 80.2, at: now.addingTimeInterval(-60))
        let h = try await s.healthSummary(for: now)
        #expect(h.bodyMass == 80.2)
        let trend = try await s.dailyValues(.bodyMass, days: 3, endingAt: now)
        #expect(trend.last?.value != nil)
    }

    @Test func bodyToolUpdatesProfileAndWeightGoesLocal() async throws {
        let s = try makeServices(ScriptedLLM([]))
        let now = try #require(s.clock.parse("2026-10-20 09:00", relativeTo: Date()))
        let ctx = ToolContext(services: s, now: now, turnID: "t", attachments: [])
        _ = try await UpdateBodyProfileTool().run(["height_cm": 172, "birth_year": 1999], ctx)
        #expect(s.body.manual == BodyProfile(heightCm: 172, birthYear: 1999))
        let bad = try await UpdateBodyProfileTool().run(["height_cm": 20], ctx)
        #expect(bad.summary.isEmpty || s.body.manual.heightCm == 172)
        _ = try await LogBodyTool().run(["kind": "weight", "value": 66.6], ctx)
        #expect(try s.body.weights(from: .distantPast, to: .distantFuture).map(\.kg) == [66.6])
    }

    @Test func legacyProfileHeightIsAdopted() async throws {
        let s = try makeServices(ScriptedLLM([]))
        try s.profile.set(.basics, "身高", "大概 175cm")
        await s.syncBodyFromHealth()
        #expect(s.body.manual.heightCm == 175)
    }

    @Test func overviewListsExtraMetrics() async throws {
        let s = try makeServices(ScriptedLLM([]))
        let h = try await s.healthSummary(for: Date().addingTimeInterval(-86_400))
        #expect(h.extra[.basalEnergy] != nil)
        let json = h.json(clock: s.clock)
        #expect(json["basal_energy"] != nil && json["blood_oxygen"] != nil)
    }
}

@Suite struct EnergyPlanTests {
    @Test func paceTurnsIntoDailyTargetWithinSafeLimits() {
        #expect(EnergyPlan.suggest(burn: 2400, weeklyChangeKg: -0.5, sex: nil).kcal == 1850)
        #expect(EnergyPlan.suggest(burn: 2400, weeklyChangeKg: 0, sex: nil).kcal == 2400)
        let fast = EnergyPlan.suggest(burn: 2400, weeklyChangeKg: -1.5, sex: nil)
        #expect(fast.kcal == 1800 && fast.limited)  // deficit capped at 25%
        let low = EnergyPlan.suggest(burn: 1500, weeklyChangeKg: -1, sex: .female)
        #expect(low.kcal == 1200 && low.limited)  // never below the floor
        #expect(EnergyPlan.suggest(burn: 2000, weeklyChangeKg: 1, sex: .male).kcal == 2500)
    }

    @Test func planFollowsWatchDataAndGoals() async throws {
        let s = try makeServices(ScriptedLLM([]))
        let auto = try #require(await s.energyPlan())
        #expect(auto.source == .watch && auto.daysMeasured >= 4 && auto.fixed == nil)
        #expect(auto.target == auto.suggested && abs(auto.suggested - auto.burn) <= 10)

        try s.wellbeing.setGoal(.weeklyWeightChange, target: -0.5)
        let losing = try #require(await s.energyPlan())
        #expect(losing.suggested < auto.suggested - 400)

        try s.wellbeing.setGoal(.dailyKcal, target: 1700)
        #expect(await s.energyPlan()?.target == 1700)
        let live = await ContextAssembler(s: s).liveState(now: Date(), userText: "")
        #expect(live.contains("每天 1700 kcal（TA 定的固定值"))
    }
}
