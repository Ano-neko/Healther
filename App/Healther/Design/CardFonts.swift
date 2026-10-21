import CoreText
import HealtherCore
import SwiftUI
import UIKit

/// Fonts for the pinned Today card. Latin text uses the first face; Chinese falls through the
/// cascade list to Apple's downloadable Chinese faces (宋体 / 圆体 / 楷体 / 手札体), fetched on first use.
@MainActor @Observable
final class CardFonts {
    static let shared = CardFonts()

    /// Chinese families downloaded and registered in this process.
    private(set) var ready: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []

    /// nil = the built-in look (SF Rounded titles, SF body, system Chinese fallback).
    func uiFont(_ style: CardFont?, size: CGFloat, bold: Bool) -> UIFont {
        let weight: UIFont.Weight = bold ? .bold : .regular
        let system = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        guard let style else {
            return UIFont(descriptor: bold ? (system.withDesign(.rounded) ?? system) : system, size: size)
        }
        if let family = style.chineseFamily { load(family) }
        var base: UIFontDescriptor
        switch style {
        case .serif:
            base = UIFontDescriptor(name: bold ? "TimesNewRomanPS-BoldMT" : "TimesNewRomanPSMT", size: size)
        case .rounded:
            base = system.withDesign(.rounded) ?? system
        case .system, .kai, .hand:
            base = system
        }
        if let family = style.chineseFamily, isAvailable(family) {
            var cjk = UIFontDescriptor(fontAttributes: [.family: family])
            if bold, let b = cjk.withSymbolicTraits(.traitBold) { cjk = b }
            base = base.addingAttributes([.cascadeList: [cjk]])
        }
        return UIFont(descriptor: base, size: size)
    }

    private func isAvailable(_ family: String) -> Bool {
        ready.contains(family) || !UIFont.fontNames(forFamilyName: family).isEmpty
    }

    /// Called while rendering, so it only starts work; `ready` changes later and re-renders the card.
    private func load(_ family: String) {
        guard !isAvailable(family), !loading.contains(family) else { return }
        loading.insert(family)
        Task {
            let ok = await Self.download(family)
            loading.remove(family)
            if ok { ready.insert(family) }
        }
    }

    /// Asks the system to fetch (or just activate, if already on disk) one of its downloadable families.
    nonisolated static func download(_ family: String) async -> Bool {
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        return await withCheckedContinuation { cont in
            CTFontDescriptorMatchFontDescriptorsWithProgressHandler([desc] as CFArray, nil) { state, _ in
                if state == .didFinish {
                    cont.resume(returning: !UIFont.fontNames(forFamilyName: family).isEmpty)
                }
                return true
            }
        }
    }
}

/// Clamps text to a number of lines and ends it with a baseline "…" drawn in the Latin face.
/// SwiftUI's own truncation takes the ellipsis from the last character's font, which for
/// Chinese text is the centered "⋯" style.
struct ClampedText: View {
    let text: String
    let font: UIFont
    let lines: Int
    var expanded = false
    @State private var width: CGFloat = 0

    var body: some View {
        Text(expanded || width <= 0 ? text : Self.clamp(text, font: font, width: width, lines: lines))
            .font(Font(font as CTFont))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    static func clamp(_ text: String, font: UIFont, width: CGFloat, lines: Int) -> String {
        let w = width - 2  // a little slack so SwiftUI never needs to truncate again
        func height(_ s: String) -> CGFloat {
            (s as NSString).boundingRect(with: CGSize(width: w, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading],
                                         attributes: [.font: font], context: nil).height
        }
        let limit = height(Array(repeating: "测Ag", count: lines).joined(separator: "\n")) + 1
        guard height(text) > limit else { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if height(String(chars[..<mid]) + "…") <= limit { lo = mid } else { hi = mid - 1 }
        }
        let cut = String(chars[..<lo]).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "，、；：,;:")))
        return cut + "…"
    }
}

extension CardFont {
    var chineseFamily: String? {
        switch self {
        case .system: return nil
        case .rounded: return "Yuanti SC"
        case .serif: return "Songti SC"
        case .kai: return "Kaiti SC"
        case .hand: return "Hannotate SC"
        }
    }

    /// Short name for menus.
    var menuTitle: String {
        switch self {
        case .system: return "默认"
        case .rounded: return "圆体"
        case .serif: return "Times New Roman + 宋体"
        case .kai: return "楷体"
        case .hand: return "手札体"
        }
    }
}
