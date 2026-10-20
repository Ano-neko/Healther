import Foundation

public struct Nutrients: Codable, Sendable, Hashable {
    public var kcal: Double
    public var protein: Double
    public var fat: Double
    public var carbs: Double
    public var fiber: Double?
    public var sugar: Double?
    public var sodiumMg: Double?
    public var saturatedFat: Double?

    public init(kcal: Double, protein: Double = 0, fat: Double = 0, carbs: Double = 0,
                fiber: Double? = nil, sugar: Double? = nil, sodiumMg: Double? = nil, saturatedFat: Double? = nil) {
        self.kcal = kcal
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.fiber = fiber
        self.sugar = sugar
        self.sodiumMg = sodiumMg
        self.saturatedFat = saturatedFat
    }

    public static let zero = Nutrients(kcal: 0)

    public func scaled(_ factor: Double) -> Nutrients {
        Nutrients(kcal: kcal * factor, protein: protein * factor, fat: fat * factor, carbs: carbs * factor,
                  fiber: fiber.map { $0 * factor }, sugar: sugar.map { $0 * factor },
                  sodiumMg: sodiumMg.map { $0 * factor }, saturatedFat: saturatedFat.map { $0 * factor })
    }

    public static func + (a: Nutrients, b: Nutrients) -> Nutrients {
        func add(_ x: Double?, _ y: Double?) -> Double? { x == nil && y == nil ? nil : (x ?? 0) + (y ?? 0) }
        return Nutrients(kcal: a.kcal + b.kcal, protein: a.protein + b.protein, fat: a.fat + b.fat, carbs: a.carbs + b.carbs,
                         fiber: add(a.fiber, b.fiber), sugar: add(a.sugar, b.sugar),
                         sodiumMg: add(a.sodiumMg, b.sodiumMg), saturatedFat: add(a.saturatedFat, b.saturatedFat))
    }

    /// Compact JSON for the model.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "kcal": .rounded(kcal, 0), "protein_g": .rounded(protein), "fat_g": .rounded(fat), "carbs_g": .rounded(carbs),
        ]
        if let fiber { o["fiber_g"] = .rounded(fiber) }
        if let sodiumMg { o["sodium_mg"] = .rounded(sodiumMg, 0) }
        return .object(o)
    }

    /// Accepts `{kcal, protein(_g), fat(_g), carbs(_g), ...}` from the model.
    public init?(json: JSONValue?) {
        guard let j = json, let kcal = j["kcal"]?.doubleValue else { return nil }
        func v(_ k: String) -> Double? { j[k]?.doubleValue ?? j[k + "_g"]?.doubleValue }
        self.init(kcal: kcal, protein: v("protein") ?? 0, fat: v("fat") ?? 0, carbs: v("carbs") ?? 0,
                  fiber: v("fiber"), sugar: v("sugar"), sodiumMg: j["sodium_mg"]?.doubleValue, saturatedFat: v("saturated_fat"))
    }
}

public enum FoodSource: String, Codable, Sendable, Hashable, CaseIterable {
    case personal
    case taiwanFDA = "tw_fda"
    case usdaSR = "usda_sr"
    case usdaFoundation = "usda_foundation"
    case openFoodFacts = "off"
    case estimate

    public var displayName: String {
        switch self {
        case .personal: return "我的食物库"
        case .taiwanFDA: return "台湾食品成分库"
        case .usdaSR, .usdaFoundation: return "USDA"
        case .openFoodFacts: return "Open Food Facts"
        case .estimate: return "AI 估算"
        }
    }
}

public struct FoodCandidate: Codable, Sendable, Hashable, Identifiable {
    /// Namespaced id: `personal:12`, `tw:J0200201`, `usda:167512`, `off:6901234567890`.
    public var id: String
    public var source: FoodSource
    public var name: String
    public var nameEN: String?
    public var aliases: String?
    public var category: String?
    public var detail: String?
    public var per100g: Nutrients
    /// Usual portion (personal history or package serving).
    public var typicalGrams: Double?
    public var useCount: Int?

    public init(id: String, source: FoodSource, name: String, nameEN: String? = nil, aliases: String? = nil,
                category: String? = nil, detail: String? = nil, per100g: Nutrients, typicalGrams: Double? = nil, useCount: Int? = nil) {
        self.id = id
        self.source = source
        self.name = name
        self.nameEN = nameEN
        self.aliases = aliases
        self.category = category
        self.detail = detail
        self.per100g = per100g
        self.typicalGrams = typicalGrams
        self.useCount = useCount
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "food_id": .string(id), "name": .string(name), "source": .string(source.rawValue), "per100g": per100g.json,
        ]
        if let nameEN, nameEN != name { o["name_en"] = .string(nameEN) }
        if let aliases { o["aliases"] = .string(String(aliases.prefix(40))) }
        if let detail { o["detail"] = .string(String(detail.prefix(60))) }
        if let typicalGrams { o["typical_g"] = .rounded(typicalGrams, 0) }
        if let useCount, useCount > 0 { o["times_eaten"] = .number(Double(useCount)) }
        return .object(o)
    }
}

public enum Confidence: String, Codable, Sendable, Hashable {
    case high, medium, low
}

public enum MealType: String, Codable, Sendable, Hashable, CaseIterable {
    case breakfast, lunch, dinner, snack

    public var displayName: String {
        switch self {
        case .breakfast: return "早餐"
        case .lunch: return "午餐"
        case .dinner: return "晚餐"
        case .snack: return "加餐"
        }
    }

    public static func guess(at date: Date, clock: DayClock) -> MealType {
        switch clock.hour(date) {
        case 5..<10: return .breakfast
        case 10..<15: return .lunch
        case 17..<21: return .dinner
        default: return .snack
        }
    }
}

public struct MealItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var grams: Double
    public var foodID: String?
    public var source: FoodSource
    public var per100g: Nutrients
    public var confidence: Confidence
    public var note: String?

    public init(id: UUID = UUID(), name: String, grams: Double, foodID: String?, source: FoodSource, per100g: Nutrients,
                confidence: Confidence, note: String? = nil) {
        self.id = id
        self.name = name
        self.grams = grams
        self.foodID = foodID
        self.source = source
        self.per100g = per100g
        self.confidence = confidence
        self.note = note
    }

    public var nutrients: Nutrients { per100g.scaled(grams / 100) }
}

public enum MealStatus: String, Codable, Sendable {
    case draft, confirmed
}

public struct Meal: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var status: MealStatus
    public var type: MealType
    public var eatenAt: Date
    public var note: String?
    public var items: [MealItem]
    public var photo: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), status: MealStatus = .draft, type: MealType, eatenAt: Date, note: String? = nil,
                items: [MealItem], photo: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.status = status
        self.type = type
        self.eatenAt = eatenAt
        self.note = note
        self.items = items
        self.photo = photo
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var totals: Nutrients { items.reduce(.zero) { $0 + $1.nutrients } }

    /// Short id the model can quote back (first 8 hex chars).
    public var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    public func json(clock: DayClock) -> JSONValue {
        [
            "meal_id": .string(shortID),
            "status": .string(status.rawValue),
            "meal_type": .string(type.rawValue),
            "eaten_at": .string(clock.stamp(eatenAt)),
            "note": JSONValue(note),
            "items": .array(items.map { item in
                [
                    "name": .string(item.name), "grams": .rounded(item.grams, 0), "source": .string(item.source.rawValue),
                    "confidence": .string(item.confidence.rawValue), "kcal": .rounded(item.nutrients.kcal, 0),
                ]
            }),
            "totals": totals.json,
        ]
    }
}
