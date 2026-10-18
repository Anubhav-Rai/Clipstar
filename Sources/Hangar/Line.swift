import AppKit
import AVFoundation
import Combine
import LocalAuthentication
import os

let log = Logger(subsystem: "com.anrai.Hangar", category: "line")

/// One screenshot hanging on the line.
struct Pegged: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    var thumb: NSImage
    /// Every photo hangs a little crooked, like on a real line.
    let tilt = Double.random(in: -2.5...2.5)
    var falling = false
    /// When it arrived, so a brand new one warps in while one brought out
    /// of the gate by the ring just appears.
    let born = Date()
    /// Still flying in from where it was captured; the card waits hidden.
    var flying = false
    /// A screen recording rather than a screenshot.
    var isRecording: Bool { Hangar.isRecording(url) }
    /// Copied text rather than a picture.
    var isText: Bool { Hangar.isText(url) }

    static func == (a: Pegged, b: Pegged) -> Bool {
        a.id == b.id && a.falling == b.falling && a.flying == b.flying && a.thumb === b.thumb
    }
}

/// The line itself: what hangs on it and what you can do with each item.
/// The files never move. The line is only a view onto them.
@MainActor
final class Line: ObservableObject {
    @Published private(set) var items: [Pegged] = []
    @Published private(set) var gust = 0
    @Published var copiedID: UUID?
    @Published var draggingID: UUID?
    @Published var pressedID: UUID?
    /// Whether the dock is open.
    @Published var revealed = false
    /// Copied text shows as asterisks until Touch ID or the password
    /// unlocks it; it locks again when the dock closes.
    @Published var textUnlocked = false

    /// Opened for a moment by a new screenshot: everything appears at once,
    /// with no warp.
    @Published var instant = false

    /// Card frames in window coordinates, reported by the views. The panel
    /// uses them to only catch clicks over photos and let the rest through.
    var hitRects: [UUID: CGRect] = [:]

    /// How many the dock keeps. Past the ports on screen, the rest wait in
    /// the warp gate and the ring turns to bring them out.
    var maxItems = 100
    /// How many ports the dock has on this screen.
    @Published var ports = 12
    /// How far the ring is turned back from the newest, in cards. 0 shows
    /// the newest ones.
    @Published var scroll: CGFloat = 0
    /// The card being zoomed with an up and down swipe, and by how much.
    @Published var zoomID: UUID?
    @Published var zoom: CGFloat = 1


    var soundOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    var liveCount: Int { items.filter { !$0.falling }.count }

    private let storeKey = "pegged"

    init() {
        restore()
        scheduleGust()
    }

    // MARK: Hanging and dropping

    @discardableResult
    func hang(_ url: URL, quietly: Bool = false, flying: Bool = false) -> UUID? {
        guard !items.contains(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return nil }
        var item = Pegged(url: url, thumb: thumb)
        item.flying = flying
        items.append(item)
        scroll = 0
        // A full line lets the oldest photo fall off the far end. Only one: a
        // line hung on a wider screen keeps its length here instead of losing
        // several photos to a single capture.
        if liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        save()
        // macOS already plays its shutter for a screenshot: docking it makes
        // no sound of its own.
        return item.id
    }

    /// The capture has reached the line: the real card takes over.
    func land(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].flying = false
    }

    /// Called once something is copied: the dock gets out of the way.
    var onCopy: (() -> Void)?

    /// Called just before a photo starts falling, so the fall can be drawn
    /// over the whole screen.
    var onFall: ((Pegged) -> Void)?

    func drop(_ id: UUID, quietly: Bool = false) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].falling else { return }
        onFall?(items[i])
        items[i].falling = true
        hitRects[id] = nil
        save()
        if !quietly { play("Pop", volume: 0.25) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }

    /// "Take everything down": every photo goes the way of its corner cross.
    func clear() {
        takeDown(items.filter { !$0.falling })
    }

    /// Every other docked screenshot.
    func others(than id: UUID) -> [Pegged] {
        items.filter { !$0.falling && $0.id != id }
    }

    /// Undocks everything but this one. Each goes the way of its own corner
    /// button: to the Trash from Hangar's folder, and only out of the dock
    /// from anywhere else.
    func takeDownOthers(than id: UUID) {
        takeDown(others(than: id))
    }

    /// All at once, however many: they leave the dock together, and the ones
    /// from Hangar's folder go to the Trash in a single batch, off the main
    /// thread. Files from anywhere else stay where they are.
    private func takeDown(_ gone: [Pegged]) {
        guard !gone.isEmpty else { return }
        let ids = Set(gone.map(\.id))
        let toTrash = gone.filter { isInInbox($0.id) }.map(\.url)
        items.removeAll { ids.contains($0.id) }
        for id in ids { hitRects[id] = nil }
        scroll = min(scroll, maxScroll)
        save()
        if toTrash.isEmpty {
            play("Pop", volume: 0.25)
            return
        }
        if soundOn { Line.trashSound?.play() }
        NSWorkspace.shared.recycle(toTrash) { _, error in
            if let error { log.error("Could not trash: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Photos whose file was deleted or moved away fall off by themselves.
    func prune() {
        for item in items where !item.falling && !FileManager.default.fileExists(atPath: item.url.path) {
            drop(item.id, quietly: true)
        }
    }

    // MARK: Actions on one photo

    func copy(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let entry = NSPasteboardItem()
        if item.isText {
            guard let text = try? String(contentsOf: item.url, encoding: .utf8) else { return }
            entry.setString(text, forType: .string)
            // Marked so the clipboard watcher does not dock it a second time.
            entry.setString("", forType: .init("org.nspasteboard.AutoGeneratedType"))
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([entry])
            copiedID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.copiedID == id { self?.copiedID = nil }
            }
            onCopy?()
            return
        }
        // A recording is copied as the file, which apps paste as the video.
        if !item.isRecording, let png = pngData(item.url) { entry.setData(png, forType: .png) }
        entry.setString(item.url.absoluteString, forType: .fileURL)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])

        copiedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == id { self?.copiedID = nil }
        }
        onCopy?()
    }

    func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        // Opening copied text shows it, so it needs unlocking first.
        if item.isText && !textUnlocked { return unlockText { NSWorkspace.shared.open(item.url) } }
        NSWorkspace.shared.open(item.url)
    }

    /// Asks for Touch ID or the Mac's password, then shows copied text
    /// until the dock closes.
    func unlockText(then action: (() -> Void)? = nil) {
        if textUnlocked {
            action?()
            return
        }
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L("show your copied text")) { ok, _ in
            Task { @MainActor [weak self] in
                guard ok, let self else { return }
                self.textUnlocked = true
                action?()
            }
        }
    }

    /// Moves the file to the Trash and takes the photo off the line. When a
    /// drag ends on the Dock's Trash, macOS only reports it: deleting the file
    /// is the source app's job, as Finder does.
    @discardableResult
    func trash(_ id: UUID, quietly: Bool = false) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            log.notice("Trashed \(item.url.lastPathComponent, privacy: .public)")
            if soundOn && !quietly { Line.trashSound?.play() }
            drop(id, quietly: true)
            return true
        } catch {
            log.error("Could not trash \(item.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            if !quietly { NSSound.beep() }
            return false
        }
    }

    private static let trashSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
        byReference: true)

    /// Whether the file lives in Tendedero's own folder. Those are discarded
    /// to the Trash, or the folder would fill up with forgotten screenshots.
    /// Files anywhere else, like the Desktop, stay where they are.
    func isInInbox(_ id: UUID) -> Bool {
        guard let item = items.first(where: { $0.id == id }) else { return false }
        return item.url.standardizedFileURL.path.hasPrefix(Inbox.folder.standardizedFileURL.path + "/")
    }

    /// The corner cross and "Take down" both end up here.
    func discard(_ id: UUID, quietly: Bool = false) {
        if isInInbox(id) { trash(id, quietly: quietly) } else { drop(id, quietly: quietly) }
    }

    /// The oldest photo falling off a full line. Like the cross, a file from
    /// Tendedero's folder goes to the Trash, or nothing would ever take it out
    /// of that folder. If the Trash refuses it, it still leaves the line.
    /// After the dock gets fewer ports (a smaller screen, a bigger size),
    /// the oldest screenshots past it go the way of a full dock, and the
    /// rest move to ports that still exist.
    func trim() {
        while liveCount > maxItems, let oldest = items.first(where: { !$0.falling }) {
            letGo(oldest.id)
        }
        scroll = min(scroll, maxScroll)
    }

    // MARK: Turning the ring

    /// How far back the ring can turn: until the oldest is at the first port.
    var maxScroll: CGFloat { CGFloat(max(0, liveCount - ports)) }

    /// A scroll gesture turns the ring, following the fingers.
    func scroll(by cards: CGFloat) {
        let next = min(maxScroll, max(0, scroll + cards))
        if next != scroll { scroll = next }
    }

    /// Once the fingers let go, every card settles into a port.
    func settle() {
        scroll = min(maxScroll, max(0, scroll.rounded()))
    }

    /// Where a live screenshot sits on the rail, in ports from the head:
    /// 0 is the newest port. Turning the ring back brings older ones
    /// forward; below 0 or past the last port, it is out of sight.
    func ringPosition(of id: UUID) -> CGFloat? {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return nil }
        return CGFloat(live.count - 1 - i) - scroll
    }

    /// 1 for the newest, 2 for the one before, and so on.
    func number(of id: UUID) -> Int? {
        let live = items.filter { !$0.falling }
        guard let i = live.firstIndex(where: { $0.id == id }) else { return nil }
        return live.count - i
    }

    private func letGo(_ id: UUID) {
        if isInInbox(id), trash(id, quietly: true) { return }
        drop(id, quietly: true)
    }

    /// Inbox mode: keep a screenshot by moving it to the Desktop.
    func saveToDesktop(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let target = uniqueURL(in: desktop, for: item.url.lastPathComponent)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            drop(id, quietly: true)
        } catch {
            log.error("Could not save to Desktop: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private func uniqueURL(in folder: URL, for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Long press: open the photo in the system Markup editor. Markup does
    /// not edit video, so a recording opens in the trimming editor instead.
    func markup(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.isText else { return }
        if item.isRecording {
            Trim.shared.edit(item.url, size: item.thumb.size)
        } else {
            Markup.shared.edit(item.url)
        }
    }

    /// After editing, the photo on the line shows the new version.
    func reloadThumbnail(for url: URL) {
        guard let i = items.firstIndex(where: { $0.url == url && !$0.falling }),
              let thumb = makeThumbnail(url) else { return }
        items[i].thumb = thumb
    }

    /// Quick Look on this photo, with the rest of the line a key press away.
    func quickLook(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), item.isText, !textUnlocked {
            return unlockText { [weak self] in self?.quickLook(id) }
        }
        let live = items.filter { !$0.falling }
        guard let index = live.firstIndex(where: { $0.id == id }) else { return }
        QuickLook.shared.show(live.map(\.url), at: index)
    }

    /// After a change of size, every photo is redrawn sharp at the new one.
    func reloadThumbnails() {
        for i in items.indices where !items[i].falling {
            if let thumb = makeThumbnail(items[i].url) { items[i].thumb = thumb }
        }
    }

    func reveal(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Breeze

    /// Every so often a little wind moves the line. It is the detail that
    /// makes it feel like an object and not a widget.
    private func scheduleGust() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 7...16)) { [weak self] in
            guard let self else { return }
            if !self.items.isEmpty && self.draggingID == nil { self.gust += 1 }
            self.scheduleGust()
        }
    }

    // MARK: Persistence

    private func save() {
        let paths = items.filter { !$0.falling }.map(\.url.path)
        UserDefaults.standard.set(paths, forKey: storeKey)
    }

    /// Everything comes back as it was. This runs before the line knows its
    /// screen, so the capacity is still the default one: hanging through
    /// `hang` would let photos fall off a wide screen's line at every launch.
    private func restore() {
        let paths = UserDefaults.standard.stringArray(forKey: storeKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard !items.contains(where: { $0.url == url }), let thumb = makeThumbnail(url) else { continue }
            items.append(Pegged(url: url, thumb: thumb))
        }
    }

    // MARK: Helpers

    private func play(_ name: String, volume: Float) {
        guard soundOn, let sound = NSSound(named: name)?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    private func pngData(_ url: URL) -> Data? {
        if url.pathExtension.lowercased() == "png" { return try? Data(contentsOf: url) }
        guard let tiff = NSImage(contentsOf: url)?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// Copied text, kept as a text file in Hangar's folder.
func isText(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "txt"
}

/// Screen recordings, as macOS saves them.
func isRecording(_ url: URL) -> Bool {
    ["mov", "mp4"].contains(url.pathExtension.lowercased())
}

/// The default size covers a card at twice its size in points, as on a
/// Retina screen, and no more: every photo on the line keeps one in memory.
func makeThumbnail(_ url: URL, maxPixels: Int = Int(320 * Layout.size.scale)) -> NSImage? {
    if isRecording(url) { return firstFrame(url, maxPixels: maxPixels) }
    if isText(url) { return maskedText() }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// A recording shows its first frame.
private func firstFrame(_ url: URL, maxPixels: Int) -> NSImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
    guard let cg = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// What copied text looks like wherever it is drawn as a picture, like the
/// image under the pointer while it is dragged: asterisks, never the text.
private func maskedText() -> NSImage {
    let size = NSSize(width: 280, height: 180)
    return NSImage(size: size, flipped: false) { r in
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 30, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 1, green: 0.88, blue: 0.54, alpha: 1),
        ]
        for (i, line) in ["**********", "*******", "*********"].enumerated() {
            (line as NSString).draw(at: NSPoint(x: 26, y: r.height - 62 - CGFloat(i) * 42), withAttributes: attrs)
        }
        return true
    }
}
