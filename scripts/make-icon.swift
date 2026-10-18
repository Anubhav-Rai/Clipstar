// Draws the Clipstar app icon: a screenshot docked as a glowing hologram card,
// held by two clamps, inside the corner brackets of a HUD, with warp
// streaks behind it, over deep space.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let cyan = color(95, 244, 255)

func glow(_ c: NSColor, blur: CGFloat) {
    let s = NSShadow()
    s.shadowColor = c
    s.shadowBlurRadius = blur
    s.shadowOffset = .zero
    s.set()
}

// Body, following the macOS icon grid: 824pt square, 100pt margin.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

ctx.saveGState()
let drop = NSShadow()
drop.shadowColor = color(0, 0, 0, 0.35)
drop.shadowBlurRadius = 26
drop.shadowOffset = NSSize(width: 0, height: -12)
drop.set()
color(16, 24, 52).setFill()
shape.fill()
ctx.restoreGState()

ctx.saveGState()
shape.addClip()
NSGradient(colors: [color(40, 62, 128), color(20, 30, 70), color(8, 12, 32)])!
    .draw(in: shape, relativeCenterPosition: NSPoint(x: -0.3, y: 0.35))

// Stars.
var seed: UInt64 = 7
func rand() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(1 << 31)
}
for _ in 0..<70 {
    let r = 1.5 + rand() * 2.5
    color(255, 255, 255, 0.25 + rand() * 0.5).setFill()
    NSBezierPath(ovalIn: NSRect(x: 100 + rand() * 824, y: 100 + rand() * 824, width: r, height: r)).fill()
}

// Warp streaks fanning out behind the card, from the upper left.
let card = NSRect(x: 352, y: 392, width: 360, height: 240)
for i in 0..<9 {
    let t = CGFloat(i) / 8
    let start = NSPoint(x: card.minX + 30, y: card.minY + 40 + t * 160)
    let end = NSPoint(x: start.x - 260 - rand() * 120, y: start.y + 150 + t * 40)
    let p = NSBezierPath()
    p.move(to: start)
    p.line(to: end)
    p.lineWidth = i % 3 == 0 ? 7 : 3.5
    p.lineCapStyle = .round
    ctx.saveGState()
    glow(cyan, blur: 14)
    cyan.withAlphaComponent(0.25 + 0.35 * (1 - abs(t - 0.5))).setStroke()
    p.stroke()
    ctx.restoreGState()
}

// HUD corner brackets.
let hud = body.insetBy(dx: 120, dy: 120)
ctx.saveGState()
glow(cyan, blur: 18)
cyan.setStroke()
for (x, y, sx, sy) in [(hud.minX, hud.minY, 1.0, 1.0), (hud.maxX, hud.minY, -1.0, 1.0),
                       (hud.minX, hud.maxY, 1.0, -1.0), (hud.maxX, hud.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y + sy * 110))
    p.line(to: NSPoint(x: x, y: y))
    p.line(to: NSPoint(x: x + sx * 110, y: y))
    p.lineWidth = 22
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.stroke()
}
ctx.restoreGState()

// The docked card: a hologram frame round a little window.
let frame = NSBezierPath(roundedRect: card, xRadius: 28, yRadius: 28)
ctx.saveGState()
glow(cyan, blur: 40)
color(6, 14, 34, 0.9).setFill()
frame.fill()
ctx.restoreGState()

let inner = card.insetBy(dx: 16, dy: 16)
let window = NSBezierPath(roundedRect: inner, xRadius: 14, yRadius: 14)
ctx.saveGState()
window.addClip()
NSGradient(colors: [color(161, 196, 253), color(194, 233, 251)])!.draw(in: inner, angle: -60)
color(255, 255, 255, 0.6).setFill()
NSRect(x: inner.minX, y: inner.maxY - 40, width: inner.width, height: 40).fill()
for (i, c) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
    c.setFill()
    NSBezierPath(ovalIn: NSRect(x: inner.minX + 20 + CGFloat(i) * 28, y: inner.maxY - 29, width: 17, height: 17)).fill()
}
color(255, 255, 255, 0.8).setFill()
for (i, w) in [0.62, 0.78, 0.45].enumerated() {
    NSBezierPath(roundedRect: NSRect(x: inner.minX + 26, y: inner.maxY - 82 - CGFloat(i) * 34, width: inner.width * w, height: 13),
                 xRadius: 6.5, yRadius: 6.5).fill()
}
// Scanlines.
color(95, 244, 255, 0.16).setFill()
var y = inner.minY
while y < inner.maxY {
    NSRect(x: inner.minX, y: y, width: inner.width, height: 3).fill()
    y += 9
}
ctx.restoreGState()

ctx.saveGState()
glow(cyan, blur: 12)
cyan.setStroke()
frame.lineWidth = 7
frame.stroke()
// Clamps either side.
for s in [-1.0, 1.0] as [CGFloat] {
    let x = s < 0 ? card.minX - 26 : card.maxX + 26
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x - s * 22, y: card.midY + 60))
    p.line(to: NSPoint(x: x, y: card.midY + 60))
    p.line(to: NSPoint(x: x, y: card.midY - 60))
    p.line(to: NSPoint(x: x - s * 22, y: card.midY - 60))
    p.lineWidth = 12
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.stroke()
}
ctx.restoreGState()

// The rim, lit from above.
ctx.restoreGState()
ctx.saveGState()
shape.lineWidth = 4
color(255, 255, 255, 0.18).setStroke()
shape.stroke()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
