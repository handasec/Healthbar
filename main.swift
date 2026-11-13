import Cocoa
import Darwin

// MARK: - Palette

enum Glass {
    static let corner: CGFloat = 13

    /// The note is genuinely see-through — a thin wash of ink, not a blurred panel,
    /// so whatever is underneath stays readable.
    static let backdrop = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 0.30)
    /// Firmed up while the pointer is over it, for when you actually want to read it.
    static let backdropHover = NSColor(srgbRed: 0.04, green: 0.05, blue: 0.06, alpha: 0.72)

    static let border = NSColor(white: 1, alpha: 0.18)
    static let highlight = NSColor(white: 1, alpha: 0.12)

    static let heading = NSColor(white: 1, alpha: 0.92)
    static let label = NSColor(white: 1, alpha: 0.62)
    static let value = NSColor(white: 1, alpha: 0.98)
    static let track = NSColor(white: 1, alpha: 0.18)

    /// Text sits directly over your windows now, so every glyph carries its own
    /// shadow — that is what keeps it legible on a light background.
    static var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.85)
        shadow.shadowBlurRadius = 3.5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    // Green is the resting accent; amber and red only show up under pressure.
    static let green = NSColor(srgbRed: 0.24, green: 0.84, blue: 0.53, alpha: 1)
    static let amber = NSColor(srgbRed: 0.96, green: 0.68, blue: 0.25, alpha: 1)
    static let red = NSColor(srgbRed: 0.96, green: 0.37, blue: 0.38, alpha: 1)

    static func meter(for fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.75: return green
        case ..<0.90: return amber
        default: return red
        }
    }
}

// MARK: - Size

/// Presets for the right-click menu. The note can also be dragged to any size in
/// between by its bottom-right corner; either way one factor multiplies every
/// dimension — bounds, fonts, padding, bars — so the proportions never shift.
enum NoteScale: String, CaseIterable {
    case small, medium, large

    /// Where versions before free resizing stored the chosen preset.
    static let defaultsKey = "NoteScale"

    var factor: CGFloat {
        switch self {
        case .small: return 0.82
        case .medium: return 1.00
        case .large: return 1.25
        }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

// MARK: - Readings

struct Reading {
    let fraction: Double   // 0...1, drives the bar
    let text: String       // what the note prints
}

/// Decimal GB, the same convention Finder uses.
func formatBytes(_ value: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = value >= 1_000_000_000 ? [.useGB] : [.useMB]
    return f.string(fromByteCount: value)
}

enum Disk {
    /// On APFS the writable data volume is the interesting one; fall back to root.
    private static let candidates = ["/System/Volumes/Data", "/"]

    static func read() -> Reading? {
        for path in candidates {
            var fs = statfs()
            guard statfs(path, &fs) == 0 else { continue }
            let block = Int64(fs.f_bsize)
            let total = Int64(fs.f_blocks) * block
            let free = Int64(fs.f_bavail) * block
            guard total > 0 else { continue }
            let used = Double(total - free) / Double(total)
            return Reading(fraction: used, text: "\(formatBytes(free)) free")
        }
        return nil
    }
}

/// CPU load is a delta between two samples, so the first call returns nil.
final class CPUSampler {
    private var previous: host_cpu_load_info?

    func read() -> Reading? {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        defer { previous = info }
        guard let prev = previous else { return nil }

        // &- so a 32-bit tick counter wrapping doesn't trap.
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)

        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        let busy = (user + system + nice) / total
        return Reading(fraction: busy, text: "\(Int((busy * 100).rounded()))%")
    }
}

enum Memory {
    /// Approximates Activity Monitor's "Memory Used":
    /// app memory (internal − purgeable) + wired + compressed.
    static func read() -> Reading? {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64()
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        let page = Int64(vm_kernel_page_size)
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let pages = max(0, app) + Int64(stats.wire_count) + Int64(stats.compressor_page_count)
        let used = pages * page

        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return nil }

        let fraction = min(1, Double(used) / Double(total))
        return Reading(fraction: fraction,
                       text: "\(Int((fraction * 100).rounded()))% · \(formatBytes(used))")
    }
}

// MARK: - The note

/// The whole note is one view that draws itself. There are no subviews, so there
/// is nothing to swallow a click: every mouse-down lands here and is routed to
/// exactly one of move, resize, or close. Every dimension is derived from the
/// view's current width, so resizing the window is all it takes to rescale.
final class StickyNoteView: NSView {
    static let baseSize = NSSize(width: 212, height: 164)
    static let minScale: CGFloat = 0.6
    static let maxScale: CGFloat = 3.0

    static func clamp(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(max(scale, minScale), maxScale)
    }

    /// The aspect ratio is locked, so a size is fully described by its scale.
    static func size(for scale: CGFloat) -> NSSize {
        let s = clamp(scale)
        return NSSize(width: (baseSize.width * s).rounded(),
                      height: (baseSize.height * s).rounded())
    }

    var disk: Reading? { didSet { redraw() } }
    var cpu: Reading? { didSet { redraw() } }
    var memory: Reading? { didSet { redraw() } }

    /// Called once a move or resize gesture finishes, so the app can persist it.
    var onGestureEnded: (() -> Void)?

    private enum Gesture {
        case move(mouse: NSPoint, origin: NSPoint)
        case resize(mouse: NSPoint, frame: NSRect)
        case close
    }

    private var gesture: Gesture?
    private var hovering = false
    private var overGrip = false
    private var overClose = false

    private var scale: CGFloat { bounds.width / StickyNoteView.baseSize.width }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        // .inVisibleRect keeps the area matched to the view as it resizes;
        // .activeAlways because this app is never the active one.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func redraw() {
        needsDisplay = true
        // The window shadow is cut from the drawn content; without this a
        // transparent window keeps the outline of whatever it showed before.
        window?.invalidateShadow()
    }

    // MARK: Hit zones

    private var closeZone: NSRect {
        let side = 24 * scale
        return NSRect(x: bounds.maxX - side - 3 * scale, y: bounds.maxY - side - 3 * scale,
                      width: side, height: side)
    }

    private var resizeZone: NSRect {
        let side = max(20, 24 * scale)
        return NSRect(x: bounds.maxX - side, y: bounds.minY, width: side, height: side)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let s = scale
        let corner = Glass.corner * s
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: corner, yRadius: corner)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        (hovering ? Glass.backdropHover : Glass.backdrop).setFill()
        bounds.fill(using: .sourceOver)

        // Thin highlight along the top edge, the way real glass catches light.
        Glass.highlight.setStroke()
        let top = NSBezierPath()
        top.move(to: NSPoint(x: corner, y: bounds.maxY - 0.5))
        top.line(to: NSPoint(x: bounds.maxX - corner, y: bounds.maxY - 0.5))
        top.lineWidth = 1
        top.stroke()
        NSGraphicsContext.restoreGraphicsState()

        Glass.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let padding = 16 * s

        let title = NSAttributedString(
            string: "SYSTEM",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5 * s, weight: .heavy),
                .foregroundColor: Glass.heading,
                .kern: 1.8 * s,
                .shadow: Glass.textShadow,
            ])
        title.draw(at: NSPoint(x: padding,
                               y: bounds.maxY - 14 * s - title.size().height))

        // Three rows of 32 with 8 between them, starting 40 below the top edge.
        let rows: [(String, Reading?)] = [("DISK", disk), ("CPU", cpu), ("MEMORY", memory)]
        for (index, row) in rows.enumerated() {
            let rowTop = bounds.maxY - (40 + CGFloat(index) * 40) * s
            drawRow(name: row.0, reading: row.1, top: rowTop, padding: padding, scale: s)
        }

        if hovering || gesture != nil {
            drawCloseMark(scale: s)
            drawGrip(scale: s)
        }
    }

    private func drawRow(name: String, reading: Reading?, top: CGFloat,
                         padding: CGFloat, scale s: CGFloat) {
        let nameFont = NSFont.systemFont(ofSize: 9.5 * s, weight: .bold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * s, weight: .semibold)

        let nameText = NSAttributedString(
            string: name,
            attributes: [
                .font: nameFont,
                .foregroundColor: Glass.label,
                .kern: 1.2 * s,
                .shadow: Glass.textShadow,
            ])
        let valueText = NSAttributedString(
            string: reading?.text ?? "—",
            attributes: [
                .font: valueFont,
                .foregroundColor: Glass.value,
                .shadow: Glass.textShadow,
            ])

        // Both strings share a baseline; descender is negative, so subtracting
        // it lifts from the bottom of the line box up to the baseline.
        let nameY = top - 1 * s - nameText.size().height
        let baseline = nameY - nameFont.descender
        nameText.draw(at: NSPoint(x: padding, y: nameY))
        valueText.draw(at: NSPoint(x: bounds.maxX - padding - valueText.size().width,
                                   y: baseline + valueFont.descender))

        let barHeight = 5 * s
        let radius = barHeight / 2
        let track = NSRect(x: padding, y: top - 32 * s,
                           width: bounds.width - 2 * padding, height: barHeight)

        Glass.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fraction = min(max(reading?.fraction ?? 0, 0), 1)
        let color = Glass.meter(for: fraction)
        var fill = track
        fill.size.width = max(barHeight, track.width * CGFloat(fraction))

        // A soft glow under the bar so it reads clearly against a busy wallpaper.
        NSGraphicsContext.saveGraphicsState()
        NSShadow.glow(color: color, radius: 5 * s).set()
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawCloseMark(scale s: CGFloat) {
        let zone = closeZone
        let center = NSPoint(x: zone.midX, y: zone.midY)
        let arm = 3.5 * s

        let mark = NSBezierPath()
        mark.move(to: NSPoint(x: center.x - arm, y: center.y - arm))
        mark.line(to: NSPoint(x: center.x + arm, y: center.y + arm))
        mark.move(to: NSPoint(x: center.x - arm, y: center.y + arm))
        mark.line(to: NSPoint(x: center.x + arm, y: center.y - arm))
        mark.lineWidth = 1.5 * s
        mark.lineCapStyle = .round
        NSColor(white: 1, alpha: overClose ? 1.0 : 0.6).setStroke()
        mark.stroke()
    }

    /// Two diagonal ticks in the bottom-right corner: the handle to drag to resize.
    private func drawGrip(scale s: CGFloat) {
        let unit = max(s, 0.85)   // keep the handle visible on the smallest note
        let cornerX = bounds.maxX
        let cornerY = bounds.minY

        let grip = NSBezierPath()
        for reach in [10.0, 14.5] as [CGFloat] {
            grip.move(to: NSPoint(x: cornerX - reach * unit, y: cornerY + 5.5 * unit))
            grip.line(to: NSPoint(x: cornerX - 5.5 * unit, y: cornerY + reach * unit))
        }
        grip.lineWidth = 1.5 * unit
        grip.lineCapStyle = .round
        NSColor(white: 1, alpha: overGrip ? 1.0 : 0.5).setStroke()
        grip.stroke()
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }

    override func mouseExited(with event: NSEvent) {
        // A fast drag can outrun the window for a frame; that is not a real exit.
        guard gesture == nil else { return }
        setHover(inside: false, grip: false, close: false)
    }

    private func updateHover(with event: NSEvent) {
        guard gesture == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        setHover(inside: bounds.contains(point),
                 grip: resizeZone.contains(point),
                 close: closeZone.contains(point))
    }

    private func setHover(inside: Bool, grip: Bool, close: Bool) {
        guard hovering != inside || overGrip != grip || overClose != close else { return }
        hovering = inside
        overGrip = grip
        overClose = close
        redraw()
    }

    // MARK: Move, resize, close

    /// Act on the very first click, even though the app is never frontmost.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Dragging is handled below, explicitly, instead of by the window server.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Screen coordinates, not window ones: the window itself moves during
        // the gesture, so anything measured relative to it would jitter.
        let mouse = NSEvent.mouseLocation

        if closeZone.contains(point) {
            gesture = .close
        } else if resizeZone.contains(point) {
            gesture = .resize(mouse: mouse, frame: window.frame)
            overGrip = true
        } else {
            gesture = .move(mouse: mouse, origin: window.frame.origin)
        }
        hovering = true
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window, let gesture = gesture else { return }
        let mouse = NSEvent.mouseLocation

        switch gesture {
        case .move(let start, let origin):
            window.setFrameOrigin(NSPoint(x: (origin.x + mouse.x - start.x).rounded(),
                                          y: (origin.y + mouse.y - start.y).rounded()))

        case .resize(let start, let frame):
            // The pointer moves freely but the note keeps its proportions, so
            // take the width implied by each axis and split the difference.
            let base = StickyNoteView.baseSize
            let byWidth = frame.width + (mouse.x - start.x)
            let byHeight = (frame.height - (mouse.y - start.y)) * (base.width / base.height)
            let size = StickyNoteView.size(for: ((byWidth + byHeight) / 2) / base.width)

            // The top-left corner stays pinned; the dragged corner follows.
            window.setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height,
                                   width: size.width, height: size.height),
                            display: true)
            redraw()

        case .close:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let finished = gesture else { return }
        gesture = nil
        let point = convert(event.locationInWindow, from: nil)

        if case .close = finished {
            // Like any button: releasing outside it cancels.
            if closeZone.contains(point) {
                NSApp.terminate(nil)
                return
            }
        } else {
            onGestureEnded?()
        }

        hovering = bounds.contains(point)
        overGrip = resizeZone.contains(point)
        overClose = closeZone.contains(point)
        redraw()
    }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for option in NoteScale.allCases {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(AppDelegate.changeSize(_:)),
                                  keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = abs(option.factor - scale) < 0.01 ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Reset Position",
                     action: #selector(AppDelegate.resetPosition), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }
}

extension NSShadow {
    static func glow(color: NSColor, radius: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = radius
        shadow.shadowOffset = .zero
        return shadow
    }
}

// MARK: - Window

final class NoteWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NoteWindow!
    private var note: StickyNoteView!
    private var timer: Timer?

    private let cpuSampler = CPUSampler()
    private let margin: CGFloat = 16
    private let autosaveName = NSWindow.FrameAutosaveName("HealthbarFrame")
    private let scaleKey = "NoteScaleFactor"

    /// CPU wants frequent sampling; the disk only changes slowly.
    private let tick: TimeInterval = 2
    private var ticksUntilDiskRead = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = StickyNoteView.size(for: storedScale())
        window = NoteWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: .borderless,
                            backing: .buffered,
                            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        // The note moves and resizes itself (see StickyNoteView); letting the
        // window server drag it as well would have the two fighting.
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)

        // No blur view: the window itself is transparent, so the note is a sheet of
        // tinted glass over your desktop rather than an opaque panel sitting on it.
        note = StickyNoteView(frame: NSRect(origin: .zero, size: size))
        note.autoresizingMask = [.width, .height]
        note.onGestureEnded = { [weak self] in
            self?.keepOnScreen()
            self?.persist()
        }
        window.contentView = note

        // Restore where it was last dragged; otherwise park it top-left.
        if window.setFrameUsingName(autosaveName) {
            // A borderless window only gets its origin back, and the saved frame
            // may be from a differently sized note — keep its top-left corner
            // and impose the size we actually want.
            let saved = window.frame
            window.setFrame(NSRect(x: saved.minX, y: saved.maxY - size.height,
                                   width: size.width, height: size.height),
                            display: false)
        } else {
            moveToTopLeft()
        }
        // The saved spot may be on a display that is no longer attached.
        keepOnScreen()
        window.orderFrontRegardless()

        // Prime the CPU sampler so the first visible value is a real delta.
        _ = cpuSampler.read()
        refresh()

        // .common so the bars keep updating while a menu is open or a drag is live.
        let timer = Timer(timeInterval: tick, target: self, selector: #selector(refresh),
                          userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Size and position

    /// The free-form scale if one was saved, else the Small/Medium/Large choice
    /// an older version stored, else medium.
    private func storedScale() -> CGFloat {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: scaleKey) != nil {
            return StickyNoteView.clamp(CGFloat(defaults.double(forKey: scaleKey)))
        }
        if let legacy = NoteScale(rawValue: defaults.string(forKey: NoteScale.defaultsKey) ?? "") {
            return legacy.factor
        }
        return NoteScale.medium.factor
    }

    private func persist() {
        let scale = window.frame.width / StickyNoteView.baseSize.width
        UserDefaults.standard.set(Double(scale), forKey: scaleKey)
        window.saveFrame(usingName: autosaveName)
    }

    @objc func resetPosition() {
        moveToTopLeft()
        persist()
    }

    @objc func changeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let scale = NoteScale(rawValue: raw) else { return }

        // Resize from the top-left corner, so the note stays where you put it.
        let size = StickyNoteView.size(for: scale.factor)
        let old = window.frame
        window.setFrame(NSRect(x: old.minX, y: old.maxY - size.height,
                               width: size.width, height: size.height),
                        display: true)
        window.invalidateShadow()
        keepOnScreen()
        persist()
    }

    @objc private func screensChanged() {
        keepOnScreen()
        persist()
    }

    private func moveToTopLeft() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + margin,
                                      y: visible.maxY - window.frame.height - margin))
    }

    /// Nudges the note back if it has ended up somewhere it cannot be grabbed:
    /// off every display, or with its top tucked under the menu bar.
    private func keepOnScreen() {
        let frame = window.frame
        func overlap(_ screen: NSScreen) -> CGFloat {
            let shared = screen.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }

        var home = NSScreen.main ?? NSScreen.screens.first
        var best: CGFloat = 0
        for screen in NSScreen.screens where overlap(screen) > best {
            best = overlap(screen)
            home = screen
        }
        guard let visible = home?.visibleFrame else { return }

        // Always leave this much of the note reachable.
        let reach = min(48, frame.width, frame.height)
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX - frame.width + reach), visible.maxX - reach)
        origin.y = min(max(origin.y, visible.minY - frame.height + reach),
                       visible.maxY - frame.height)
        if origin != frame.origin {
            window.setFrameOrigin(origin)
        }
    }

    // MARK: Readings

    @objc func refresh() {
        if ticksUntilDiskRead <= 0 {
            note.disk = Disk.read()
            ticksUntilDiskRead = Int(30 / tick)  // roughly every 30s
        }
        ticksUntilDiskRead -= 1

        if let cpu = cpuSampler.read() { note.cpu = cpu }
        note.memory = Memory.read()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar
app.run()
