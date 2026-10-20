import Testing
@testable import HealtherCore

@Suite struct TokenizerTests {
    @Test func indexesCJKAsUnigramsAndBigrams() {
        #expect(SearchTokenizer.indexTokens("鸡腿饭") == "鸡 腿 饭 鸡腿 腿饭")
        #expect(SearchTokenizer.indexTokens("Chicken 鸡腿, raw") == "chicken 鸡 腿 鸡腿 raw")
    }

    @Test func queryUsesBigramsAndPrefixes() {
        #expect(SearchTokenizer.queryTerms("番茄炒蛋") == ["番茄", "茄炒", "炒蛋"])
        #expect(SearchTokenizer.queryTerms("蛋 egg") == ["蛋", "egg"])
        #expect(SearchTokenizer.matchExpression("chicken 腿") == "\"chicken\"* OR \"腿\"")
    }

    @Test func coverage() {
        #expect(SearchTokenizer.coverage(of: "番茄炒蛋", in: "番茄炒蛋(家常)") == 1.0)
        #expect(SearchTokenizer.coverage(of: "番茄炒蛋", in: "红番茄") > 0.3)
    }
}
