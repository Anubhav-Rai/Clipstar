import SwiftUI

/// How the screenshots fly in when the dock opens, from Arrival in the menu.
/// Closing is the same quick slip past the edges for all of them.
enum Arrival: String, CaseIterable {
    case warp, deep, formation, reentry, wormhole, orbit, hyperjump

    static var current: Arrival {
        get { Arrival(rawValue: UserDefaults.standard.string(forKey: "arrival") ?? "") ?? .warp }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "arrival") }
    }

    var title: String {
        switch self {
        case .warp: L("Warp In")
        case .deep: L("From Deep Space")
        case .formation: L("Formation")
        case .reentry: L("Re-entry")
        case .wormhole: L("Wormhole")
        case .orbit: L("Orbit")
        case .hyperjump: L("Hyperspace Jump")
        }
    }

    /// How long one ship takes, start to port.
    var duration: Double {
        switch self {
        case .warp: 0.6
        case .deep: 1.0
        case .formation: 1.1
        case .reentry: 0.9
        case .wormhole: 1.2
        case .orbit: 1.6
        case .hyperjump: 0.7
        }
    }

    /// Whether ships fire their engines on the way (a warp is too quick to).
    var burns: Bool { self != .warp && self != .hyperjump }

    /// Where a ship is, k of the way from its start (0) to its port (1).
    struct State {
        var at: CGPoint
        var scale: CGFloat = 1
        /// Stretched along the way in by speed, for a warp.
        var stretch: CGFloat = 1
        var hidden = false
        /// The flash of dropping out of hyperspace, and the streak before it.
        var flash: CGFloat = 0
        var streak: CGFloat = 0
        /// Glowing hot on re-entry.
        var heat: CGFloat = 0
    }

    func state(_ k: CGFloat, port: CGPoint, slot: Slot, size: CGSize) -> State {
        let k = min(max(k, 0), 1), n = CGFloat(slot.index)
        func ease(_ p: CGFloat) -> CGFloat { 1 - pow(1 - k, p) }
        let mid = CGPoint(x: size.width * 0.55, y: size.height * 0.5)
        switch self {
        case .warp:
            let e = ease(4), a = slot.approach
            return State(at: CGPoint(x: port.x + a.dx * 1400 * (1 - e), y: port.y + a.dy * 1400 * (1 - e)),
                         stretch: 1 + 2.5 * (1 - e))
        case .deep:
            // From far away near the middle, curving out to the port, growing as it nears.
            let e = ease(2.2)
            let s = CGPoint(x: mid.x + (n.truncatingRemainder(dividingBy: 3) - 1) * 50, y: mid.y + (slot.index % 2 == 0 ? 24 : -24))
            let c = CGPoint(x: (s.x + port.x) / 2 + (port.y - s.y) * 0.25, y: (s.y + port.y) / 2 - (port.x - s.x) * 0.25)
            return State(at: bezier(s, c, port, e), scale: 0.25 + 0.75 * e)
        case .formation:
            // In a line from the empty right side, then into the port.
            let e = ease(2.4)
            let lane = slot.side == .left ? size.height / 2 : port.y
            let s = CGPoint(x: size.width + 120 + n * 34, y: lane)
            return State(at: CGPoint(x: s.x + (port.x - s.x) * e, y: s.y + (port.y - s.y) * pow(e, 3)))
        case .reentry:
            let e = ease(2)
            let s = CGPoint(x: port.x + 160, y: -160)
            return State(at: CGPoint(x: s.x + (port.x - s.x) * e, y: s.y + (port.y - s.y) * e), heat: 1 - k)
        case .wormhole:
            let e = ease(2), a = (1 - e) * 4.5 + n
            return State(at: CGPoint(x: mid.x + (port.x - mid.x) * e + cos(a) * 110 * (1 - e),
                                     y: mid.y + (port.y - mid.y) * e + sin(a) * 70 * (1 - e)),
                         scale: 0.2 + 0.8 * e)
        case .orbit:
            let r = 170 + n * 7, a0 = n * 0.7
            if k < 0.5 {
                let a = k / 0.5 * 2 * .pi + a0
                return State(at: CGPoint(x: mid.x + cos(a) * r, y: mid.y + sin(a) * r * 0.55), scale: 0.7)
            }
            let e = 1 - pow(1 - (k - 0.5) / 0.5, 2)
            let s = CGPoint(x: mid.x + cos(a0) * r, y: mid.y + sin(a0) * r * 0.55)
            return State(at: CGPoint(x: s.x + (port.x - s.x) * e, y: s.y + (port.y - s.y) * e), scale: 0.7 + 0.3 * e)
        case .hyperjump:
            if k < 0.55 { return State(at: port, hidden: true, streak: k / 0.55) }
            return State(at: port, flash: 1 - (k - 0.55) / 0.45)
        }
    }

    private func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

/// Moves a docked card along its arrival, k from 0 (away) to 1 (docked),
/// with its engines burning on the way and a reverse burn as it brakes.
/// Animatable, so every frame of the flight is worked out from k.
struct Flight: ViewModifier, Animatable {
    var k: CGFloat
    let arrival: Arrival
    let port: CGPoint
    let slot: Slot
    let size: CGSize
    let skin: Skin
    /// The screenshot's frame inside the card's box, for the engines.
    let photo: CGRect
    let box: CGSize

    var animatableData: CGFloat {
        get { k }
        set { k = newValue }
    }

    func body(content: Content) -> some View {
        let s = arrival.state(k, port: port, slot: slot, size: size)
        let before = arrival.state(k - 0.02, port: port, slot: slot, size: size)
        let dx = s.at.x - before.at.x, dy = s.at.y - before.at.y, speed = hypot(dx, dy)
        let moving = k > 0.001 && k < 0.999
        return content
            .background {
                if moving { exhaust(s, heading: CGVector(dx: dx, dy: dy), speed: speed) }
            }
            .scaleEffect(x: slot.side.isHorizontal ? 1 : s.stretch, y: slot.side.isHorizontal ? s.stretch : 1)
            .scaleEffect(s.scale)
            .opacity(s.hidden ? 0 : 1)
            .overlay {
                if s.flash > 0 {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.9 * s.flash), .clear], center: .center,
                                                 startRadius: 0, endRadius: box.width * 0.6))
                        .frame(width: box.width * 1.2, height: box.width * 1.2)
                        .allowsHitTesting(false)
                }
            }
            .offset(x: s.at.x - port.x, y: s.at.y - port.y)
            .background {
                if s.streak > 0 && s.streak < 1 { streak(s.streak) }
            }
    }

    /// Engines at the back, a reverse burn at the front near the end, and
    /// heat on re-entry. Drawn in a canvas larger than the card.
    private func exhaust(_ s: Arrival.State, heading: CGVector, speed: CGFloat) -> some View {
        let pad: CGFloat = 260
        return Canvas { ctx, _ in
            let o = CGPoint(x: pad, y: pad)
            let len = max(hypot(heading.dx, heading.dy), 0.001)
            let back = CGVector(dx: -heading.dx / len, dy: -heading.dy / len)
            if s.heat > 0 {
                let c = CGPoint(x: o.x + box.width / 2, y: o.y + box.height / 2 - 10)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 110, y: c.y - 110, width: 220, height: 220)),
                         with: .radialGradient(Gradient(colors: [Color(red: 1, green: 0.48, blue: 0.18).opacity(0.55 * s.heat), .clear]),
                                               center: c, startRadius: 0, endRadius: 110))
            }
            guard arrival.burns, len > 0.3 else { return }
            let flicker = 1 + 0.2 * sin(k * 420 + CGFloat(slot.index)) + 0.1 * sin(k * 760)
            if k < 0.82 {
                let power = min(max(speed / 9, 0.35), 1.8)
                for e in skin.engines {
                    let p = CGPoint(x: o.x + photo.midX + e.x * photo.width / 50, y: o.y + photo.midY + e.y * photo.height / 32)
                    Flight.flame(&ctx, at: p, toward: back, length: (40 + 110 * power) * flicker, width: 10)
                }
            }
            if k > 0.62 && k < 0.95 {
                let r = sin(.pi * (k - 0.62) / 0.33)
                let front = CGPoint(x: o.x + box.width / 2 - back.dx * box.width * 0.42, y: o.y + box.height / 2 - back.dy * box.height * 0.42)
                Flight.flame(&ctx, at: front, toward: CGVector(dx: -back.dx, dy: -back.dy), length: 60 * r * flicker, width: 9 * r + 1)
            }
        }
        .frame(width: box.width + pad * 2, height: box.height + pad * 2)
        .allowsHitTesting(false)
    }

    /// A white-hot core, gold, then orange fading out.
    static func flame(_ ctx: inout GraphicsContext, at p: CGPoint, toward d: CGVector, length: CGFloat, width: CGFloat) {
        let n = CGVector(dx: -d.dy, dy: d.dx)
        let end = CGPoint(x: p.x + d.dx * length, y: p.y + d.dy * length)
        var path = Path()
        path.move(to: CGPoint(x: p.x + n.dx * width, y: p.y + n.dy * width))
        path.addQuadCurve(to: end, control: CGPoint(x: p.x + d.dx * length * 0.5 + n.dx * width * 0.7,
                                                    y: p.y + d.dy * length * 0.5 + n.dy * width * 0.7))
        path.addQuadCurve(to: CGPoint(x: p.x - n.dx * width, y: p.y - n.dy * width),
                          control: CGPoint(x: p.x + d.dx * length * 0.5 - n.dx * width * 0.7,
                                           y: p.y + d.dy * length * 0.5 - n.dy * width * 0.7))
        path.closeSubpath()
        let gold = Color(red: 1, green: 0.88, blue: 0.54)
        ctx.fill(path, with: .linearGradient(Gradient(stops: [
            .init(color: .white.opacity(0.95), location: 0), .init(color: gold.opacity(0.9), location: 0.2),
            .init(color: Color(red: 1, green: 0.55, blue: 0.24).opacity(0.5), location: 0.55),
            .init(color: Color(red: 1, green: 0.31, blue: 0.12).opacity(0), location: 1),
        ]), startPoint: p, endPoint: end))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - width * 1.6, y: p.y - width * 1.6, width: width * 3.2, height: width * 3.2)),
                 with: .radialGradient(Gradient(colors: [gold.opacity(0.6), .clear]), center: p, startRadius: 0, endRadius: width * 1.6))
    }

    /// The light trail of a ship about to drop out of hyperspace.
    private func streak(_ t: CGFloat) -> some View {
        let a = slot.approach
        return Capsule()
            .fill(LinearGradient(colors: [.clear, Color(red: 1, green: 0.88, blue: 0.54)], startPoint: .leading, endPoint: .trailing))
            .frame(width: 260 * t, height: 3)
            .offset(x: 130 * t)
            .rotationEffect(.radians(atan2(-a.dy, -a.dx) + .pi))
            .offset(x: a.dx * 300 * (1 - t), y: a.dy * 300 * (1 - t))
            .opacity(Double(sin(.pi * t)))
            .allowsHitTesting(false)
    }
}
