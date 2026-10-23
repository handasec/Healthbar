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

/// Three fixed steps rather than a free drag: the note is a glanceable widget,
/// and arbitrary sizes mostly produce awkward ones. The factor multiplies every
/// dimension — bounds, fonts, padding, bars — so the proportions never shift.
enum NoteScale: String, CaseIterable {
    case small, medium, large

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

    static var current: NoteScale {
        get {
            NoteScale(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
                ?? .medium
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
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

// MARK: - One labelled meter

final class MetricRow: NSView {
    static let baseHeight: CGFloat = 32

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")
    private let scale: CGFloat
    private let barHeight: CGFloat
    private var fraction: Double = 0

    init(name: String, scale: CGFloat) {
        self.scale = scale
        self.barHeight = (5 * scale).rounded()
        super.init(frame: .zero)

        nameLabel.attributedStringValue = NSAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5 * scale, weight: .bold),
                .foregroundColor: Glass.label,
                .kern: 1.2 * scale,
                .shadow: Glass.textShadow,
            ])

        valueLabel.alignment = .right

        for v in [nameLabel, valueLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor,
                                                constant: 6 * scale),

            heightAnchor.constraint(equalToConstant: (MetricRow.baseHeight * scale).rounded()),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ reading: Reading?) {
        fraction = reading?.fraction ?? 0
        // An attributed string carries its own alignment, so it has to be set here
        // rather than once on the field.
        let rightAligned = NSMutableParagraphStyle()
        rightAligned.alignment = .right

        valueLabel.attributedStringValue = NSAttributedString(
            string: reading?.text ?? "—",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5 * scale, weight: .semibold),
                .foregroundColor: Glass.value,
                .shadow: Glass.textShadow,
                .paragraphStyle: rightAligned,
            ])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = barHeight / 2
        let track = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        Glass.track.setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let color = Glass.meter(for: fraction)
        let width = max(barHeight, track.width * CGFloat(min(max(fraction, 0), 1)))
        let fill = NSRect(x: 0, y: 0, width: width, height: barHeight)

        // A soft glow under the bar so it reads clearly against a busy wallpaper.
        NSGraphicsContext.saveGraphicsState()
        NSShadow.glow(color: color).set()
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension NSShadow {
    static func glow(color: NSColor) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = .zero
        return shadow
    }
}

// MARK: - The note

final class StickyNoteView: NSView {
    static let baseSize = NSSize(width: 212, height: 164)

    static func size(for scale: NoteScale) -> NSSize {
        NSSize(width: (baseSize.width * scale.factor).rounded(),
               height: (baseSize.height * scale.factor).rounded())
    }

    private let scale: CGFloat
    private let padding: CGFloat
    private let corner: CGFloat

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    let disk: MetricRow
    let cpu: MetricRow
    let memory: MetricRow

    private var hovering = false
    private var tracking: NSTrackingArea?

    init(frame: NSRect, scale: NoteScale) {
        let factor = scale.factor
        self.scale = factor
        self.padding = (16 * factor).rounded()
        self.corner = (Glass.corner * factor).rounded()
        self.disk = MetricRow(name: "DISK", scale: factor)
        self.cpu = MetricRow(name: "CPU", scale: factor)
        self.memory = MetricRow(name: "MEMORY", scale: factor)
        super.init(frame: frame)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        titleLabel.attributedStringValue = NSAttributedString(
            string: "SYSTEM",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5 * scale, weight: .heavy),
                .foregroundColor: Glass.heading,
                .kern: 1.8 * scale,
                .shadow: Glass.textShadow,
            ])

        closeButton.isBordered = false
        closeButton.attributedTitle = NSAttributedString(
            string: "✕",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10 * scale, weight: .bold),
                .foregroundColor: NSColor(white: 1, alpha: 0.6),
            ])
        closeButton.target = NSApp
        closeButton.action = #selector(NSApplication.terminate(_:))
        closeButton.alphaValue = 0
        closeButton.toolTip = "Quit"

        let stack = NSStackView(views: [disk, cpu, memory])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.spacing = (6 * scale).rounded()

        for v in [titleLabel, closeButton, stack] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 13 * scale),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8 * scale),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8 * scale),
            closeButton.widthAnchor.constraint(equalToConstant: (16 * scale).rounded()),
            closeButton.heightAnchor.constraint(equalToConstant: (16 * scale).rounded()),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10 * scale),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12 * scale),
        ])

        for row in [disk, cpu, memory] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
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
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        needsDisplay = true   // the backdrop firms up while hovered
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            closeButton.animator().alphaValue = value ? 1 : 0
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        let active = NoteScale.current
        for option in NoteScale.allCases {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(AppDelegate.changeSize(_:)),
                                  keyEquivalent: "")
            item.representedObject = option.rawValue
            item.state = option == active ? .on : .off
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

    /// CPU wants frequent sampling; the disk only changes slowly.
    private let tick: TimeInterval = 2
    private var ticksUntilDiskRead = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = StickyNoteView.size(for: NoteScale.current)
        window = NoteWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: .borderless,
                            backing: .buffered,
                            defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.appearance = NSAppearance(named: .darkAqua)

        // No blur view: the window itself is transparent, so the note is a sheet of
        // tinted glass over your desktop rather than an opaque panel sitting on it.
        note = StickyNoteView(frame: NSRect(origin: .zero, size: size),
                              scale: NoteScale.current)
        note.autoresizingMask = [.width, .height]
        window.contentView = note

        // Restore where it was last dragged; otherwise park it top-left.
        if window.setFrameUsingName(autosaveName) {
            // The saved frame may be from an older, differently sized note —
            // keep its top-left corner and impose the current size.
            let saved = window.frame
            window.setFrame(NSRect(x: saved.minX, y: saved.maxY - size.height,
                                   width: size.width, height: size.height),
                            display: false)
        } else {
            moveToTopLeft()
        }
        window.setFrameAutosaveName(autosaveName)
        window.orderFrontRegardless()

        // Prime the CPU sampler so the first visible value is a real delta.
        _ = cpuSampler.read()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func resetPosition() {
        moveToTopLeft()
        window.saveFrame(usingName: autosaveName)
    }

    @objc func changeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let scale = NoteScale(rawValue: raw),
              scale != NoteScale.current else { return }
        NoteScale.current = scale

        // Every metric is baked in at init, so the note is rebuilt rather than
        // relaid out — cheaper to reason about than mutating a dozen constraints.
        let size = StickyNoteView.size(for: scale)
        let old = window.frame
        note = StickyNoteView(frame: NSRect(origin: .zero, size: size), scale: scale)
        note.autoresizingMask = [.width, .height]
        window.contentView = note

        // Resize from the top-left corner, so the note stays where you put it.
        window.setFrame(NSRect(x: old.minX, y: old.maxY - size.height,
                               width: size.width, height: size.height),
                        display: true)
        window.saveFrame(usingName: autosaveName)

        // The fresh rows are empty; fill them now instead of waiting for a tick.
        // No re-priming of the sampler — refresh consumes the delta already accrued.
        ticksUntilDiskRead = 0
        refresh()
    }

    private func moveToTopLeft() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = StickyNoteView.size(for: NoteScale.current)
        window.setFrameOrigin(NSPoint(x: visible.minX + margin,
                                      y: visible.maxY - size.height - margin))
    }

    @objc func refresh() {
        if ticksUntilDiskRead <= 0 {
            note.disk.apply(Disk.read())
            ticksUntilDiskRead = Int(30 / tick)  // roughly every 30s
        }
        ticksUntilDiskRead -= 1

        if let cpu = cpuSampler.read() { note.cpu.apply(cpu) }
        note.memory.apply(Memory.read())
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // no Dock icon, no menu bar
app.run()
