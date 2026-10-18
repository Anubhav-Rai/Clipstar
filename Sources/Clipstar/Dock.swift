import SwiftUI

/// The four edges of the screen a screenshot can dock on.
enum Side: Int, CaseIterable {
    case top, right, bottom, left

    var isHorizontal: Bool { self == .top || self == .bottom }

    /// Pointing out of the screen, past this edge, in view coordinates
    /// (y grows downwards).
    var outward: CGVector {
        switch self {
        case .top: CGVector(dx: 0, dy: -1)
        case .right: CGVector(dx: 1, dy: 0)
        case .bottom: CGVector(dx: 0, dy: 1)
        case .left: CGVector(dx: -1, dy: 0)
        }
    }
}

/// One docking port: where on the rail it sits and where its card rests.
struct Slot: Equatable {
    let index: Int
    let side: Side
    /// The port on the rail.
    let port: CGPoint
    /// The centre of the card docked there.
    let center: CGPoint

    /// Ships come in from beyond their own edge, a little slanted, so a
    /// fleet arriving at once seems to come from everywhere.
    var approach: CGVector {
        let o = side.outward
        let slant: CGFloat = index % 2 == 0 ? 0.45 : -0.45
        let d = CGVector(dx: o.dx - o.dy * slant, dy: o.dy + o.dx * slant)
        let len = hypot(d.dx, d.dy)
        return CGVector(dx: d.dx / len, dy: d.dy / len)
    }
}

/// Where the ports are. The rail runs round the screen a little inside the
/// edge; cards rest just inside it, upright so they stay readable.
enum Dock {
    static let rail: CGFloat = 12
    static let gap: CGFloat = 12
    /// How solid the space behind the dock is, from Background in the menu.
    static var skyOpacity: Double {
        get { (UserDefaults.standard.object(forKey: "skyOpacity") as? Double) ?? 0.8 }
        set { UserDefaults.standard.set(newValue, forKey: "skyOpacity") }
    }

    /// The accent: starlight gold.
    static let cyan = Color(red: 1, green: 0.88, blue: 0.54)
    static let amber = Color(red: 1, green: 0.71, blue: 0.28)

    /// The box a card takes, whatever its proportions.
    static var box: CGSize {
        let card = CGSize(width: Layout.cardWidth, height: Layout.photoMaxHeight + Frame.inset * 2)
        // A ship is a little bigger than a card, with the screenshot smaller inside it.
        return Skin.current == .card ? card : CGSize(width: card.width * 1.3, height: card.height * 1.35)
    }

    /// How deep the band along each edge is, rail and card included.
    static var topBand: CGFloat { rail + gap + box.height }
    static var sideBand: CGFloat { rail + gap + box.width }

    /// Every port, in the order they fill: round the sides in turn (top,
    /// right, bottom, left), and on each side from the middle outwards, so
    /// the dock fills evenly whatever the count.
    static func slots(in size: CGSize) -> [Slot] {
        guard size.width > 0, size.height > 0 else { return [] }
        let b = box
        func centreOut(_ n: Int) -> [Int] {
            let mid = Double(n - 1) / 2
            return (0..<n).sorted { abs(Double($0) - mid) < abs(Double($1) - mid) || (abs(Double($0) - mid) == abs(Double($1) - mid) && $0 < $1) }
        }
        // Along the top and bottom, between the side bands.
        let hFrom = sideBand, hTo = size.width - sideBand
        let hCount = max(0, Int((hTo - hFrom) / (b.width + 24)))
        // Down the sides, between the top and bottom bands.
        let vFrom = topBand, vTo = size.height - topBand
        let vCount = max(0, Int((vTo - vFrom) / (b.height + 18)))

        func along(_ side: Side, _ i: Int) -> (CGPoint, CGPoint) {
            switch side {
            case .top, .bottom:
                let step = (hTo - hFrom) / CGFloat(hCount)
                let x = hFrom + step * (CGFloat(i) + 0.5)
                return side == .top
                    ? (CGPoint(x: x, y: rail), CGPoint(x: x, y: rail + gap + b.height / 2))
                    : (CGPoint(x: x, y: size.height - rail), CGPoint(x: x, y: size.height - rail - gap - b.height / 2))
            case .left, .right:
                let step = (vTo - vFrom) / CGFloat(vCount)
                let y = vFrom + step * (CGFloat(i) + 0.5)
                return side == .left
                    ? (CGPoint(x: rail, y: y), CGPoint(x: rail + gap + b.width / 2, y: y))
                    : (CGPoint(x: size.width - rail, y: y), CGPoint(x: size.width - rail - gap - b.width / 2, y: y))
            }
        }

        var queues: [Side: [Int]] = [.top: centreOut(hCount), .bottom: centreOut(hCount),
                                     .left: centreOut(vCount), .right: centreOut(vCount)]
        var out: [Slot] = []
        while queues.values.contains(where: { !$0.isEmpty }) {
            for side in Side.allCases {
                guard var q = queues[side], !q.isEmpty else { continue }
                let i = q.removeFirst()
                queues[side] = q
                let (port, center) = along(side, i)
                out.append(Slot(index: out.count, side: side, port: port, center: center))
            }
        }
        return out
    }

    /// The rail the screenshots ride, newest first: from the top right,
    /// straight above where the bottom row ends, leftwards along the top,
    /// down the left side, then back along the bottom to the tail in the
    /// bottom right corner. Top and bottom rows match; the right side stays
    /// clear.
    static func ring(in size: CGSize) -> [Slot] {
        let b = box
        var out: [Slot] = []
        func add(_ side: Side, _ center: CGPoint, _ port: CGPoint) {
            out.append(Slot(index: out.count, side: side, port: port, center: center))
        }
        let topY = rail + gap + b.height / 2
        let leftX = rail + gap + b.width / 2
        let bottomY = size.height - rail - gap - b.height / 2
        let stepX = b.width + 24, stepY = b.height + 18
        // The columns the top and bottom rows share, left to right, spread
        // evenly from just right of the left column to the tail, so every
        // screen is filled the same way whatever its width.
        let from = leftX + b.width / 2 + 12 + b.width / 2, to = size.width - tailRoom - b.width / 2
        let columns = max(1, Int((to - from) / stepX) + 1)
        let xs: [CGFloat] = columns == 1 ? [from] : (0..<columns).map { from + (to - from) * CGFloat($0) / CGFloat(columns - 1) }
        for x in xs.reversed() {
            add(.top, CGPoint(x: x, y: topY), CGPoint(x: x, y: rail))
        }
        // Down the left, spread evenly between the top and bottom rows.
        let top = topY + b.height / 2 + 12 + b.height / 2, bottom = bottomY - b.height / 2 - 12 - b.height / 2
        let rows = bottom >= top ? Int((bottom - top) / stepY) + 1 : 0
        for i in 0..<rows {
            let y = rows == 1 ? (top + bottom) / 2 : top + (bottom - top) * CGFloat(i) / CGFloat(rows - 1)
            add(.left, CGPoint(x: leftX, y: y), CGPoint(x: rail, y: y))
        }
        for x in xs {
            add(.bottom, CGPoint(x: x, y: bottomY), CGPoint(x: x, y: size.height - rail))
        }
        return out
    }

    /// Room kept clear at the end of the bottom row for the tail.
    static let tailRoom: CGFloat = 150

    /// Where the newest come from, just right of the first port, top right: the head.
    static func head(in size: CGSize) -> CGPoint {
        let first = ring(in: size).first?.center ?? CGPoint(x: size.width - tailRoom, y: rail + gap + box.height / 2)
        return CGPoint(x: min(first.x + box.width * 0.75, size.width - 30), y: first.y)
    }

    /// Where the oldest go once past the last port: the tail.
    static func gate(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - tailRoom / 2 - 10, y: size.height - rail - gap - box.height / 2)
    }

    /// Where a card is drawn at a position on the ring, in ports. Between
    /// two ports it is on the way from one to the other; past either end it
    /// shrinks and spins into the gate.
    struct Placement {
        var center: CGPoint
        var slot: Slot
        var scale: CGFloat
        var opacity: Double
        var spin: Double
    }

    /// Position 0 is the newest port. Below 0 a card is drawn shrinking
    /// into the head; past the last port, into the tail.
    static func place(at p: CGFloat, ring: [Slot], head: CGPoint, tail: CGPoint) -> Placement? {
        guard let first = ring.first, let last = ring.last else { return nil }
        let n = CGFloat(ring.count)
        if p < 0 || p > n - 1 {
            let beyond = p < 0 ? -p : p - (n - 1)
            let k = 1 - min(1, beyond / 0.5)
            guard k > 0.02 else { return nil }
            let from = p < 0 ? first : last, to = p < 0 ? head : tail
            let c = CGPoint(x: to.x + (from.center.x - to.x) * k, y: to.y + (from.center.y - to.y) * k)
            return Placement(center: c, slot: from, scale: 0.25 + 0.75 * k, opacity: Double(k), spin: 0)
        }
        let i = Int(p.rounded(.down)), f = p - CGFloat(i)
        let a = ring[i], b = ring[min(i + 1, ring.count - 1)]
        let c = CGPoint(x: a.center.x + (b.center.x - a.center.x) * f, y: a.center.y + (b.center.y - a.center.y) * f)
        return Placement(center: c, slot: f < 0.5 ? a : b, scale: 1, opacity: 1, spin: 0)
    }

    /// The middle of the screen, away from every band: the pointer resting
    /// here counts as having left the dock.
    static func inner(of size: CGSize) -> CGRect {
        CGRect(x: sideBand, y: topBand, width: max(0, size.width - sideBand),
               height: max(0, size.height - 2 * topBand))
    }
}
