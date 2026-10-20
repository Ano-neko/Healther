import SwiftUI

/// The agent's face: a living fluid orb. Each state changes palette, flow speed and breathing.
enum OrbState: Equatable {
    case idle, thinking, speaking, working, offline

    var palette: [Color] {
        switch self {
        case .idle: return [Theme.pink, Theme.blue, Theme.lilac, Theme.deepBlue]
        case .thinking: return [Theme.lilac, Theme.deepBlue, Theme.blue, Theme.rose]
        case .speaking: return [Theme.pink, Theme.blue, Theme.pink, Theme.lilac]
        case .working: return [Theme.amber, Theme.coral, Theme.lilac, Theme.blue]
        case .offline: return [Color.gray, Color.gray.opacity(0.6), Color.gray.opacity(0.4), Color.gray.opacity(0.3)]
        }
    }

    var flow: Double {
        switch self {
        case .idle: return 0.6
        case .thinking: return 2.2
        case .speaking: return 1.5
        case .working: return 2.6
        case .offline: return 0.2
        }
    }

    var glow: Color { palette[0] }
}

struct AgentOrb: View {
    var state: OrbState = .idle
    var size: CGFloat = 120

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let p = state.palette
            let breath = 1 + (state == .thinking ? 0.05 : 0.03) * sin(t * (state == .speaking ? 5 : 1.6))
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [state.glow.opacity(0.55), state.glow.opacity(0)], center: .center,
                                         startRadius: size * 0.2, endRadius: size * 0.95))
                    .frame(width: size * 1.9, height: size * 1.9)
                    .blur(radius: size * 0.12)
                    .opacity(0.8 + 0.2 * sin(t * 1.3))

                MeshGradient(width: 3, height: 3, points: Self.points(t * state.flow),
                             colors: [p[3], p[0], p[2], p[1], p[0], p[3], p[2], p[1], p[0]])
                    .hueRotation(.degrees(sin(t * 0.3) * 18))
                    .clipShape(Circle())
                    .overlay {
                        // Specular highlight gives the glassy sphere look.
                        Circle()
                            .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)], startPoint: .top, endPoint: .center))
                            .padding(size * 0.14)
                            .offset(y: -size * 0.16)
                            .blur(radius: size * 0.05)
                            .blendMode(.screen)
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: max(0.5, size / 160)))
                    .shadow(color: state.glow.opacity(0.6), radius: size * 0.18)
                    .frame(width: size, height: size)
                    .scaleEffect(breath)
            }
            .frame(width: size, height: size)
        }
        .animation(.easeInOut(duration: 0.6), value: state)
        .accessibilityHidden(true)
    }

    static func points(_ t: Double) -> [SIMD2<Float>] {
        func w(_ phase: Double, _ freq: Double, _ amp: Double = 0.2) -> Float { Float(0.5 + amp * sin(t * freq + phase)) }
        return [
            [0, 0], [w(0, 0.9), 0], [1, 0],
            [0, w(1, 1.1)], [w(2, 0.7, 0.25), w(3, 1.3, 0.25)], [1, w(4, 0.8)],
            [0, 1], [w(5, 1.2), 1], [1, 1],
        ]
    }
}

#Preview {
    ZStack {
        AuroraBackground()
        VStack(spacing: 40) {
            AgentOrb(state: .idle, size: 140)
            HStack(spacing: 30) {
                AgentOrb(state: .thinking, size: 60)
                AgentOrb(state: .working, size: 60)
                AgentOrb(state: .speaking, size: 60)
            }
        }
    }
}
