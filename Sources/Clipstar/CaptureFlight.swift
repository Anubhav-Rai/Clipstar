import AppKit
import QuartzCore

/// Reads where on screen a screenshot was taken. macOS stores the captured
/// area on the file, in global points with the origin at the top left of
/// the main display. Returned in AppKit screen coordinates.
func captureRect(of url: URL) -> CGRect? {
    let name = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"
    let data: Data? = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return nil }
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
        return read == size ? buffer : nil
    }
    guard let data,
          let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [NSNumber],
          values.count == 4, let main = NSScreen.screens.first else { return nil }
    let x = CGFloat(truncating: values[0]), y = CGFloat(truncating: values[1])
    let w = CGFloat(truncating: values[2]), h = CGFloat(truncating: values[3])
    guard w > 2, h > 2 else { return nil }
    return CGRect(x: x, y: main.frame.maxY - y - h, width: w, height: h)
}

/// A new capture launching into the dock. A laser scans the captured area,
/// then it lifts off as a hologram card, swings round toward its port with
/// an exhaust trail behind it, and brakes hard at the end. Landing hands
/// over to the docked card, which closes its clamps.
@MainActor
final class CaptureFlight {
    static let scan: CFTimeInterval = 0.32
    static let flight: CFTimeInterval = 0.8

    private static let cyan = NSColor(red: 1, green: 0.88, blue: 0.54, alpha: 1)

    private let window: NSWindow
    private let container = CALayer()
    private let photo = CALayer()
    private let border = CALayer()
    private let scanArea = CALayer()
    private let scanLine = CALayer()
    private let trailGlow = CAShapeLayer()
    private let trailCore = CAShapeLayer()

    private let from: CGRect
    private let to: CGRect
    /// Which way it banks on the way.
    private let bank: CGFloat
    private var falling = false
    private var toward = CGVector(dx: 0, dy: -1)
    private var duration: CFTimeInterval = CaptureFlight.scan + CaptureFlight.flight
    private var start: CFTimeInterval = 0
    private var timer: Timer?
    private var completion: () -> Void = {}

    private static var current: [CaptureFlight] = []

    /// Captures launching right now. Each one holds a large image, so in a
    /// burst of captures only a few fly and the rest warp in.
    static var flightsInProgress: Int { current.filter { !$0.falling }.count }

    /// - Parameters:
    ///   - from: the captured area, in screen coordinates.
    ///   - to: the card's frame at its port, in screen coordinates.
    static func fly(image: CGImage, from: CGRect, to: CGRect, on screen: NSScreen,
                    completion: @escaping () -> Void) {
        let flight = CaptureFlight(image: image, from: from, to: to, screen: screen)
        current.append(flight)
        flight.completion = { [weak flight] in
            completion()
            current.removeAll { $0 === flight }
        }
        flight.run()
    }

    /// A discarded card jettisoned out past its edge, spinning and fading.
    static func fall(image: CGImage, card: CGRect, toward: CGVector, on screen: NSScreen) {
        let flight = CaptureFlight(image: image, from: card, to: card, screen: screen)
        flight.falling = true
        flight.toward = toward
        flight.duration = 0.5
        current.append(flight)
        flight.completion = { [weak flight] in current.removeAll { $0 === flight } }
        flight.run()
    }

    private init(image: CGImage, from: CGRect, to: CGRect, screen: NSScreen) {
        self.from = from
        self.to = to
        bank = Bool.random() ? 1 : -1
        window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        window.contentView = host
        let scale = screen.backingScaleFactor
        let cyan = Self.cyan.cgColor

        for trail in [trailGlow, trailCore] {
            trail.fillColor = nil
            trail.lineCap = .round
            trail.lineJoin = .round
        }
        trailGlow.strokeColor = cyan
        trailGlow.lineWidth = 16
        trailGlow.opacity = 0.45
        trailGlow.shadowColor = cyan
        trailGlow.shadowRadius = 10
        trailGlow.shadowOpacity = 1
        trailGlow.shadowOffset = .zero
        trailCore.strokeColor = NSColor.white.cgColor
        trailCore.lineWidth = 4

        scanArea.backgroundColor = Self.cyan.withAlphaComponent(0.14).cgColor
        scanArea.borderColor = cyan
        scanArea.borderWidth = 1
        scanLine.backgroundColor = NSColor.white.cgColor
        scanLine.shadowColor = cyan
        scanLine.shadowRadius = 6
        scanLine.shadowOpacity = 1
        scanLine.shadowOffset = .zero

        container.shadowColor = cyan
        container.shadowOpacity = 0.7
        container.shadowRadius = 10
        container.shadowOffset = .zero

        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        border.borderColor = cyan
        border.borderWidth = 1.4
        border.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor

        for layer in [container, photo, border, scanArea, scanLine, trailGlow, trailCore] as [CALayer] {
            layer.contentsScale = scale
        }
        container.addSublayer(border)
        container.addSublayer(photo)
        host.layer?.addSublayer(trailGlow)
        host.layer?.addSublayer(trailCore)
        host.layer?.addSublayer(container)
        host.layer?.addSublayer(scanArea)
        host.layer?.addSublayer(scanLine)
    }

    private func run() {
        update(0)
        window.orderFrontRegardless()
        start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - start
        update(elapsed)
        guard elapsed >= duration else { return }
        timer?.invalidate()
        timer = nil
        completion()
        if falling {
            window.orderOut(nil)
            return
        }
        // The docked card fades in underneath; this one fades out over it.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [window] in
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func update(_ elapsed: CFTimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if falling {
            updateFall(min(1, elapsed / duration))
        } else if elapsed < Self.scan {
            updateScan(elapsed / Self.scan)
        } else {
            scanArea.opacity = 0
            scanLine.opacity = 0
            updateFlight(min(1, (elapsed - Self.scan) / Self.flight))
        }
        CATransaction.commit()
    }

    private var origin: CGPoint { window.frame.origin }

    /// A laser sweeps down the captured area, leaving it tinted.
    private func updateScan(_ k: Double) {
        let r = from.offsetBy(dx: -origin.x, dy: -origin.y)
        let y = r.maxY - r.height * CGFloat(k)
        scanArea.frame = CGRect(x: r.minX, y: y, width: r.width, height: r.maxY - y)
        scanArea.opacity = 1
        scanLine.frame = CGRect(x: r.minX - 6, y: y - 1, width: r.width + 12, height: 2)
        scanLine.opacity = 1
        // The card waits, full size, under the scan.
        place(center: CGPoint(x: r.midX, y: r.midY), size: r.size, angle: 0, opacity: k > 0.9 ? 1 : 0)
        trailGlow.path = nil
        trailCore.path = nil
    }

    /// Slow off the mark, fast in the middle, a hard stop at the port.
    private static func thrust(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// Where the card is at k along its flight: a curve that swings out to
    /// one side first, like a ship turning toward its bay.
    private func point(_ k: Double) -> CGPoint {
        let a = CGPoint(x: from.midX - origin.x, y: from.midY - origin.y)
        let b = CGPoint(x: to.midX - origin.x, y: to.midY - origin.y)
        let c = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.45 * bank,
                        y: (a.y + b.y) / 2 - (b.x - a.x) * 0.45 * bank)
        let e = CGFloat(Self.thrust(k))
        let u = 1 - e
        return CGPoint(x: u * u * a.x + 2 * u * e * c.x + e * e * b.x,
                       y: u * u * a.y + 2 * u * e * c.y + e * e * b.y)
    }

    private func updateFlight(_ k: Double) {
        let p = point(k)
        // Shrinks to the card's size early, so most of the trip is the card.
        let s = CGFloat(min(1, k * 1.6))
        let eased = s * s * (3 - 2 * s)
        let size = CGSize(width: from.width + (to.width - from.width) * eased,
                          height: from.height + (to.height - from.height) * eased)
        let angle = sin(.pi * k) * 14 * bank
        place(center: p, size: size, angle: angle, opacity: 1)

        // Exhaust along the path just flown, fading out as it brakes.
        let path = CGMutablePath()
        path.move(to: p)
        for j in 1...18 {
            let pk = k - Double(j) * 0.02
            if pk < 0 { break }
            path.addLine(to: point(pk))
        }
        let fade = Float(k < 0.85 ? 1 : (1 - k) / 0.15)
        trailGlow.path = path
        trailCore.path = path
        trailGlow.opacity = 0.45 * fade
        trailCore.opacity = 0.9 * fade
    }

    private func place(center: CGPoint, size: CGSize, angle: CGFloat, opacity: Float) {
        container.bounds = CGRect(origin: .zero, size: size)
        container.position = center
        container.setAffineTransform(CGAffineTransform(rotationAngle: angle * .pi / 180))
        container.opacity = opacity
        let radius = min(10, min(size.width, size.height) / 8)
        container.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        border.frame = container.bounds
        border.cornerRadius = radius
        photo.frame = container.bounds.insetBy(dx: 4, dy: 4)
        photo.cornerRadius = max(0, radius - 4)
    }

    private func updateFall(_ raw: Double) {
        let e = CGFloat(raw * raw)
        let c = CGPoint(x: to.midX - origin.x + toward.dx * 420 * e, y: to.midY - origin.y + toward.dy * 420 * e)
        place(center: c, size: CGSize(width: to.width * (1 - 0.4 * e), height: to.height * (1 - 0.4 * e)),
              angle: 220 * e * bank, opacity: Float(1 - e))
        trailGlow.path = nil
        trailCore.path = nil
        scanArea.opacity = 0
        scanLine.opacity = 0
    }
}
