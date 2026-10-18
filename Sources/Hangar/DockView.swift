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

/// The whole screen while the dock is open: the Milky Way behind, a trail
/// of stardust along the rail, and the screenshots riding it, newest at the
/// middle of the top.
struct DockView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let ring = Dock.ring(in: size)
            let head = Dock.head(in: size)
            let tail = Dock.gate(in: size)
            let live = line.items.filter { !$0.falling }
            let older = max(0, live.count - ring.count - Int(line.scroll.rounded()))
            let newer = Int(line.scroll.rounded())
            ZStack(alignment: .topLeading) {
                SpaceBackground(size: size, ring: ring, head: head, tail: tail, on: line.revealed, instant: line.instant)
                if !line.instant { Hyperspace(size: size, on: line.revealed) }

                if !live.isEmpty {
                    Beacon(label: newer > 0 ? "+\(newer) newer" : nil, on: line.revealed)
                        .position(head)
                    Swirl(label: older > 0 ? "+\(older)" : nil, on: line.revealed)
                        .position(tail)
                }

                if line.items.isEmpty && line.revealed {
                    Hint()
                        .position(x: size.width / 2, y: size.height / 2)
                        .transition(.opacity)
                }

                let zoomedAt = line.zoomID.flatMap { line.ringPosition(of: $0) }
                ForEach(line.items) { item in
                    if let p = ringPosition(item.id, zoomedAt: zoomedAt), let number = line.number(of: item.id),
                       let place = Dock.place(at: p, ring: ring, head: head, tail: tail) {
                        let zoomed = line.zoomID == item.id
                        DockedView(item: item, line: line, slot: place.slot, number: number,
                                   zoom: zoomed ? line.zoom : 1,
                                   // Grows towards the middle of the screen, so it never runs off an edge.
                                   anchor: UnitPoint(x: place.center.x / max(size.width, 1),
                                                     y: place.center.y / max(size.height, 1)))
                            .frame(width: Dock.box.width, height: Dock.box.height)
                            .zIndex(zoomed ? 10 : 0)
                            .scaleEffect(place.scale)
                            .opacity(place.opacity)
                            .position(place.center)
                            .transition(.identity)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }

    /// Where a card rides, with room made round a zoomed one: its neighbours
    /// slide along the rail away from it, half a card further for each
    /// time it doubles.
    private func ringPosition(_ id: UUID, zoomedAt: CGFloat?) -> CGFloat? {
        guard let p = line.ringPosition(of: id) else { return nil }
        guard let z = zoomedAt, id != line.zoomID else { return p }
        let push = (line.zoom - 1) * 0.6
        return p < z ? p - push : p + push
    }
}

/// The head of the rail, where the newest arrive: a bright star. While the
/// ring is turned back it says how many newer ones are past it.
private struct Beacon: View {
    let label: String?
    let on: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !on)) { context in
            let pulse = 1 + 0.15 * sin(context.date.timeIntervalSinceReferenceDate * 4)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.9), Dock.cyan.opacity(0.35), Dock.cyan.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 34))
                    .frame(width: 68, height: 68)
                    .scaleEffect(pulse)
                if let label { Tag(text: label).offset(y: 30) }
            }
        }
        .opacity(on ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// The tail of the rail, where older ones wait: a swirl of stardust with
/// how many are in it.
private struct Swirl: View {
    let label: String?
    let on: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !on)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80)),
                             with: .radialGradient(Gradient(colors: [Dock.cyan.opacity(0.5), Dock.cyan.opacity(0)]),
                                                   center: c, startRadius: 0, endRadius: 40))
                    for i in 0..<180 {
                        let seed = Double(i)
                        let a = seed * 2.39996 + t * (0.8 + (seed.truncatingRemainder(dividingBy: 7)) / 7)
                        let d = 6 + (seed * 37).truncatingRemainder(dividingBy: 34)
                        let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d * 0.55)
                        ctx.fill(Path(CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)),
                                 with: .color(Dock.cyan.opacity(0.35 + 0.5 * (seed * 13).truncatingRemainder(dividingBy: 1))))
                    }
                }
                .frame(width: 100, height: 70)
                if let label { Tag(text: label).offset(y: -40) }
            }
        }
        .opacity(on ? 1 : 0)
        .allowsHitTesting(false)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(Dock.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
            .fixedSize()
    }
}

/// The Milky Way behind the dock, drawn once for the screen's size, with a
/// trail of stardust along the rail and a few bright stars that twinkle.
private struct SpaceBackground: View {
    let size: CGSize
    let ring: [Slot]
    let head: CGPoint
    let tail: CGPoint
    let on: Bool
    let instant: Bool

    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            if let sky = Sky.image(size: size, ring: ring, head: head, tail: tail) {
                Image(decorative: sky, scale: 2).resizable()
            }
            Twinkle(size: size, on: on)
        }
        .frame(width: size.width, height: size.height)
        .opacity(shown)
        .allowsHitTesting(false)
        .onAppear { if on { show() } }
        .onChange(of: on) { _, now in now ? show() : hide() }
    }

    // A peek just appears and goes; only opening on purpose eases in.
    private func show() {
        if instant { set(0.95) } else { withAnimation(.easeOut(duration: 0.35)) { shown = 0.95 } }
    }
    private func hide() {
        if instant { set(0) } else { withAnimation(.easeIn(duration: 0.3).delay(0.35)) { shown = 0 } }
    }
    private func set(_ value: Double) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { shown = value }
    }
}

private struct Twinkle: View {
    let size: CGSize
    let on: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !on)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { ctx, _ in
                var r = Sky.Random(seed: 77)
                for _ in 0..<140 {
                    let x = r.next() * size.width, y = r.next() * size.height, ph = r.next() * 6.28
                    let a = 0.5 + 0.5 * sin(t * 2.5 + ph)
                    let s = 1 + r.next() * 1.4
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)), with: .color(.white.opacity(a)))
                }
            }
        }
    }
}

/// Paints the sky into an image, kept for as long as the screen and the
/// rail stay the same.
enum Sky {
    struct Random {
        var s: UInt64
        init(seed: UInt64) { s = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> CGFloat {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(s >> 33) / CGFloat(1 << 31)
        }
    }

    private static var cache: (key: String, image: CGImage)?

    @MainActor
    static func image(size: CGSize, ring: [Slot], head: CGPoint, tail: CGPoint) -> CGImage? {
        let key = "\(size.width)x\(size.height)-\(ring.count)-\(Layout.size.rawValue)"
        if let cache, cache.key == key { return cache.image }
        let w = Int(size.width * 2), h = Int(size.height * 2)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        // Flip so y grows downwards, like the view.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        var r = Random(seed: 11)
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
        func glow(_ c: CGPoint, _ radius: CGFloat, _ color: (CGFloat, CGFloat, CGFloat), _ a: CGFloat) {
            let g = CGGradient(colorsSpace: nil, colors: [rgb(color.0, color.1, color.2, a), rgb(color.0, color.1, color.2, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
        }

        // Deep space.
        let bg = CGGradient(colorsSpace: nil, colors: [rgb(0.012, 0.02, 0.06, 1), rgb(0.04, 0.063, 0.14, 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])

        // Stars everywhere.
        let area = size.width * size.height
        for _ in 0..<Int(area / 260) {
            let s = r.next() * 1.3 + 0.3
            ctx.setFillColor(rgb(1, 1, 1, 0.25 + r.next() * 0.6))
            ctx.fill(CGRect(x: r.next() * size.width, y: r.next() * size.height, width: s, height: s))
        }

        // The Milky Way: a dense band of warm stars across the screen.
        ctx.saveGState()
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: -0.42)
        ctx.setBlendMode(.plusLighter)
        glow(.zero, size.width * 0.38, (1, 0.9, 0.72), 0.2)
        glow(CGPoint(x: -size.width * 0.15, y: 10), size.width * 0.16, (1, 0.72, 0.54), 0.16)
        glow(CGPoint(x: size.width * 0.17, y: -8), size.width * 0.17, (0.72, 0.78, 1), 0.14)
        let spread = size.height * 0.08
        for _ in 0..<Int(area / 70) {
            let x = (r.next() - 0.5) * size.width * 1.6
            let y = (r.next() + r.next() + r.next() - 1.5) * spread
            ctx.setFillColor(rgb(1, 0.88 + r.next() * 0.12, 0.76 + r.next() * 0.24, 0.12 + r.next() * 0.45))
            ctx.fill(CGRect(x: x, y: y, width: 1.1, height: 1.1))
        }
        // Dark dust lanes through the middle of the band.
        ctx.setBlendMode(.normal)
        for i in 0..<6 {
            let x = (CGFloat(i) / 5 - 0.5) * size.width * 1.1
            let lane = CGGradient(colorsSpace: nil, colors: [rgb(0.01, 0.015, 0.04, 0.35), rgb(0.01, 0.015, 0.04, 0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(lane, startCenter: CGPoint(x: x, y: (r.next() - 0.5) * spread), startRadius: 0,
                                   endCenter: CGPoint(x: x, y: 0), endRadius: spread * 1.4, options: [])
        }
        ctx.restoreGState()

        // A couple of far galaxies.
        ctx.setBlendMode(.plusLighter)
        for (cx, cy, rad, col) in [(0.78, 0.22, 30.0, (0.75, 0.8, 1.0)), (0.32, 0.7, 22.0, (1.0, 0.78, 0.9))] as [(CGFloat, CGFloat, CGFloat, (CGFloat, CGFloat, CGFloat))] {
            ctx.saveGState()
            ctx.translateBy(x: size.width * cx, y: size.height * cy)
            ctx.rotate(by: 0.5)
            ctx.scaleBy(x: 1, y: 0.4)
            glow(.zero, rad, col, 0.55)
            glow(.zero, rad * 0.3, (1, 1, 1), 0.7)
            ctx.restoreGState()
        }

        // Stardust along the rail, from the head through every port to the tail.
        var path = [head] + ring.map(\.center) + [tail]
        if path.count < 2 { path = [head, tail] }
        let b = Dock.box
        for i in 0..<(path.count - 1) {
            let a = path[i], c = path[i + 1]
            let len = hypot(c.x - a.x, c.y - a.y)
            for _ in 0..<Int(len * 1.6) {
                let k = r.next()
                let jx = (r.next() - 0.5) * b.width * 0.5, jy = (r.next() - 0.5) * b.height * 0.5
                ctx.setFillColor(rgb(1, 0.88, 0.54, 0.15 + r.next() * 0.5))
                let s = 1 + r.next() * 0.8
                ctx.fill(CGRect(x: a.x + (c.x - a.x) * k + jx, y: a.y + (c.y - a.y) * k + jy, width: s, height: s))
            }
        }

        guard let image = ctx.makeImage() else { return nil }
        cache = (key, image)
        return image
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
