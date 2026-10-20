import SwiftUI

enum Theme {
    static let background = Color(red: 0.02, green: 0.03, blue: 0.06)
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.10)

    // Brand: blue #7799CC is the primary color; pink #FF8899 is a sparing accent.
    // Lilac and deep blue bridge the two.
    static let pink = Color(red: 1.00, green: 0.533, blue: 0.60)
    static let blue = Color(red: 0.467, green: 0.60, blue: 0.80)
    static let lilac = Color(red: 0.70, green: 0.60, blue: 0.84)
    static let deepBlue = Color(red: 0.29, green: 0.37, blue: 0.60)
    static let coral = Color(red: 1.00, green: 0.52, blue: 0.40)
    static let amber = Color(red: 1.00, green: 0.78, blue: 0.36)
    static let rose = Color(red: 1.00, green: 0.36, blue: 0.42)

    static let protein = Color(red: 0.36, green: 0.80, blue: 1.00)
    static let fat = Color(red: 1.00, green: 0.74, blue: 0.32)
    static let carbs = Color(red: 0.60, green: 0.52, blue: 1.00)

    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)

    static let brandGradient = LinearGradient(colors: [blue, lilac, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let energyGradient = AngularGradient(colors: [amber, coral, rose, amber], center: .center)
}

extension Font {
    /// Rounded, monospaced digits — every number in the app uses this.
    static func metric(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension View {
    /// Liquid Glass card used across the app.
    func glassCard(cornerRadius: CGFloat = 24, padding: CGFloat = 16, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.16)) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
    }

    func sectionLabel() -> some View {
        self.font(.system(size: 12, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .kerning(1.2)
            .foregroundStyle(Theme.tertiaryText)
    }
}

/// Slowly drifting aurora behind every screen.
struct AuroraBackground: View {
    var intensity: Double = 1

    static func points(_ t: Double) -> [SIMD2<Float>] {
        func f(_ x: Double) -> Float { Float(x) }
        return [
            [0, 0], [f(0.5 + 0.2 * sin(t)), 0], [1, 0],
            [0, f(0.45 + 0.15 * cos(t * 0.8))], [f(0.5 + 0.18 * cos(t * 1.1)), f(0.5 + 0.18 * sin(t * 0.9))], [1, f(0.55 + 0.15 * sin(t * 0.7))],
            [0, 1], [f(0.5 + 0.2 * cos(t * 0.6)), 1], [1, 1],
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate / 9
            ZStack {
                Theme.background
                MeshGradient(
                    width: 3, height: 3,
                    points: Self.points(t),
                    colors: [
                        Theme.blue.opacity(0.50 * intensity), Theme.background, Theme.lilac.opacity(0.24 * intensity),
                        Theme.background, Theme.pink.opacity(0.10 * intensity), Theme.background,
                        Theme.deepBlue.opacity(0.40 * intensity), Theme.background, Theme.blue.opacity(0.32 * intensity),
                    ]
                )
                .blur(radius: 60)
                .opacity(0.9)
            }
            .ignoresSafeArea()
        }
    }
}

/// Small rounded tag.
struct Chip: View {
    var text: String
    var color: Color = Theme.blue
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
    }
}
