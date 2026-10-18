import SwiftUI

/// What each screenshot looks like in the dock, from Skin in the menu: a
/// plain card, or a little ship built round it. The screenshot stays the
/// part you click and drag; the hull is drawn behind it.
///
/// Hulls are drawn in design units round a screenshot 50 wide and 32 tall,
/// centred on (0, 0), stretched to the screenshot's real size.
enum Skin: String, CaseIterable {
    case card, starfighter, shuttle, freighter, saucer, rocket, satellite, xwing, capsule, module, brass, stealth

    static var current: Skin {
        get { Skin(rawValue: UserDefaults.standard.string(forKey: "skin") ?? "") ?? .card }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "skin") }
    }

    var title: String {
        switch self {
        case .card: L("Card")
        case .starfighter: L("Starfighter")
        case .shuttle: L("Shuttle")
        case .freighter: L("Freighter")
        case .saucer: L("Saucer")
        case .rocket: L("Rocket")
        case .satellite: L("Satellite")
        case .xwing: L("X-Wing")
        case .capsule: L("Capsule")
        case .module: L("Station Module")
        case .brass: L("Brass Rocket")
        case .stealth: L("Stealth")
        }
    }

    /// How far the hull reaches past the screenshot on each side, in
    /// design units: (sideways, up and down).
    var reach: CGSize {
        switch self {
        case .card: CGSize(width: 0, height: 0)
        case .starfighter: CGSize(width: 20, height: 14)
        case .shuttle: CGSize(width: 18, height: 18)
        case .freighter: CGSize(width: 14, height: 10)
        case .saucer: CGSize(width: 22, height: 11)
        case .rocket: CGSize(width: 10, height: 22)
        case .satellite: CGSize(width: 36, height: 13)
        case .xwing: CGSize(width: 24, height: 16)
        case .capsule: CGSize(width: 9, height: 10)
        case .module: CGSize(width: 13, height: 6)
        case .brass: CGSize(width: 18, height: 18)
        case .stealth: CGSize(width: 26, height: 16)
        }
    }

    /// The share of the ship's width and height the screenshot takes.
    var screenShare: CGSize {
        CGSize(width: 50 / (50 + 2 * reach.width), height: 32 / (32 + 2 * reach.height))
    }

    /// The window the screenshot shows in: the same on every ship of a
    /// skin, whatever the screenshot's shape, about 85% of a card's
    /// picture. Ships with big wings grow, up to a limit, rather than
    /// shrinking the screenshot.
    var window: CGSize {
        let card = CGSize(width: Layout.cardWidth, height: Layout.photoMaxHeight + Frame.inset * 2)
        guard self != .card else { return card }
        let most = CGSize(width: card.width * 1.55, height: card.height * 1.6)
        return CGSize(width: min(card.width * 0.85, most.width * screenShare.width),
                      height: min(card.height * 0.85, most.height * screenShare.height))
    }

    /// The box a ship takes on the rail: its window and the hull round it.
    var box: CGSize {
        guard self != .card else { return window }
        return CGSize(width: (window.width / screenShare.width).rounded(), height: (window.height / screenShare.height).rounded())
    }

    /// Where the engines are, in design units, for the thrusters.
    var engines: [CGPoint] {
        switch self {
        case .card: [CGPoint(x: 0, y: 19)]
        case .starfighter: [CGPoint(x: -17, y: 23), CGPoint(x: 17, y: 23)]
        case .shuttle, .rocket, .capsule, .brass: [CGPoint(x: 0, y: 26)]
        case .freighter: [CGPoint(x: -23, y: 24), CGPoint(x: 0, y: 24), CGPoint(x: 23, y: 24)]
        case .saucer: [CGPoint(x: 0, y: 24)]
        case .satellite: [CGPoint(x: -19, y: 19), CGPoint(x: 19, y: 19)]
        case .xwing: [CGPoint(x: -45, y: 18), CGPoint(x: 45, y: 18)]
        case .module: [CGPoint(x: -34, y: 18), CGPoint(x: 34, y: 18)]
        case .stealth: [CGPoint(x: -14, y: 24), CGPoint(x: 14, y: 24)]
        }
    }

    /// How round the screenshot's corners are, in points, on this ship.
    var corner: CGFloat {
        switch self {
        case .card: Frame.radius - Frame.inset
        case .starfighter, .rocket: 10
        case .saucer: 18
        case .brass: 40
        case .xwing: 8
        default: 4
        }
    }
}

/// The hull behind the screenshot. `photo` is the ship's window inside this
/// view: the same for every ship of a skin.
struct Hull: View {
    let skin: Skin
    let photo: CGRect

    var body: some View {
        Canvas { ctx, _ in
            guard skin != .card else { return }
            var c = ctx
            c.translateBy(x: photo.midX, y: photo.midY)
            c.scaleBy(x: photo.width / 50, y: photo.height / 32)
            Hull.draw(skin, in: &c)
            // The screen in the window, behind a screenshot that does not fill it.
            ctx.fill(Path(roundedRect: photo, cornerRadius: skin.corner + Frame.inset),
                     with: .color(Color(red: 0.03, green: 0.04, blue: 0.08)))
        }
        .allowsHitTesting(false)
    }

    private static let gold = Color(red: 1, green: 0.88, blue: 0.54)
    private static let cyan = Color(red: 0.37, green: 0.96, blue: 1)

    private static func metal(_ a: Color = Color(red: 0.79, green: 0.82, blue: 0.89),
                              _ b: Color = Color(red: 0.36, green: 0.4, blue: 0.47),
                              from: CGPoint, to: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(stops: [.init(color: a, location: 0), .init(color: Color(white: 0.94), location: 0.5),
                                         .init(color: b, location: 1)]), startPoint: from, endPoint: to)
    }

    private static func poly(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { p in
            p.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for q in points.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
            p.closeSubpath()
        }
    }

    private static let dark = Color(red: 0.13, green: 0.15, blue: 0.2)
    private static let red = Color(red: 0.91, green: 0.28, blue: 0.25)

    // The screenshot sits in the box from (-25, -16) to (25, 16).
    private static func draw(_ skin: Skin, in c: inout GraphicsContext) {
        switch skin {
        case .card:
            break
        case .starfighter:
            c.fill(poly([(0, -30), (45, 22), (23, 18), (-23, 18), (-45, 22)]), with: metal(from: CGPoint(x: -45, y: 0), to: CGPoint(x: 45, y: 0)))
            c.fill(Path(CGRect(x: -21, y: 16, width: 8, height: 6)), with: .color(dark))
            c.fill(Path(CGRect(x: 13, y: 16, width: 8, height: 6)), with: .color(dark))
            c.fill(Path(CGRect(x: -44, y: 19, width: 3, height: 3)), with: .color(Color(red: 1, green: 0.37, blue: 0.34)))
            c.fill(Path(CGRect(x: 41, y: 19, width: 3, height: 3)), with: .color(Color(red: 0.16, green: 0.78, blue: 0.25)))
        case .shuttle:
            var body = Path()
            body.move(to: CGPoint(x: 0, y: -34))
            body.addQuadCurve(to: CGPoint(x: 29, y: 24), control: CGPoint(x: 31, y: -20))
            body.addLine(to: CGPoint(x: -29, y: 24))
            body.addQuadCurve(to: CGPoint(x: 0, y: -34), control: CGPoint(x: -31, y: -20))
            c.fill(body, with: .color(Color(white: 0.92)))
            c.fill(poly([(-29, 12), (-43, 26), (-23, 24)]), with: .color(dark))
            c.fill(poly([(29, 12), (43, 26), (23, 24)]), with: .color(dark))
            c.fill(poly([(-9, -31), (9, -31), (6, -26), (-6, -26)]), with: .color(dark))
            c.fill(Path(CGRect(x: -8, y: 24, width: 16, height: 4)), with: .color(Color(white: 0.6)))
        case .freighter:
            c.fill(Path(CGRect(x: -33, y: -26, width: 66, height: 50)),
                   with: metal(Color(white: 0.56), Color(white: 0.24), from: CGPoint(x: 0, y: -26), to: CGPoint(x: 0, y: 24)))
            for k in 0..<6 {
                c.fill(Path(CGRect(x: -33 + CGFloat(k) * 11, y: -26, width: 5.5, height: 3)), with: .color(Color(red: 1, green: 0.71, blue: 0.28)))
            }
            c.fill(Path(CGRect(x: -39, y: -6, width: 6, height: 14)), with: .color(dark))
            c.fill(Path(CGRect(x: 33, y: -6, width: 6, height: 14)), with: .color(dark))
        case .saucer:
            c.fill(Path(ellipseIn: CGRect(x: -47, y: 3, width: 94, height: 22)),
                   with: metal(from: CGPoint(x: -47, y: 0), to: CGPoint(x: 47, y: 0)))
            for k in 0..<7 {
                let a = Double(k) / 7 * .pi
                let x = cos(a) * 39
                c.fill(Path(ellipseIn: CGRect(x: x - 2, y: 16, width: 4, height: 4)), with: .color(k % 2 == 0 ? gold : cyan))
            }
            c.stroke(Path(ellipseIn: CGRect(x: -27, y: -21, width: 54, height: 50)).trimmedPath(from: 0.5, to: 1),
                     with: .color(Color(red: 0.78, green: 0.92, blue: 1).opacity(0.8)), lineWidth: 1.4)
        case .rocket:
            var body = Path()
            body.move(to: CGPoint(x: 0, y: -38))
            body.addQuadCurve(to: CGPoint(x: 23, y: 24), control: CGPoint(x: 27, y: -22))
            body.addLine(to: CGPoint(x: -23, y: 24))
            body.addQuadCurve(to: CGPoint(x: 0, y: -38), control: CGPoint(x: -27, y: -22))
            c.fill(body, with: .color(Color(white: 0.95)))
            var nose = Path()
            nose.move(to: CGPoint(x: 0, y: -38))
            nose.addQuadCurve(to: CGPoint(x: 14, y: -26), control: CGPoint(x: 10, y: -32))
            nose.addLine(to: CGPoint(x: -14, y: -26))
            nose.addQuadCurve(to: CGPoint(x: 0, y: -38), control: CGPoint(x: -10, y: -32))
            c.fill(nose, with: .color(red))
            c.fill(poly([(-23, 10), (-35, 28), (-19, 24)]), with: .color(red))
            c.fill(poly([(23, 10), (35, 28), (19, 24)]), with: .color(red))
        case .satellite:
            for s: CGFloat in [-1, 1] {
                let x0: CGFloat = s < 0 ? -61 : 31
                c.fill(Path(CGRect(x: x0, y: -9, width: 30, height: 18)), with: .color(Color(red: 0.11, green: 0.23, blue: 0.54)))
                for k in 1..<5 {
                    var line = Path()
                    line.move(to: CGPoint(x: x0 + CGFloat(k) * 6, y: -9))
                    line.addLine(to: CGPoint(x: x0 + CGFloat(k) * 6, y: 9))
                    c.stroke(line, with: .color(Color(red: 0.5, green: 0.64, blue: 1)), lineWidth: 0.6)
                }
                var arm = Path()
                arm.move(to: CGPoint(x: s * 25, y: 0))
                arm.addLine(to: CGPoint(x: s * 31, y: 0))
                c.stroke(arm, with: .color(Color(white: 0.7)), lineWidth: 1.5)
            }
            c.fill(Path(CGRect(x: -27, y: -18, width: 54, height: 36)), with: .color(Color(red: 0.79, green: 0.65, blue: 0.29)))
            var mast = Path()
            mast.move(to: CGPoint(x: 0, y: -18))
            mast.addLine(to: CGPoint(x: 0, y: -28))
            c.stroke(mast, with: .color(Color(white: 0.87)), lineWidth: 1)
            c.fill(Path(ellipseIn: CGRect(x: -2.5, y: -31.5, width: 5, height: 5)), with: .color(Color(white: 0.87)))
        case .xwing:
            for (sx, sy) in [(-1.0, -1.0), (1, -1), (-1, 1), (1, 1)] as [(CGFloat, CGFloat)] {
                c.fill(poly([(sx * 15, sy * 3), (sx * 49, sy * 16), (sx * 49, sy * 10), (sx * 15, sy * -3)]), with: .color(Color(white: 0.85)))
                c.fill(Path(CGRect(x: sx * 37 - 4, y: sy * 12 - 1.5, width: 8, height: 3)), with: .color(red))
            }
            c.fill(Path(roundedRect: CGRect(x: -25, y: -22, width: 50, height: 44), cornerRadius: 8),
                   with: metal(from: CGPoint(x: 0, y: -22), to: CGPoint(x: 0, y: 22)))
        case .capsule:
            c.fill(poly([(-14, -26), (14, -26), (33, 20), (-33, 20)]),
                   with: metal(Color(white: 0.5), Color(white: 0.24), from: CGPoint(x: -33, y: 0), to: CGPoint(x: 33, y: 0)))
            c.fill(Path(ellipseIn: CGRect(x: -34, y: 16, width: 68, height: 10)), with: .color(Color(red: 0.29, green: 0.17, blue: 0.1)))
        case .module:
            c.fill(Path(roundedRect: CGRect(x: -31, y: -20, width: 62, height: 40), cornerRadius: 6),
                   with: metal(Color(white: 0.69), Color(white: 0.3), from: CGPoint(x: 0, y: -20), to: CGPoint(x: 0, y: 20)))
            for s: CGFloat in [-1, 1] {
                c.stroke(Path(ellipseIn: CGRect(x: s * 34 - 4, y: -18, width: 8, height: 36)), with: .color(gold), lineWidth: 2.5)
            }
            for k in 0..<4 {
                c.fill(Path(CGRect(x: -21 + CGFloat(k) * 13, y: -19, width: 5, height: 2)), with: .color(cyan))
            }
        case .brass:
            let brass = metal(Color(red: 0.85, green: 0.66, blue: 0.29), Color(red: 0.48, green: 0.33, blue: 0.09),
                              from: CGPoint(x: -35, y: 0), to: CGPoint(x: 35, y: 0))
            c.fill(poly([(-29, 14), (-43, 34), (-19, 24)]), with: .color(Color(red: 0.48, green: 0.33, blue: 0.09)))
            c.fill(poly([(29, 14), (43, 34), (19, 24)]), with: .color(Color(red: 0.48, green: 0.33, blue: 0.09)))
            c.fill(Path(ellipseIn: CGRect(x: -35, y: -28, width: 70, height: 56)), with: brass)
            for k in 0..<10 {
                let a = Double(k) / 10 * 2 * .pi
                c.fill(Path(ellipseIn: CGRect(x: cos(a) * 28 - 1.2, y: sin(a) * 22 - 1.2, width: 2.4, height: 2.4)),
                       with: .color(Color(red: 0.96, green: 0.83, blue: 0.54)))
            }
        case .stealth:
            let hull = poly([(0, -32), (51, 24), (-51, 24)])
            c.fill(hull, with: .color(Color(red: 0.08, green: 0.1, blue: 0.13)))
            c.stroke(hull, with: .color(cyan.opacity(0.7)), lineWidth: 1)
        }
    }
}
