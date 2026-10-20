import Foundation

public protocol FoodDataSource: Sendable {
    /// Id prefixes this source owns, e.g. `["tw", "usda"]`.
    var idPrefixes: [String] { get }
    func search(_ query: String, limit: Int) async throws -> [FoodCandidate]
    func lookup(id: String) async throws -> FoodCandidate?
}

extension FoodDataSource {
    public func owns(_ id: String) -> Bool {
        guard let prefix = id.split(separator: ":").first else { return false }
        return idPrefixes.contains(String(prefix))
    }
}

/// Fans a query out to every source and merges results.
/// Personal foods rank first — what the user actually eats beats any table.
public struct FoodSearchService: Sendable {
    public var personal: PersonalFoodLibrary
    public var offline: [any FoodDataSource]
    public var online: [any FoodDataSource]

    public init(personal: PersonalFoodLibrary, offline: [any FoodDataSource], online: [any FoodDataSource] = []) {
        self.personal = personal
        self.offline = offline
        self.online = online
    }

    public func search(queries: [String], limit: Int = 8, includeOnline: Bool = false) async -> [FoodCandidate] {
        var seen = Set<String>()
        var personalHits: [FoodCandidate] = []
        var tableHits: [FoodCandidate] = []
        for q in queries where !q.trimmingCharacters(in: .whitespaces).isEmpty {
            for c in (try? await personal.search(q, limit: 4)) ?? [] where seen.insert(c.id).inserted {
                personalHits.append(c)
            }
        }
        // Interleave per-query results so a Chinese query and its English twin both get a share.
        var perQuery: [[FoodCandidate]] = []
        let sources = offline + (includeOnline ? online : [])
        for q in queries where !q.trimmingCharacters(in: .whitespaces).isEmpty {
            var list: [FoodCandidate] = []
            for s in sources { list += (try? await s.search(q, limit: limit)) ?? [] }
            perQuery.append(list)
        }
        var i = 0
        while tableHits.count < limit, perQuery.contains(where: { i < $0.count }) {
            for list in perQuery where i < list.count {
                if seen.insert(list[i].id).inserted { tableHits.append(list[i]) }
            }
            i += 1
        }
        return Array((personalHits + tableHits).prefix(limit + personalHits.count))
    }

    public func lookup(id: String) async -> FoodCandidate? {
        if personal.owns(id) { return try? await personal.lookup(id: id) }
        for s in offline + online where s.owns(id) {
            if let c = try? await s.lookup(id: id) { return c }
        }
        return nil
    }
}
