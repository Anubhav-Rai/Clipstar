import SwiftUI

enum Layout {
    /// How big the docked screenshots are, from Size in the menu bar.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (96 * size.scale).rounded() }
    static var cardWidth: CGFloat { (140 * size.scale).rounded() }
}

/// The whole screen while the dock is open: a HUD frame round the edges with
/// a port for every screenshot, and the screenshots docked at them.
struct DockView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let ring = Dock.ring(in: size)
            let gate = Dock.gate(in: size)
            let live = line.items.filter { !$0.falling }
            let overflow = live.count > ring.count
            ZStack(alignment: .topLeading) {
                HUD(size: size, slots: ring, docked: Set(0..<min(live.count, ring.count)), on: line.revealed)
                Hyperspace(size: size, on: line.revealed)

                if overflow {
                    Gate(on: line.revealed)
                        .position(gate)
                    Counter(first: Int(CGFloat(live.count - ring.count) - line.scroll.rounded()) + 1,
                            last: Int(CGFloat(live.count) - line.scroll.rounded()), total: live.count, on: line.revealed)
                        .position(x: size.width / 2, y: Dock.topBand + 22)
                }

                if line.items.isEmpty && line.revealed {
                    Hint()
                        .position(x: size.width / 2, y: size.height / 2)
                        .transition(.opacity)
                }

                ForEach(line.items) { item in
                    if let p = line.ringPosition(of: item.id),
                       let place = Dock.place(at: p, ring: ring, gate: gate) {
                        DockedView(item: item, line: line, slot: place.slot)
                            .frame(width: Dock.box.width, height: Dock.box.height)
                            .scaleEffect(place.scale)
                            .rotationEffect(.degrees(place.spin))
                            .opacity(place.opacity)
                            .position(place.center)
                            .transition(.identity)
                    }
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: line.items.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

/// The warp gate: a spinning portal in the corner while some screenshots
/// wait there.
private struct Gate: View {
    let on: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !on)) { context in
            let a = context.date.timeIntervalSinceReferenceDate * 140
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.8), Dock.cyan.opacity(0.5), Dock.cyan.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 30))
                    .frame(width: 60, height: 60)
                Circle()
                    .stroke(Dock.cyan, style: StrokeStyle(lineWidth: 2.5, dash: [14, 8]))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(a))
                    .shadow(color: Dock.cyan, radius: 4)
                Circle()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 1.4, dash: [6, 6]))
                    .frame(width: 20, height: 20)
                    .rotationEffect(.degrees(-a * 1.5))
            }
        }
        .opacity(on ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: on)
        .allowsHitTesting(false)
    }
}

/// Which of them the ring shows, while there are more than ports.
private struct Counter: View {
    let first: Int
    let last: Int
    let total: Int
    let on: Bool

    var body: some View {
        Text("\(first)–\(last) of \(total)")
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(Dock.cyan)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(Dock.cyan.opacity(0.6), lineWidth: 1))
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: 0.3), value: on)
            .allowsHitTesting(false)
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(Dock.cyan)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(Dock.cyan.opacity(0.6), lineWidth: 1))
            .shadow(color: Dock.cyan.opacity(0.5), radius: 6)
            .allowsHitTesting(false)
    }
}

/// The frame round the screen. Opening the dock powers it on: the corner
/// brackets snap out, the rail traces itself round, the ports light up.
/// Free ports glow amber, taken ones cyan.
struct HUD: View {
    let size: CGSize
    let slots: [Slot]
    let docked: Set<Int>
    let on: Bool

    @State private var power: CGFloat = 0

    var body: some View {
        let r = Dock.rail
        let frame = CGRect(x: r, y: r, width: size.width - 2 * r, height: size.height - 2 * r)
        ZStack(alignment: .topLeading) {
            // A dark line under every bright one, so the HUD reads on light
            // backgrounds as well as dark.
            Rectangle().path(in: frame).trim(from: 0, to: power)
                .stroke(Color.black.opacity(0.25), lineWidth: 3)
            Rectangle().path(in: frame).trim(from: 0, to: power)
                .stroke(Dock.cyan.opacity(0.45), lineWidth: 1)
                .shadow(color: Dock.cyan.opacity(0.8), radius: 3)

            Canvas { ctx, _ in
                var ticks = Path()
                var x = r + 20
                while x < size.width - r {
                    ticks.move(to: CGPoint(x: x, y: r)); ticks.addLine(to: CGPoint(x: x, y: r + 4))
                    ticks.move(to: CGPoint(x: x, y: size.height - r)); ticks.addLine(to: CGPoint(x: x, y: size.height - r - 4))
                    x += 20
                }
                var y = r + 20
                while y < size.height - r {
                    ticks.move(to: CGPoint(x: r, y: y)); ticks.addLine(to: CGPoint(x: r + 4, y: y))
                    ticks.move(to: CGPoint(x: size.width - r, y: y)); ticks.addLine(to: CGPoint(x: size.width - r - 4, y: y))
                    y += 20
                }
                ctx.stroke(ticks, with: .color(Dock.cyan.opacity(0.35)), lineWidth: 1)
            }
            .opacity(Double(power))

            ForEach(0..<4, id: \.self) { corner in
                Bracket(corner: corner, size: size, length: 34 * power)
                    .stroke(Dock.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .shadow(color: Dock.cyan, radius: 4)
            }

            ForEach(slots, id: \.index) { slot in
                let taken = docked.contains(slot.index)
                RoundedRectangle(cornerRadius: 2)
                    .fill(taken ? Dock.cyan : Dock.amber)
                    .frame(width: slot.side.isHorizontal ? 34 : 6, height: slot.side.isHorizontal ? 6 : 34)
                    .shadow(color: taken ? Dock.cyan : Dock.amber, radius: 4)
                    .opacity(Double(power) * (taken ? 1 : 0.7))
                    .position(slot.port)
                    .animation(.easeOut(duration: 0.25), value: taken)
            }
        }
        .allowsHitTesting(false)
        .onAppear { if on { powerUp() } }
        .onChange(of: on) { _, now in now ? powerUp() : powerDown() }
    }

    private func powerUp() {
        power = 0
        withAnimation(.easeOut(duration: 0.45)) { power = 1 }
    }

    private func powerDown() {
        withAnimation(.easeIn(duration: 0.3).delay(0.3)) { power = 0 }
    }
}

/// One corner bracket of the frame, `length` long on each arm.
private struct Bracket: Shape {
    let corner: Int
    let size: CGSize
    var length: CGFloat

    var animatableData: CGFloat {
        get { length }
        set { length = newValue }
    }

    func path(in _: CGRect) -> Path {
        let r = Dock.rail
        let (x, y, sx, sy): (CGFloat, CGFloat, CGFloat, CGFloat) = switch corner {
        case 0: (r, r, 1, 1)
        case 1: (size.width - r, r, -1, 1)
        case 2: (r, size.height - r, 1, -1)
        default: (size.width - r, size.height - r, -1, -1)
        }
        var p = Path()
        p.move(to: CGPoint(x: x, y: y + sy * length))
        p.addLine(to: CGPoint(x: x, y: y))
        p.addLine(to: CGPoint(x: x + sx * length, y: y))
        return p
    }
}

/// Light streaks bursting from the middle of the screen while the fleet
/// drops out of warp, and again as it jumps away.
private struct Hyperspace: View {
    let size: CGSize
    let on: Bool

    @State private var since: Date?

    private static let length: TimeInterval = 0.9

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: since == nil)) { context in
            Canvas { ctx, _ in
                guard let since else { return }
                let t = context.date.timeIntervalSince(since)
                let rise = min(max((t - 0.05) / 0.2, 0), 1), fall = 1 - min(max((t - 0.4) / 0.45, 0), 1)
                let s = CGFloat(rise * fall)
                guard s > 0 else { return }
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let reach = max(size.width, size.height) / 2
                var lines = Path()
                for i in 0..<64 {
                    let a = Double(i) * 2.39996
                    let r0 = reach * (0.12 + 0.35 * CGFloat((i * 37) % 100) / 100)
                    let len = reach * (0.2 + 0.5 * CGFloat((i * 53) % 100) / 100) * s
                    let dx = CGFloat(cos(a)), dy = CGFloat(sin(a)) * 0.62
                    lines.move(to: CGPoint(x: c.x + dx * r0, y: c.y + dy * r0))
                    lines.addLine(to: CGPoint(x: c.x + dx * (r0 + len), y: c.y + dy * (r0 + len)))
                }
                ctx.stroke(lines, with: .color(Color(red: 0.87, green: 0.99, blue: 1).opacity(0.5 * Double(s))), lineWidth: 1.2)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: on) { _, _ in burst() }
    }

    private func burst() {
        let now = Date()
        since = now
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.length) {
            if since == now { since = nil }
        }
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
