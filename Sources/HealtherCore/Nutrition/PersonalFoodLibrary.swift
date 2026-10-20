import Foundation

/// Foods the user has actually eaten or saved ("公司食堂的鸡腿饭").
/// Confirmed meals feed it automatically, so recognition gets better with use.
public final class PersonalFoodLibrary: FoodDataSource {
    let db: SQLiteDatabase
    public let idPrefixes = ["personal"]

    public init(db: SQLiteDatabase) { self.db = db }

    static func normalize(_ name: String) -> String {
        name.precomposedStringWithCompatibilityMapping.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).joined()
    }

    func candidate(_ r: Row) -> FoodCandidate {
        let nutrients = (try? JSONDecoder().decode(Nutrients.self, from: Data((r.string("nutrients") ?? "{}").utf8))) ?? .zero
        return FoodCandidate(
            id: "personal:\(r.int("id") ?? 0)", source: .personal, name: r.string("name") ?? "",
            aliases: r.string("aliases"), detail: r.string("note"), per100g: nutrients,
            typicalGrams: r.double("typical_grams"), useCount: r.int("use_count"))
    }

    public func search(_ query: String, limit: Int) async throws -> [FoodCandidate] {
        guard let match = SearchTokenizer.matchExpression(query) else { return [] }
        let rows = try db.query(
            """
            SELECT p.*, bm25(personal_foods_fts, 5.0, 3.0) AS rank
            FROM personal_foods_fts JOIN personal_foods p ON p.id = personal_foods_fts.rowid
            WHERE personal_foods_fts MATCH ? ORDER BY rank LIMIT 30
            """, [match])
        // Personal entries must cover the query well; a single shared bigram is noise here.
        return rows.map(candidate)
            .filter { SearchTokenizer.coverage(of: query, in: $0.name + " " + ($0.aliases ?? "")) >= 0.5 }
            .prefix(limit).map { $0 }
    }

    public func lookup(id: String) async throws -> FoodCandidate? {
        guard let n = Int(id.split(separator: ":").last ?? "") else { return nil }
        return try db.queryOne("SELECT * FROM personal_foods WHERE id = ?", [n]).map(candidate)
    }

    public func all(limit: Int = 200) throws -> [FoodCandidate] {
        try db.query("SELECT * FROM personal_foods ORDER BY use_count DESC, last_used_at DESC LIMIT ?", [limit]).map(candidate)
    }

    /// Insert or update by normalized name. `grams` (if given) updates the running typical portion.
    @discardableResult
    public func upsert(name: String, per100g: Nutrients, aliases: String? = nil, note: String? = nil,
                       grams: Double? = nil, countUse: Bool = false, sourceRef: String? = nil, now: Date = Date()) throws -> FoodCandidate {
        let norm = Self.normalize(name)
        let json = String(decoding: try JSONEncoder().encode(per100g), as: UTF8.self)
        return try db.transaction {
            if let existing = try db.queryOne("SELECT * FROM personal_foods WHERE norm_name = ?", [norm]) {
                let id = existing.int("id")!
                let uses = existing.int("use_count") ?? 0
                var typical = existing.double("typical_grams")
                if let grams, countUse {
                    // Exponential moving average: recent portions matter more.
                    typical = typical.map { $0 * 0.6 + grams * 0.4 } ?? grams
                } else if let grams, typical == nil {
                    typical = grams
                }
                let mergedAliases = Self.mergeAliases(existing.string("aliases"), aliases)
                try db.execute(
                    """
                    UPDATE personal_foods SET name = ?, nutrients = ?, aliases = ?, note = COALESCE(?, note),
                        typical_grams = ?, use_count = ?, source_ref = COALESCE(?, source_ref),
                        last_used_at = CASE WHEN ? THEN ? ELSE last_used_at END
                    WHERE id = ?
                    """, [name, json, mergedAliases, note, typical, uses + (countUse ? 1 : 0), sourceRef, countUse, now, id])
                try reindex(id: id, name: name, aliases: mergedAliases)
                return try lookupSync(id)!
            } else {
                try db.execute(
                    """
                    INSERT INTO personal_foods(name, norm_name, aliases, note, nutrients, typical_grams, use_count, source_ref, created_at, last_used_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [name, norm, aliases, note, json, grams, countUse ? 1 : 0, sourceRef, now, countUse ? now : nil])
                let id = Int(db.lastInsertRowID)
                try reindex(id: id, name: name, aliases: aliases)
                return try lookupSync(id)!
            }
        }
    }

    public func delete(id: String) throws {
        guard let n = Int(id.split(separator: ":").last ?? "") else { return }
        try db.transaction {
            try db.execute("DELETE FROM personal_foods WHERE id = ?", [n])
            try db.execute("DELETE FROM personal_foods_fts WHERE rowid = ?", [n])
        }
    }

    private func lookupSync(_ id: Int) throws -> FoodCandidate? {
        try db.queryOne("SELECT * FROM personal_foods WHERE id = ?", [id]).map(candidate)
    }

    private func reindex(id: Int, name: String, aliases: String?) throws {
        try db.execute("DELETE FROM personal_foods_fts WHERE rowid = ?", [id])
        try db.execute("INSERT INTO personal_foods_fts(rowid, name_tokens, alias_tokens) VALUES (?, ?, ?)",
                       [id, SearchTokenizer.indexTokens(name), SearchTokenizer.indexTokens(aliases)])
    }

    static func mergeAliases(_ a: String?, _ b: String?) -> String? {
        let parts = [a, b].compactMap { $0 }.flatMap { $0.split(whereSeparator: { ",，、".contains($0) }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: ",")
    }
}
