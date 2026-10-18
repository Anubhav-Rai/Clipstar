import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    private var escapeKey: HotKey?
    /// The app that was in front when the dock took focus.
    private var previousApp: NSRunningApplication?
    /// When the ring last turned, so a swipe keeps the mouse to the end.
    private var lastTurn = Date.distantPast
    /// Whether the swipe in progress zooms rather than slides.
    private var zooming = false
    /// Zoomed with Command and the wheel: it lasts while Command is held.
    private var wheelZoom = false
    private var settleWork: DispatchWorkItem?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer in the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Off unless turned on from the menu: a screenshot docks quietly and
    /// the dock only opens when you ask.
    static var peeksAtNew: Bool {
        get { UserDefaults.standard.bool(forKey: "peekAtNew") }
        set { UserDefaults.standard.set(newValue, forKey: "peekAtNew") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: DockView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled || ClipboardWatcher.isTextEnabled { clipboardWatcher.start() }

        registerShortcut()

        setUpStatusItem()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        line.onFall = { [weak self] item in self?.fall(item) }
        // For checking the layout on each display without moving the pointer:
        // a "com.anrai.Clipstar.open" notification with "screen" set to the
        // display's index opens or closes the dock there.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.anrai.Clipstar.open"), object: nil, queue: .main
        ) { [weak self] note in
            let index = Int(note.object as? String ?? "") ?? 0
            MainActor.assumeIsolated {
                let screens = NSScreen.screens
                self?.toggle(on: screens.indices.contains(index) ? screens[index] : nil)
            }
        }
        // A copy shows "Copied" for a moment, then the dock bows out.
        line.onCopy = { [weak self] in
            self?.pinned = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                self?.setRevealed(false)
            }
        }
        panel.onScroll = { [weak self] event in self?.turnRing(event) }
        panel.onMagnify = { [weak self] event in self?.pinch(event) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self?.refresh() }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let Clipstar handle your screenshots?")
        alert.informativeText = L(
            "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Clipstar quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        if let icon = NSImage(named: "Clipstar") ?? NSApp.applicationIconImage { alert.icon = icon }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        syncClipboardWatcher()
        updateStatusIcon()
    }

    private func setClipboardText(_ on: Bool) {
        ClipboardWatcher.isTextEnabled = on
        syncClipboardWatcher()
    }

    private func syncClipboardWatcher() {
        if ClipboardWatcher.isEnabled || ClipboardWatcher.isTextEnabled { clipboardWatcher.start() } else { clipboardWatcher.stop() }
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        // A peek appears at once; only opening on purpose warps the fleet in.
        if !isRevealed { line.instant = true }
        if Self.peeksAtNew { reveal(peekFor: 3) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    private func hangCapture(_ url: URL) {
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        // It shows up at once as the newest, with no flight.
        if line.hang(url) == nil {
            // Nothing hung after all, so an empty dock goes away again.
            itemsChanged()
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 3, let screen = panel.screen,
              let (to, _) = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let (card, slot) = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // Jettisoned out past its own edge. Screen y grows upwards.
        let out = slot.side.outward
        CaptureFlight.fall(image: image, card: card, toward: CGVector(dx: out.dx, dy: -out.dy), on: screen)
    }

    /// Where a card docks, in screen coordinates, using the same layout as
    /// the dock view, and the port it docks at.
    private func cardFrame(for id: UUID) -> (CGRect, Slot)? {
        let size = panel.frame.size
        guard let item = line.items.first(where: { $0.id == id }), let p = line.ringPosition(of: id),
              let place = Dock.place(at: p, ring: Dock.ring(in: size), head: Dock.head(in: size), tail: Dock.gate(in: size)) else { return nil }
        let card = DockedView.cardSize(for: item.thumb.size)
        return (CGRect(x: panel.frame.minX + place.center.x - card.width / 2,
                       y: panel.frame.maxY - place.center.y - card.height / 2,
                       width: card.width, height: card.height), place.slot)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        // Closing is quick but smooth, however it happens: the cards slip
        // out past their edges and the stars fade, in about a quarter second.
        if !on {
            if Line.keepTextShown == -1 { line.textUnlocked = false }
            line.instant = false
            line.zoom = 1
            line.zoomID = nil
        }
        line.revealed = on
        // Escape closes the dock while it is open, and only then.
        escapeKey = on ? HotKey(Shortcut(keyCode: kVK_Escape, modifiers: [], key: "")) { [weak self] in
            self?.setRevealed(false)
        } : nil
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
            // Opened on purpose, the dock takes focus like Mission Control,
            // so pinches and keys reach it; closing gives it back.
            if openedOnPurpose, !NSApp.isActive {
                previousApp = NSWorkspace.shared.frontmostApplication
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKey()
            }
        } else {
            // Long enough for the whole fleet to warp away; a peek goes at once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            if let previous = previousApp {
                previousApp = nil
                previous.activate()
            }
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    @objc private func toggle() { toggle(on: nil) }

    /// Opens the dock on that screen, or the one under the pointer.
    private func toggle(on screen: NSScreen?) {
        if isRevealed {
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            line.instant = false
            panel.placeOnScreen(screen)
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// Whether the pointer is near Clipstar's icon in the menu bar of this
    /// screen. Every screen shows the icon at the same distance from its
    /// right edge as the one the status item reports.
    private func nearIcon(_ mouse: NSPoint, on screen: NSScreen) -> Bool {
        guard let window = statusItem.button?.window,
              let home = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) }) else { return false }
        let fromRight = home.frame.maxX - window.frame.midX
        return abs(mouse.x - (screen.frame.maxX - fromRight)) <= 36
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        // A click on empty space in the open dock closes it, and goes no
        // further. Clicks on a card are the card's.
        if let away = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let window = event.windowNumber, p = event.locationInWindow
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRevealed, window == self.panel.windowNumber else { return false }
                let flipped = CGPoint(x: p.x, y: self.panel.frame.height - p.y)
                if self.line.hitRects.values.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(flipped) }) { return false }
                self.pinned = false
                self.setRevealed(false)
                return true
            }
            return swallow ? nil : event
        }) {
            clickMonitors.append(away)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the menu bar brings the line down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            // An empty line stays up there: only the shortcut and the menu
            // bring it down on purpose.
            if line.liveCount > 0, Self.opensFromMenuBar, let screen = screenUnderPointer,
               inMenuBar, nearIcon(mouse, on: screen), !menuBarSuppressed, !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    // Pointing at the icon is asking for the dock, like the
                    // shortcut: it stays until you click away or press Escape.
                    toggle()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)
        if wheelZoom, !NSEvent.modifierFlags.contains(.command) {
            wheelZoom = false
            unzoom()
        }
        if line.zoomID != nil, now.timeIntervalSince(lastTurn) > 0.3,
           let frame = zoomedFrame(), !frame.insetBy(dx: -12, dy: -12).contains(flippedPointer()) {
            unzoom()
        }

        // The dock's zone is the band along every edge, the menu bar
        // included, so moving up to it never closes the dock. Resting in the
        // middle of the screen counts as having left.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inner = Dock.inner(of: panel.frame.size)
        let middle = NSRect(x: panel.frame.minX + inner.minX, y: panel.frame.maxY - inner.maxY,
                            width: inner.width, height: inner.height)
        let inside = NSMouseInRect(mouse, zone, false) && !NSMouseInRect(mouse, middle, false)
        // Moving onto a card during a peek keeps the dock open, as if it had
        // been opened on purpose.
        if !pinned, line.hitRects.values.contains(where: {
            $0.contains(CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y))
        }) {
            pinned = true
        }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu
            || line.pressedID != nil || now < peekUntil
        // A peek from a new screenshot goes when its moment is up, wherever
        // the pointer is, unless you moved onto a card and so kept it.
        let peeking = peekUntil != .distantPast
        if inside && !(peeking && !busy) || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        // While the dock is open it covers the screen and takes every click,
        // so a click on empty space closes it without reaching the app below.
        var catches = isRevealed || line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // With more than fit, the whole rail takes the mouse, gaps included,
        // so a swipe anywhere along it turns the ring and never reaches the
        // app underneath (Safari would take it for Back). A swipe in
        // progress keeps it until a moment after the last scroll.
        if !catches, line.liveCount > line.ports {
            catches = Date().timeIntervalSince(lastTurn) < 0.6 || Self.onRail(flipped, in: panel.frame.size)
        }
        if panel.ignoresMouseEvents == catches {
            panel.ignoresMouseEvents = !catches
        }
    }

    /// The bands the rail runs through: the top from the left edge to just
    /// past the head, the left side, and the bottom up to and round the tail.
    private static func onRail(_ p: CGPoint, in size: CGSize) -> Bool {
        let top = CGRect(x: 0, y: 0, width: Dock.head(in: size).x + 50, height: Dock.topBand)
        let left = CGRect(x: 0, y: 0, width: Dock.sideBand, height: size.height)
        let bottom = CGRect(x: 0, y: size.height - Dock.topBand, width: size.width - 10, height: Dock.topBand)
        return top.contains(p) || left.contains(p) || bottom.contains(p)
    }

    // MARK: Turning the ring

    /// On a trackpad, two fingers sideways slide the rail; up and down, they
    /// zoom the card under the pointer, bigger as the fingers go up, for as
    /// long as they are down. A gesture keeps to whichever way it started.
    /// A mouse wheel slides the rail; with Command held it zooms instead,
    /// for as long as Command is held.
    private func turnRing(_ event: NSEvent) {
        lastTurn = Date()
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        // A wheel sends no gesture phases. Apps that smooth a mouse's wheel,
        // like Mac Mouse Fix, post their own events dressed up as trackpad
        // gestures, phases and all; those come from their process, where a
        // real trackpad's come from the hardware with none.
        let posted = (event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0) != 0
        if posted || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
            wheel(event, dx: dx, dy: dy)
            return
        }
        if event.phase == .began {
            zooming = abs(dy) > abs(dx)
            if zooming { zoomTarget() }
        }
        if zooming {
            // Only while the fingers are down: lifting them puts it back, and
            // the coasting that follows does nothing.
            guard event.momentumPhase.isEmpty else { return }
            if event.phase == .ended || event.phase == .cancelled {
                unzoom()
                return
            }
            guard line.zoomID != nil else { return }
            // With natural scrolling the deltas follow the content, the
            // other way from the fingers.
            let up = event.isDirectionInvertedFromDevice ? -dy : dy
            zoom(by: up / 120)
        } else {
            unzoom()
            line.scroll(by: (abs(dx) >= abs(dy) ? dx : dy) / 60)
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { line.settle() }
            }
        }
    }

    private func wheel(_ event: NSEvent, dx: CGFloat, dy: CGFloat) {
        let d = abs(dx) > abs(dy) ? dx : dy
        guard d != 0 else { return }
        if event.modifierFlags.contains(.command) {
            if line.zoomID == nil { zoomTarget() }
            guard line.zoomID != nil else { return }
            wheelZoom = true
            let up = event.isDirectionInvertedFromDevice ? -d : d
            if event.hasPreciseScrollingDeltas {
                zoom(by: up / 120)
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { zoom(by: up > 0 ? 0.25 : -0.25) }
            }
            return
        }
        unzoom()
        if event.hasPreciseScrollingDeltas {
            // Smooth scrolling follows the wheel, then settles into the ports
            // once it stops.
            line.scroll(by: d / 60)
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self?.line.settle() }
            }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { line.scroll(by: d > 0 ? 1 : -1) }
        }
    }

    /// A pinch zooms the card under the pointer, for as long as it lasts.
    private func pinch(_ event: NSEvent) {
        lastTurn = Date()
        if event.phase == .began || line.zoomID == nil { zoomTarget() }
        if event.phase == .ended || event.phase == .cancelled {
            unzoom()
            return
        }
        guard line.zoomID != nil else { return }
        zoom(by: event.magnification * 2)
    }

    /// The card under the pointer becomes the one to zoom.
    private func zoomTarget() {
        let flipped = flippedPointer()
        guard let id = line.hitRects.first(where: { $0.value.contains(flipped) })?.key else { return }
        if line.zoomID != id {
            line.zoom = 1
            line.zoomID = id
        }
    }

    private func zoom(by amount: CGFloat) {
        let size = panel.frame.size, box = Dock.box
        let most = max(1, min(2, size.width * 0.85 / box.width, size.height * 0.85 / box.height))
        line.zoom = min(most, max(1, line.zoom + amount))
    }

    private func unzoom() {
        guard line.zoomID != nil else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { line.zoom = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.line.zoom == 1 { self?.line.zoomID = nil }
        }
    }

    private func flippedPointer() -> CGPoint {
        let local = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        return CGPoint(x: local.x, y: panel.frame.height - local.y)
    }

    /// The zoomed card's frame as drawn, grown from its fixed point, so
    /// leaving it can shrink it back.
    private func zoomedFrame() -> CGRect? {
        guard let id = line.zoomID, let r = line.hitRects[id], let p = line.ringPosition(of: id) else { return nil }
        let size = panel.frame.size
        guard let place = Dock.place(at: p, ring: Dock.ring(in: size), head: Dock.head(in: size), tail: Dock.gate(in: size)) else { return nil }
        let box = Dock.box, z = line.zoom
        let fixed = CGPoint(x: place.center.x - box.width / 2 + place.center.x / size.width * box.width,
                            y: place.center.y - box.height / 2 + place.center.y / size.height * box.height)
        return CGRect(x: fixed.x + (r.minX - fixed.x) * z, y: fixed.y + (r.minY - fixed.y) * z,
                      width: r.width * z, height: r.height * z)
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    NSSound.beep()
                    Shortcut.current = previous
                }
            }
            self.registerShortcut()
        }
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    /// As many as the dock has ports on this screen.
    /// A ship takes more room than a card, so the ports are laid out again.
    private func setSkin(_ skin: Skin) {
        guard skin != Skin.current else { return }
        Skin.current = skin
        updateCapacity()
        line.objectWillChange.send()
    }

    private func updateCapacity() {
        let ports = max(4, Dock.ring(in: panel.frame.size).count)
        guard ports != line.ports else { return }
        line.ports = ports
        line.trim()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A viewfinder, like the corners of the dock. A dot in the middle
    /// while something is docked.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let count = line.liveCount
        let description = on ? L("Clipstar, hanging copied images") : "Clipstar"
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        let image = NSImage(systemSymbolName: count > 0 ? "dot.viewfinder" : "viewfinder",
                            accessibilityDescription: "\(description), \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        let text = ClosureMenuItem(L("Dock copied text")) { [weak self] in
            self?.setClipboardText(!ClipboardWatcher.isTextEnabled)
        }
        text.state = ClipboardWatcher.isTextEnabled ? .on : .off
        text.toolTip = L("Shown as asterisks until Touch ID or your password unlocks it")
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)
        menu.addItem(text)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests on the icon")) {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let keepItem = NSMenuItem(title: L("Keep text shown"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        for (minutes, title) in [(-1, L("Until the dock closes")), (15, L("15 minutes")), (60, L("1 hour")),
                                 (240, L("4 hours")), (0, L("Until Clipstar quits"))] {
            let item = ClosureMenuItem(title) { [weak self] in
                Line.keepTextShown = minutes
                // Takes effect now: a shown text keeps to the new time.
                if self?.line.textUnlocked == true { self?.line.textUnlocked = true }
            }
            item.state = Line.keepTextShown == minutes ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let skinItem = NSMenuItem(title: L("Skin"), action: nil, keyEquivalent: "")
        let skins = NSMenu()
        for skin in Skin.allCases {
            let item = ClosureMenuItem(skin.title) { [weak self] in self?.setSkin(skin) }
            item.state = Skin.current == skin ? .on : .off
            skins.addItem(item)
        }
        skinItem.submenu = skins
        menu.addItem(skinItem)

        let arrivalItem = NSMenuItem(title: L("Arrival"), action: nil, keyEquivalent: "")
        let arrivals = NSMenu()
        for arrival in Arrival.allCases {
            let item = ClosureMenuItem(arrival.title) { Arrival.current = arrival }
            item.state = Arrival.current == arrival ? .on : .off
            arrivals.addItem(item)
        }
        arrivalItem.submenu = arrivals
        menu.addItem(arrivalItem)

        let skyItem = NSMenuItem(title: L("Background"), action: nil, keyEquivalent: "")
        let skies = NSMenu()
        for (title, level) in [(L("Solid"), 0.95), (L("Dim"), 0.8), (L("Light"), 0.6), (L("Faint"), 0.4)] {
            let item = ClosureMenuItem(title) { Dock.skyOpacity = level }
            item.state = abs(Dock.skyOpacity - level) < 0.01 ? .on : .off
            skies.addItem(item)
        }
        skyItem.submenu = skies
        menu.addItem(skyItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Clipstar"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Clipstar to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
