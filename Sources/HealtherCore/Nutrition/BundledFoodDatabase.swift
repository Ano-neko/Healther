import Foundation

/// Read-only offline food table built by scripts/build_food_db.py
/// (Taiwan TFND in simplified Chinese + USDA SR Legacy/Foundation in English).
public final class BundledFoodDatabase: FoodDataSource {
    let db: SQLiteDatabase
    public let idPrefixes = ["tw", "usda"]

    public init(url: URL) throws {
        db = try SQLiteDatabase(path: url.path, readOnly: true)
    }

    /// The copy shipped inside HealtherCore's resource bundle.
    public static func bundled() throws -> BundledFoodDatabase {
        guard let url = Bundle.module.url(forResource: "foods", withExtension: "sqlite") else {
            throw SQLiteError(code: -1, message: "foods.sqlite missing from bundle", sql: nil)
        }
        return try BundledFoodDatabase(url: url)
    }

    public var count: Int { (try? db.queryOne("SELECT count(*) AS n FROM foods")?.int("n")) ?? 0 }

    static func candidate(_ r: Row) -> FoodCandidate {
        let source = FoodSource(rawValue: r.string("source") ?? "") ?? .usdaSR
        return FoodCandidate(
            id: r.string("id") ?? "",
            source: source,
            name: r.string("name") ?? "",
            nameEN: r.string("name_en"),
            aliases: r.string("aliases"),
            category: r.string("category"),
            detail: r.string("description"),
            per100g: Nutrients(
                kcal: r.double("kcal") ?? 0, protein: r.double("protein") ?? 0, fat: r.double("fat") ?? 0,
                carbs: r.double("carbs") ?? 0, fiber: r.double("fiber"), sugar: r.double("sugar"),
                sodiumMg: r.double("sodium_mg"), saturatedFat: r.double("sat_fat"))
        )
    }

    public func search(_ query: String, limit: Int) async throws -> [FoodCandidate] {
        guard let match = SearchTokenizer.matchExpression(query) else { return [] }
        let rows = try db.query(
            """
            SELECT f.*, bm25(foods_fts, 10.0, 4.0, 1.0) AS rank
            FROM foods_fts JOIN foods f ON f.rowid = foods_fts.rowid
            WHERE foods_fts MATCH ?
            ORDER BY rank LIMIT 60
            """, [match])
        // Re-rank: bm25 alone favours short names that match one bigram; reward covering the whole query.
        let q = query.lowercased()
        let scored = rows.map { r -> (FoodCandidate, Double) in
            let c = Self.candidate(r)
            let bm = -(r.double("rank") ?? 0)
            let nameCov = SearchTokenizer.coverage(of: query, in: c.name)
            let aliasCov = SearchTokenizer.coverage(of: query, in: (c.aliases ?? "") + " " + (c.nameEN ?? ""))
            var score = bm + 12 * nameCov + 6 * aliasCov
            let lname = c.name.lowercased()
            if lname == q { score += 20 } else if lname.hasPrefix(q) { score += 6 }
            score -= Double(c.name.count) * 0.05
            return (c, score)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    public func lookup(id: String) async throws -> FoodCandidate? {
        try db.queryOne("SELECT * FROM foods WHERE id = ?", [id]).map(Self.candidate)
    }
}
