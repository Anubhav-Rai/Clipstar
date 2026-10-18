import SwiftUI

/// One screenshot in its port: a hologram card held by two clamps. Opening
/// the dock warps it in from past its own edge; closing it warps it away.
struct DockedView: View {
    let item: Pegged
    @ObservedObject var line: Line
    let slot: Slot
    /// 1 for the newest.
    let number: Int
    /// How much it is zoomed by an up and down swipe, and the point that
    /// stays put while it grows.
    let zoom: CGFloat
    let anchor: UnitPoint
    /// Where its port is on the screen, and the screen's size, for its flight.
    let port: CGPoint
    let screen: CGSize

    /// A sharp version for when it is zoomed; the docked one is small.
    @State private var full: NSImage?

    /// How far along its flight it is: 0 away, 1 docked.
    @State private var k: CGFloat = 0
    /// Going away: every arrival leaves the same quick way.
    @State private var leaving = false
    /// The clamps closed on the card.
    @State private var locked = false
    /// The shockwave of docking, 0 to 1. Invisible at 1.
    @State private var ring: CGFloat = 1
    @State private var hovering = false

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }

    /// Ships in a fleet arrive a moment apart, in the order the ports fill.
    private var stagger: Double { min(Double(slot.index) * 0.045, 0.6) }

    private var skin: Skin { Skin.current }

    /// The ship's window inside the box the card is given: the same for every
    /// ship of a skin, so they all match whatever their screenshots' shape.
    private var photoFrame: CGRect {
        let box = Dock.box, w = skin.window
        return CGRect(x: (box.width - w.width) / 2, y: (box.height - w.height) / 2, width: w.width, height: w.height)
    }

    var body: some View {
        ZStack {
            Hull(skin: skin, photo: photoFrame)
                .frame(width: Dock.box.width, height: Dock.box.height)
            card
            if skin == .card {
                clamps
                    .opacity(zoom > 1.05 ? 0 : 1)
            }
            Circle()
                .stroke(Dock.cyan, lineWidth: 3 * (1 - ring))
                .frame(width: 40, height: 40)
                .scaleEffect(0.6 + 5 * ring)
                .opacity(Double(1 - ring))
                .allowsHitTesting(false)
        }
        .frame(width: Dock.box.width, height: Dock.box.height)
        .scaleEffect(zoom, anchor: anchor)
        .modifier(Flight(k: k, arrival: leaving ? .warp : Arrival.current, port: port, slot: slot, size: screen,
                         skin: skin, photo: photoFrame, box: Dock.box))
        .opacity(item.falling || item.flying ? 0 : 1)
        .transaction { t in if item.falling { t.animation = nil } }
        .onAppear(perform: appear)
        .onChange(of: line.revealed) { _, on in
            if line.instant {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    k = on ? 1 : 0
                    locked = on
                }
            } else {
                on ? warpIn() : warpOut()
            }
        }
        .onChange(of: item.flying) { was, now in if was && !now { dock() } }
        .onChange(of: copied) { _, isCopied in if isCopied { flash() } }
        .onChange(of: zoom > 1.3) { _, big in if big && full == nil { loadFull() } }
    }

    private func loadFull() {
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            let image = makeThumbnail(url, maxPixels: 2600)
            DispatchQueue.main.async { full = image }
        }
    }

    // MARK: Motion

    private func appear() {
        if item.flying {
            // The launch flies it here; it shows itself once it lands.
            k = 1
        } else if line.revealed {
            // New, or brought round by the ring: already docked.
            k = 1
            locked = true
        }
    }

    private func warpIn() { warpIn(after: stagger) }

    /// Flies in the way Arrival says; the easing is in the flight itself.
    private func warpIn(after delay: Double) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            leaving = false
            k = 0
            locked = false
        }
        let arrival = Arrival.current
        withAnimation(.linear(duration: arrival.duration).delay(delay)) { k = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + arrival.duration * 0.92) {
            guard line.revealed else { return }
            dock()
        }
    }

    /// Clamps shut and a shockwave rings out.
    private func dock() {
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) { locked = true }
        flash()
    }

    private func flash() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { ring = 0 }
        withAnimation(.easeOut(duration: 0.6)) { ring = 1 }
    }

    /// Slips away past its edge, quickly, nearly together with the rest.
    private func warpOut() {
        withAnimation(.easeOut(duration: 0.08)) { locked = false }
        leaving = true
        withAnimation(.easeIn(duration: 0.22).delay(min(stagger * 0.1, 0.05))) { k = 0 }
    }

    // MARK: Parts

    /// Two brackets either side of the card, along the rail.
    private var clamps: some View {
        let size = DockedView.cardSize(for: item.thumb.size)
        let gap: CGFloat = locked ? 3 : 14
        return ZStack {
            ForEach([-1, 1], id: \.self) { s in
                Clamp(side: slot.side, flip: s == 1)
                    .stroke(Dock.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: slot.side.isHorizontal ? 7 : 22, height: slot.side.isHorizontal ? 22 : 7)
                    .shadow(color: Dock.cyan, radius: 3)
                    .offset(x: slot.side.isHorizontal ? CGFloat(s) * (size.width / 2 + gap) : 0,
                            y: slot.side.isHorizontal ? 0 : CGFloat(s) * (size.height / 2 + gap))
            }
        }
        .opacity(locked ? 1 : 0)
        .allowsHitTesting(false)
    }

    /// The photo fits inside the card area keeping its proportions.
    static func photoSize(for size: CGSize) -> CGSize {
        // Fits the window of the ship, or the card.
        let window = Skin.current.window
        let maxW = window.width - Frame.inset * 2, maxH = window.height - Frame.inset * 2
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The card around the photo: the photo plus the hologram frame.
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + Frame.inset * 2, height: p.height + Frame.inset * 2)
    }

    private var photoSize: CGSize { Self.photoSize(for: item.thumb.size) }

    /// Corner radii of the card and the screenshot in it, rounder on some ships.
    private var outer: CGFloat { skin == .card ? Frame.radius : skin.corner + Frame.inset }
    private var inner: CGFloat { max(0, outer - Frame.inset) }

    /// A picture, or copied text: asterisks until unlocked.
    @ViewBuilder private var face: some View {
        if item.isText {
            TextFace(url: item.url, unlocked: line.textUnlocked)
        } else {
            Image(nsImage: full ?? item.thumb)
                .resizable()
                .interpolation(.high)
        }
    }

    private var card: some View {
        face
            .frame(width: photoSize.width, height: photoSize.height)
            .overlay(Scanlines().opacity(hovering ? 0.03 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: inner, style: .continuous))
            .overlay {
                // A recording says so with a play button over its first frame.
                if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Dock.cyan)
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.6), in: Circle())
                        .overlay(Circle().stroke(Dock.cyan.opacity(0.7), lineWidth: 1))
                        .allowsHitTesting(false)
                }
            }
            .padding(Frame.inset)
            .background(Color.black.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: outer, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: outer, style: .continuous)
                    .stroke(Dock.cyan.opacity(hovering ? 1 : 0.7), lineWidth: hovering ? 1.6 : 1.1)
            )
            .shadow(color: Dock.cyan.opacity(hovering || number == 1 ? 0.8 : 0.4), radius: hovering || number == 1 ? 14 : 6)
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.05 : 1))
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top. A
                // cross sends a file in Clipstar's folder to the Trash; for a
                // file anywhere else it only takes it out of the dock.
                Image(systemName: line.isInInbox(item.id) ? "xmark" : "eye.slash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Dock.cyan)
                    .frame(width: 20, height: 20)
                    .background(Color.black.opacity(0.7), in: Circle())
                    .overlay(Circle().stroke(Dock.cyan.opacity(0.8), lineWidth: 1))
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                // How new it is: 1 is the newest.
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(number == 1 ? Color.black : Color.white)
                    .frame(minWidth: 19, minHeight: 19)
                    .padding(.horizontal, number > 9 ? 3 : 0)
                    .background(number == 1 ? Dock.cyan : Color.black.opacity(0.85), in: Capsule())
                    .overlay(Capsule().stroke(Dock.cyan.opacity(0.8), lineWidth: 1))
                    .offset(x: 7, y: -7)
                    .allowsHitTesting(false)
            }
            .overlay(GrabArea(item: item, line: line))
            .overlay(alignment: slot.side == .bottom ? .top : .bottom) {
                if copied {
                    Label(L("Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Dock.cyan)
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.7), in: Capsule())
                        .overlay(Capsule().stroke(Dock.cyan.opacity(0.7), lineWidth: 1))
                        .offset(y: slot.side == .bottom ? -16 : 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { hovering = $0 }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling || k < 0.99 ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }
}

/// Faint horizontal lines over the photo, the way a hologram flickers.
private struct Scanlines: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var y: CGFloat = 0
            while y < size.height {
                p.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            ctx.fill(p, with: .color(Dock.cyan))
        }
        .allowsHitTesting(false)
    }
}

/// A docking clamp: a bracket opening towards the card.
private struct Clamp: Shape {
    let side: Side
    let flip: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        if side.isHorizontal {
            // A [ or ] shape, opening towards the card.
            let outer = flip ? r.maxX : r.minX, inner = flip ? r.minX : r.maxX
            p.move(to: CGPoint(x: inner, y: r.minY)); p.addLine(to: CGPoint(x: outer, y: r.minY))
            p.addLine(to: CGPoint(x: outer, y: r.maxY)); p.addLine(to: CGPoint(x: inner, y: r.maxY))
        } else {
            let outer = flip ? r.maxY : r.minY, inner = flip ? r.minY : r.maxY
            p.move(to: CGPoint(x: r.minX, y: inner)); p.addLine(to: CGPoint(x: r.minX, y: outer))
            p.addLine(to: CGPoint(x: r.maxX, y: outer)); p.addLine(to: CGPoint(x: r.maxX, y: inner))
        }
        return p
    }
}

enum Frame {
    static let radius: CGFloat = 10
    static let inset: CGFloat = 4
}

/// Copied text on a card. Locked, every character shows as an asterisk,
/// keeping the shape of the lines. One button in the dock shows them all.
private struct TextFace: View {
    let url: URL
    let unlocked: Bool

    @State private var text = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.06, green: 0.07, blue: 0.12)
            VStack(alignment: .leading, spacing: 4) {
                Text("TEXT · \(text.count)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(Dock.cyan.opacity(0.7))
                Text(unlocked ? text : masked)
                    .font(.system(size: unlocked ? 9 : 11, weight: unlocked ? .regular : .bold, design: .monospaced))
                    .foregroundStyle(unlocked ? Color.white : Dock.cyan)
                    .lineLimit(unlocked ? 8 : 3)
                    .truncationMode(.tail)
            }
            .padding(8)
        }
        .onAppear { text = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    /// Each character an asterisk, up to a few lines' worth.
    private var masked: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).prefix(3)
            .map { String(repeating: "*", count: min(max($0.count, 3), 14)) }
            .joined(separator: "\n")
    }
}
