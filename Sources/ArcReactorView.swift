import SwiftUI

/// A JARVIS / arc-reactor style HUD core for the Dynamic Island.
/// Rotating tick rings, a pulsing glowing core (pulse speed tracks charging watts),
/// a battery-level progress arc, and a state-driven color (cyan / red / amber).
struct ArcReactorView: View {
    let level: Int          // 0…100
    let isCharging: Bool
    let temperature: Double // battery °C
    let watts: Double       // power draw → pulse speed while charging

    private var fill: CGFloat { CGFloat(min(max(level, 0), 100)) / 100 }
    private var isHot: Bool { temperature > 42 }
    private var isLow: Bool { level < 20 && !isCharging }

    private var core: Color {
        if isHot { return Color(red: 1.0, green: 0.62, blue: 0.18) }   // amber
        if isLow { return Color(red: 1.0, green: 0.30, blue: 0.34) }   // red
        return Color(red: 0.30, green: 0.80, blue: 1.0)                // arc-reactor cyan
    }

    /// Faster, stronger pulse the more power is flowing in.
    private var pulseHz: Double { isCharging ? (0.8 + min(watts, 100) / 45) : 0.5 }

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = (sin(t * pulseHz * 2 * .pi) + 1) / 2            // 0…1
            let glow = 0.55 + 0.45 * pulse

            ZStack {
                // Outer rotating tick ring (HUD)
                TickRing(ticks: 60, longEvery: 5)
                    .stroke(core.opacity(0.45), lineWidth: 1)
                    .rotationEffect(.degrees(t * 6))

                // Inner counter-rotating dashed ring
                Circle()
                    .inset(by: 16)
                    .stroke(core.opacity(0.30), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))
                    .rotationEffect(.degrees(-t * 14))

                // Battery-level progress arc
                Circle()
                    .inset(by: 9)
                    .trim(from: 0, to: fill)
                    .stroke(core.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: core.opacity(glow * 0.8), radius: 4)

                // Rotating scan sweep
                Circle()
                    .inset(by: 9)
                    .trim(from: 0, to: 0.16)
                    .stroke(
                        AngularGradient(colors: [core.opacity(0), core.opacity(0.7)],
                                        center: .center),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(t * 80))

                // Glowing core
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [core.opacity(glow), core.opacity(0.05)],
                            center: .center, startRadius: 1, endRadius: 34))
                        .blur(radius: 3)
                    Circle()
                        .fill(core.opacity(0.18 + 0.20 * pulse))
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(core.opacity(0.8), lineWidth: 1.2))
                    // Reactor triangle/segments hint
                    Image(systemName: isCharging ? "bolt.fill" : "atom")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: core.opacity(glow), radius: 6)
                }
                .scaleEffect(0.96 + 0.06 * pulse)
            }
            .frame(width: 96, height: 96)
            .drawingGroup()
        }
    }
}

/// A ring of radial tick marks, with longer ticks every `longEvery`.
private struct TickRing: Shape {
    let ticks: Int
    let longEvery: Int
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rOuter = min(rect.width, rect.height) / 2
        for i in 0..<ticks {
            let isLong = i % longEvery == 0
            let len: CGFloat = isLong ? 7 : 3.5
            let a = Double(i) / Double(ticks) * 2 * .pi
            let r1 = rOuter - len
            let r2 = rOuter
            p.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        }
        return p
    }
}
