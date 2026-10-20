import Foundation

public final class MealStore: Sendable {
    let db: SQLiteDatabase
    public init(db: SQLiteDatabase) { self.db = db }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    func meal(_ r: Row) -> Meal? {
        guard let id = r.string("id").flatMap(UUID.init(uuidString:)),
              let items = try? Self.decoder.decode([MealItem].self, from: Data((r.string("items") ?? "[]").utf8)) else { return nil }
        return Meal(
            id: id, status: MealStatus(rawValue: r.string("status") ?? "") ?? .draft,
            type: MealType(rawValue: r.string("meal_type") ?? "") ?? .snack,
            eatenAt: r.date("eaten_at") ?? Date(), note: r.string("note"), items: items, photo: r.string("photo"),
            createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
    }

    public func save(_ meal: Meal) throws {
        let t = meal.totals
        let items = String(decoding: try Self.encoder.encode(meal.items), as: UTF8.self)
        try db.execute(
            """
            INSERT INTO meals(id, status, meal_type, eaten_at, note, items, kcal, protein, fat, carbs, photo, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET status = excluded.status, meal_type = excluded.meal_type, eaten_at = excluded.eaten_at,
                note = excluded.note, items = excluded.items, kcal = excluded.kcal, protein = excluded.protein, fat = excluded.fat,
                carbs = excluded.carbs, photo = excluded.photo, updated_at = excluded.updated_at
            """,
            [meal.id, meal.status.rawValue, meal.type.rawValue, meal.eatenAt, meal.note, items, t.kcal, t.protein, t.fat, t.carbs,
             meal.photo, meal.createdAt, meal.updatedAt])
    }

    public func get(_ id: UUID) throws -> Meal? {
        try db.queryOne("SELECT * FROM meals WHERE id = ?", [id]).flatMap(meal)
    }

    /// Accepts a full UUID or the 8-char short id the model sees.
    public func find(_ ref: String) throws -> Meal? {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if let u = UUID(uuidString: r) { return try get(u) }
        guard r.count >= 6 else { return nil }
        return try db.queryOne("SELECT * FROM meals WHERE lower(id) LIKE ? ORDER BY updated_at DESC", [r.lowercased() + "%"]).flatMap(meal)
    }

    public func delete(_ id: UUID) throws { try db.execute("DELETE FROM meals WHERE id = ?", [id]) }

    public func meals(from: Date, to: Date, includeDrafts: Bool = false) throws -> [Meal] {
        try db.query(
            "SELECT * FROM meals WHERE eaten_at >= ? AND eaten_at < ? \(includeDrafts ? "" : "AND status = 'confirmed'") ORDER BY eaten_at",
            [from, to]).compactMap(meal)
    }

    public func drafts(since: Date) throws -> [Meal] {
        try db.query("SELECT * FROM meals WHERE status = 'draft' AND updated_at >= ? ORDER BY updated_at", [since]).compactMap(meal)
    }

    public func totals(from: Date, to: Date) throws -> Nutrients {
        guard let r = try db.queryOne(
            "SELECT sum(kcal) k, sum(protein) p, sum(fat) f, sum(carbs) c FROM meals WHERE status = 'confirmed' AND eaten_at >= ? AND eaten_at < ?",
            [from, to]) else { return .zero }
        return Nutrients(kcal: r.double("k") ?? 0, protein: r.double("p") ?? 0, fat: r.double("f") ?? 0, carbs: r.double("c") ?? 0)
    }

    public func markSynced(_ id: UUID, _ synced: Bool = true) throws {
        try db.execute("UPDATE meals SET synced = ? WHERE id = ?", [synced, id])
    }

    /// Drafts the user never confirmed — cleaned up after a while.
    public func purgeDrafts(olderThan date: Date) throws {
        try db.execute("DELETE FROM meals WHERE status = 'draft' AND updated_at < ?", [date])
    }
}
