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
    static let cyan = Color(red: 0.37, green: 0.96, blue: 1)
    static let amber = Color(red: 1, green: 0.71, blue: 0.28)

    /// The box a card takes, whatever its proportions.
    static var box: CGSize { CGSize(width: Layout.cardWidth, height: Layout.photoMaxHeight + Frame.inset * 2) }

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

    /// The middle of the screen, away from every band: the pointer resting
    /// here counts as having left the dock.
    static func inner(of size: CGSize) -> CGRect {
        CGRect(x: sideBand, y: topBand, width: max(0, size.width - 2 * sideBand),
               height: max(0, size.height - 2 * topBand))
    }
}
