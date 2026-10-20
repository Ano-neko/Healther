import Foundation

/// Tokenizer for SQLite FTS5 search over mixed Chinese / Latin text.
///
/// FTS5's `unicode61` tokenizer does not segment Chinese, so we pre-tokenize ourselves:
/// CJK runs become unigrams + bigrams, Latin/digit runs become lowercase words.
/// Indexed text is stored as space-separated tokens and matched with a generated query.
///
/// Must stay in sync with `index_tokens` in scripts/build_food_db.py.
public enum SearchTokenizer {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF, 0x3040...0x30FF:
            return true
        default:
            return false
        }
    }

    enum Segment: Equatable {
        case cjk([String])
        case word(String)
    }

    static func segments(_ text: String) -> [Segment] {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        var out: [Segment] = []
        var run: [String] = []
        var word = ""

        func flushRun() { if !run.isEmpty { out.append(.cjk(run)); run.removeAll() } }
        func flushWord() { if !word.isEmpty { out.append(.word(word)); word = "" } }

        for scalar in normalized.unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                run.append(String(scalar))
            } else if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                flushRun()
                word.unicodeScalars.append(scalar)
            } else {
                flushRun()
                flushWord()
            }
        }
        flushRun()
        flushWord()
        return out
    }

    /// Tokens to store in an FTS column.
    public static func indexTokens(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var tokens: [String] = []
        for seg in segments(text) {
            switch seg {
            case .cjk(let chars):
                tokens.append(contentsOf: chars)
                if chars.count > 1 {
                    for i in 0..<(chars.count - 1) { tokens.append(chars[i] + chars[i + 1]) }
                }
            case .word(let w):
                tokens.append(w)
            }
        }
        return tokens.joined(separator: " ")
    }

    /// Query terms: bigrams for multi-char CJK runs (unigram if single char), prefix-matched words.
    public static func queryTerms(_ text: String) -> [String] {
        var terms: [String] = []
        for seg in segments(text) {
            switch seg {
            case .cjk(let chars):
                if chars.count == 1 {
                    terms.append(chars[0])
                } else {
                    for i in 0..<(chars.count - 1) { terms.append(chars[i] + chars[i + 1]) }
                }
            case .word(let w):
                if w.count >= 2 || w.first?.isNumber == true { terms.append(w) }
            }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    /// An FTS5 MATCH expression (OR of quoted terms; Latin words prefix-matched). Nil if nothing searchable.
    public static func matchExpression(_ text: String, columns: [String]? = nil) -> String? {
        let terms = queryTerms(text)
        guard !terms.isEmpty else { return nil }
        let parts = terms.map { term -> String in
            let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let isLatin = term.unicodeScalars.allSatisfy { !isCJK($0) }
            return isLatin && term.count >= 3 ? quoted + "*" : quoted
        }
        let body = parts.joined(separator: " OR ")
        if let columns, !columns.isEmpty {
            return "{" + columns.joined(separator: " ") + "} : (" + body + ")"
        }
        return body
    }

    /// Fraction of the query's terms that occur in `candidate` (0...1). Used for re-ranking.
    public static func coverage(of query: String, in candidate: String) -> Double {
        let q = queryTerms(query)
        guard !q.isEmpty else { return 0 }
        let tokens = Set(indexTokens(candidate).split(separator: " ").map(String.init))
        let hit = q.filter { term in tokens.contains(term) || tokens.contains { $0.hasPrefix(term) && term.count >= 3 } }
        return Double(hit.count) / Double(q.count)
    }
}
