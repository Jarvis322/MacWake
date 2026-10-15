import SwiftUI

/// The shared "lit from above" look used by the menu panel and the Dynamic Island: tiles
/// and surfaces get a top highlight, a darker lower edge and a soft cast shadow, so
/// everything reads as one physical material instead of flat tinted rectangles.

private struct DepthMotionKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Mirrors the "Enable Animations" setting. Reduce Motion is checked separately at
    /// each use, so either one turning motion off is enough.
    var depthMotionEnabled: Bool {
        get { self[DepthMotionKey.self] }
        set { self[DepthMotionKey.self] = newValue }
    }
}

enum DepthMotion {
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
}

/// An SF Symbol on a raised, glossy squircle. Hovering lifts and tilts it toward the
/// pointer and bounces the glyph — feedback that the row under the cursor is live.
struct DepthIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26
    /// Repeating pulse for states that need attention (warnings, active charging).
    var pulsing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.depthMotionEnabled) private var motionEnabled
    @State private var hovering = false
    @State private var bounce = 0

    private var moves: Bool { motionEnabled && !reduceMotion }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        ZStack {
            shape.fill(tint.gradient)
                .saturation(1.3)
            // Shading: bright crown, neutral middle, darker base — the cheap read of a
            // curved surface without needing a per-tint colour ramp.
            shape.fill(LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.3), location: 0),
                    .init(color: .white.opacity(0.0), location: 0.5),
                    .init(color: .black.opacity(0.14), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            ))
            // Specular gloss across the upper half.
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.86, height: size * 0.5)
                .offset(y: -size * 0.22)
                .blur(radius: size * 0.02)
                .clipShape(shape)
            shape.strokeBorder(LinearGradient(
                colors: [.white.opacity(0.6), .white.opacity(0.08), .black.opacity(0.2)],
                startPoint: .top, endPoint: .bottom
            ), lineWidth: 0.75)
            Image(systemName: symbol)
                .font(.system(size: size * 0.47, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 0.6, y: 0.8)
                .symbolEffect(.bounce, value: bounce)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing && moves)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(hovering ? 0.65 : 0.45), radius: hovering ? 6 : 3, y: hovering ? 3 : 1.5)
        .rotation3DEffect(.degrees(hovering && moves ? 12 : 0), axis: (x: 1, y: -0.7, z: 0), perspective: 0.5)
        .scaleEffect(hovering && moves ? 1.08 : 1)
        .animation(moves ? DepthMotion.spring : nil, value: hovering)
        .onHover { inside in
            hovering = inside
            if inside && moves { bounce += 1 }
        }
        .accessibilityHidden(true)
    }
}

/// Card surface for the light/dark popover: faint fill, a lit top edge and a short shadow
/// so cards sit above the panel instead of being printed onto it.
private struct DepthSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = colorScheme == .dark
        content
            .background {
                ZStack {
                    shape.fill(Color.primary.opacity(dark ? 0.06 : 0.035))
                    if let tint {
                        shape.fill(LinearGradient(colors: [tint.opacity(dark ? 0.3 : 0.24), tint.opacity(0.06)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                            .saturation(1.3)
                    }
                    shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.06 : 0.45), .clear],
                                              startPoint: .top, endPoint: .center))
                }
                .shadow(color: (tint ?? .black).opacity(tint == nil ? (dark ? 0.25 : 0.07) : 0.18), radius: 4, y: 2)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [tint.map { $0.opacity(0.5) } ?? .white.opacity(dark ? 0.16 : 0.8),
                             (tint ?? .primary).opacity(dark ? 0.06 : 0.1)],
                    startPoint: .top, endPoint: .bottom
                ), lineWidth: 0.75)
            }
    }
}

extension View {
    func depthSurface(cornerRadius: CGFloat = 10, tint: Color? = nil) -> some View {
        modifier(DepthSurface(cornerRadius: cornerRadius, tint: tint))
    }

    /// Rolls digits instead of swapping the whole string when a reading changes.
    func rollingDigits<V: Equatable>(_ value: V) -> some View {
        modifier(RollingDigits(value: value))
    }
}

private struct RollingDigits<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.depthMotionEnabled) private var motionEnabled

    func body(content: Content) -> some View {
        content
            .contentTransition(.numericText())
            .animation(motionEnabled && !reduceMotion ? DepthMotion.spring : nil, value: value)
    }
}

/// A glass battery with a liquid fill, used in the panel header. While charging a band of
/// light sweeps through the fill — the same cue as the island's charging ring.
struct DepthBattery: View {
    let level: Int
    let tint: Color
    let charging: Bool
    var width: CGFloat = 38
    var height: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.depthMotionEnabled) private var motionEnabled

    private var fraction: CGFloat { CGFloat(min(100, max(0, level))) / 100 }
    private var sweeps: Bool { charging && motionEnabled && !reduceMotion }

    var body: some View {
        let radius = height * 0.32
        let shell = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let inset: CGFloat = 2
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                shell.fill(Color.primary.opacity(0.1))
                // Liquid fill, shaded like a cylinder (bright top, deep bottom).
                RoundedRectangle(cornerRadius: radius - inset, style: .continuous)
                    .fill(tint.gradient)
                    .saturation(1.3)
                    .overlay(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.45), location: 0),
                            .init(color: .white.opacity(0.0), location: 0.45),
                            .init(color: .black.opacity(0.15), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .overlay { if sweeps { chargeSweep } }
                    .clipShape(RoundedRectangle(cornerRadius: radius - inset, style: .continuous))
                    .frame(width: max(3, (width - inset * 2) * fraction))
                    .padding(inset)
                    .animation(motionEnabled && !reduceMotion ? .smooth(duration: 0.6) : nil, value: level)
                // Glass shell: gloss on top, lit rim.
                shell.fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                          startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false)
                shell.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .primary.opacity(0.25)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: height * 0.62, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1, y: 0.5)
                        .frame(maxWidth: .infinity)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: width, height: height)
            Capsule()
                .fill(Color.primary.opacity(0.3))
                .frame(width: 2.5, height: height * 0.38)
        }
        .shadow(color: tint.opacity(0.55), radius: 4, y: 1.5)
        .animation(motionEnabled && !reduceMotion ? DepthMotion.spring : nil, value: charging)
        .accessibilityHidden(true)
    }

    private var chargeSweep: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let period = 1.8
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.5)
                    .offset(x: -proxy.size.width * 0.5 + proxy.size.width * 1.5 * phase)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A lit sphere behind a symbol — the island's equivalent of `DepthIcon`, drawn for a
/// black background where a squircle tile would look like a stuck-on sticker.
struct DepthOrb: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 64
    /// Expanding rings radiating from the orb, for "something is happening right now".
    var ripples = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.depthMotionEnabled) private var motionEnabled
    @State private var appeared = 0

    private var moves: Bool { motionEnabled && !reduceMotion }

    var body: some View {
        ZStack {
            if ripples && moves {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<2, id: \.self) { index in
                            let phase = (t / 2.0 + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(tint.opacity(0.5 * (1 - phase)), lineWidth: 1.5)
                                .scaleEffect(1 + phase * 0.45)
                        }
                    }
                }
                .frame(width: size, height: size)
            }
            Circle()
                .fill(RadialGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.55), tint.opacity(0.18)],
                    center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.62
                ))
            Circle()
                .fill(RadialGradient(colors: [.black.opacity(0), .black.opacity(0.45)],
                                     center: .center, startRadius: size * 0.25, endRadius: size * 0.52))
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.6, height: size * 0.34)
                .offset(y: -size * 0.24)
                .blur(radius: 1)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1.5)
                .symbolEffect(.bounce, value: appeared)
        }
        .frame(width: size, height: size)
        .shadow(color: tint.opacity(0.55), radius: size * 0.22)
        .onAppear { if moves { appeared += 1 } }
        .accessibilityHidden(true)
    }
}
