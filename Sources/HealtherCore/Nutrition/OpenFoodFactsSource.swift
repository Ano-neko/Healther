import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open Food Facts (ODbL): packaged products by barcode or name. Queried live, never bundled.
public struct OpenFoodFactsSource: FoodDataSource {
    public let idPrefixes = ["off"]
    var base = URL(string: "https://world.openfoodfacts.org")!
    var userAgent = "Healther/0.1 (personal health app; https://github.com/)"

    public init() {}

    static let fields = "code,product_name,product_name_zh,product_name_en,brands,serving_quantity,nutriments"

    func get(_ url: URL) async throws -> JSONValue {
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .null }
        return try JSONValue.parse(data)
    }

    static func candidate(_ p: JSONValue) -> FoodCandidate? {
        guard let code = p["code"]?.stringValue, let n = p["nutriments"],
              let kcal = n["energy-kcal_100g"]?.doubleValue ?? n["energy_100g"]?.doubleValue.map({ $0 / 4.184 }) else { return nil }
        let name = [p["product_name_zh"], p["product_name"], p["product_name_en"]]
            .compactMap { $0?.stringValue }.first { !$0.isEmpty } ?? code
        let brand = p["brands"]?.stringValue
        return FoodCandidate(
            id: "off:\(code)", source: .openFoodFacts,
            name: brand.map { "\(name)（\($0)）" } ?? name,
            nameEN: p["product_name_en"]?.stringValue,
            per100g: Nutrients(
                kcal: kcal, protein: n["proteins_100g"]?.doubleValue ?? 0, fat: n["fat_100g"]?.doubleValue ?? 0,
                carbs: n["carbohydrates_100g"]?.doubleValue ?? 0, fiber: n["fiber_100g"]?.doubleValue,
                sugar: n["sugars_100g"]?.doubleValue, sodiumMg: n["sodium_100g"]?.doubleValue.map { $0 * 1000 },
                saturatedFat: n["saturated-fat_100g"]?.doubleValue),
            typicalGrams: p["serving_quantity"]?.doubleValue)
    }

    public func search(_ query: String, limit: Int) async throws -> [FoodCandidate] {
        var c = URLComponents(url: base.appendingPathComponent("cgi/search.pl"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "search_terms", value: query), .init(name: "search_simple", value: "1"),
            .init(name: "json", value: "1"), .init(name: "page_size", value: String(limit)),
            .init(name: "fields", value: Self.fields),
        ]
        let v = try await get(c.url!)
        return (v["products"]?.arrayValue ?? []).compactMap(Self.candidate)
    }

    public func lookup(id: String) async throws -> FoodCandidate? {
        let code = String(id.split(separator: ":").last ?? "")
        return try await barcode(code)
    }

    public func barcode(_ code: String) async throws -> FoodCandidate? {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("api/v2/product/\(digits).json"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "fields", value: Self.fields)]
        let v = try await get(c.url!)
        guard v["status"]?.intValue == 1, var p = v["product"] else { return nil }
        if case .object(var o) = p, o["code"] == nil { o["code"] = .string(digits); p = .object(o) }
        return Self.candidate(p)
    }
}
