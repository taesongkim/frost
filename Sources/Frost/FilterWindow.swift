import AppKit
import Combine

// MARK: - Panel

/// Titled (for native edge-resizing, rounded corners and shadow) but with the
/// title bar made invisible and the traffic lights hidden. Non-activating, so
/// summoning it never steals focus from what you're typing in.
final class FilterPanel: NSPanel {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDismissKey: (() -> Void)?
    var onNumberKey: ((Int) -> Void)?
    /// Points (in window coords) that belong to interactive controls, not the pane.
    var isControlHit: ((NSPoint) -> Bool)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(b)?.isHidden = true
        }
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.ignoresCycle]
        animationBehavior = .none
        minSize = NSSize(width: 80, height: 60)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Let it go anywhere, including over the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !(isControlHit?(event.locationInWindow) ?? false) {
            if event.clickCount >= 2 {
                onDoubleClick?()
                return
            }
            onClick?()
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismissKey?(); return } // Esc
        if let c = event.charactersIgnoringModifiers, let n = Int(c), (1...Preset.maxCount).contains(n),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onNumberKey?(n - 1)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "w" {
            onDismissKey?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Views

private final class DragThroughEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class DragThroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class FilterRootView: NSView {
    fileprivate let effect = DragThroughEffectView()
    fileprivate let pixel = DragThroughView()
    fileprivate let tint = DragThroughView()
    fileprivate let flashView = DragThroughView()
    let pill = PresetPill()

    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // A hair of opacity so a fully clear preset still catches clicks
        // instead of letting them fall through to the window underneath.
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.012).cgColor

        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = .hudWindow

        pixel.wantsLayer = true
        pixel.layer?.magnificationFilter = .nearest
        pixel.layer?.contentsGravity = .resize

        tint.wantsLayer = true

        flashView.wantsLayer = true
        flashView.layer?.backgroundColor = NSColor.white.cgColor
        flashView.layer?.opacity = 0

        for v in [effect, pixel, tint, flashView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }
        pill.alphaValue = 0
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updatePillVisibility() }
    override func mouseExited(with event: NSEvent) { hovering = false; updatePillVisibility() }

    override func layout() {
        super.layout()
        layoutPill()
    }

    func layoutPill() {
        pill.compact = bounds.width < 200
        let size = pill.fittingSize
        pill.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                            y: 10, width: size.width, height: size.height)
        updatePillVisibility()
    }

    func updatePillVisibility() {
        let fits = pill.frame.width + 16 <= bounds.width && bounds.height >= 56
        let show = hovering && fits && pill.dotCount > 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = show ? 1 : 0
        }
    }

    func flash() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.22
        a.toValue = 0
        a.duration = 0.22
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashView.layer?.add(a, forKey: "flash")
    }
}

// MARK: - Preset pill

/// Compact in-window preset switcher. Capped at Preset.maxCount dots so it can
/// never overflow; the label collapses away on narrow windows.
final class PresetPill: NSView {
    var onSelect: ((Int) -> Void)?
    var compact = false { didSet { if oldValue != compact { needsLayout = true } } }
    private(set) var dotCount = 0

    private var dots: [PresetDot] = []
    private let label = NSTextField(labelWithString: "")
    private var activeName = ""

    private let dotWidth: CGFloat = 16
    private let height: CGFloat = 22
    private let pad: CGFloat = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        layer?.cornerRadius = height / 2
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.92)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {} // swallow so the pill doesn't drag

    func update(presets: [Preset], activeID: UUID) {
        if dots.count != presets.count {
            dots.forEach { $0.removeFromSuperview() }
            dots = presets.indices.map { i in
                let d = PresetDot()
                d.onClick = { [weak self] in self?.onSelect?(i) }
                d.onHover = { [weak self] name in self?.label.stringValue = name ?? self?.activeName ?? "" }
                addSubview(d)
                return d
            }
        }
        dotCount = presets.count
        for (d, p) in zip(dots, presets) {
            d.name = p.name
            d.isActive = p.id == activeID
        }
        activeName = presets.first { $0.id == activeID }?.name ?? ""
        label.stringValue = activeName
        needsLayout = true
        superview?.needsLayout = true
    }

    private var labelWidth: CGFloat {
        compact ? 0 : min(110, ceil(label.intrinsicContentSize.width))
    }

    override var fittingSize: NSSize {
        let dotsW = CGFloat(dots.count) * dotWidth
        let lw = labelWidth
        return NSSize(width: pad + dotsW + (lw > 0 ? 4 + lw + pad + 2 : pad), height: height)
    }

    override func layout() {
        super.layout()
        var x = pad
        for d in dots {
            d.frame = NSRect(x: x, y: 0, width: dotWidth, height: height)
            x += dotWidth
        }
        let lw = labelWidth
        label.isHidden = lw == 0
        label.frame = NSRect(x: x + 4, y: (height - 14) / 2, width: lw, height: 14)
    }
}

private final class PresetDot: NSView {
    var onClick: (() -> Void)?
    var onHover: ((String?) -> Void)?
    var name = ""
    var isActive = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(name) }
    override func mouseExited(with event: NSEvent) { hovered = false; onHover?(nil) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = 7
        let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: r)
        if isActive {
            NSColor.white.setFill()
            path.fill()
        } else {
            NSColor(white: 1, alpha: hovered ? 0.7 : 0.4).setFill()
            path.fill()
        }
    }
}

// MARK: - Controller

final class FilterController: NSObject, NSWindowDelegate {
    let panel: FilterPanel
    private let root: FilterRootView
    private var capture: PixelCapture!
    private(set) var presetID: UUID
    private var cancellables = Set<AnyCancellable>()
    private var closing = false
    private let onClose: (FilterController) -> Void

    init(frame: NSRect, presetID: UUID, onClose: @escaping (FilterController) -> Void) {
        self.presetID = presetID
        self.onClose = onClose
        panel = FilterPanel(contentRect: frame)
        root = FilterRootView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()

        panel.contentView = root
        panel.delegate = self
        capture = PixelCapture(window: panel) { [weak self] image in
            self?.root.pixel.layer?.contents = image
        }

        panel.onClick = { [weak self] in self?.root.flash() }
        panel.onDoubleClick = { [weak self] in self?.dismiss() }
        panel.onDismissKey = { [weak self] in self?.dismiss() }
        panel.onNumberKey = { [weak self] i in self?.selectPreset(at: i) }
        panel.isControlHit = { [weak self] point in
            guard let pill = self?.root.pill, pill.alphaValue > 0.01 else { return false }
            return pill.bounds.contains(pill.convert(point, from: nil))
        }
        root.pill.onSelect = { [weak self] i in self?.selectPreset(at: i) }

        let store = Store.shared
        store.$presets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
        store.$defaultID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)
    }

    func show() {
        apply()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func dismiss(animated: Bool = true) {
        guard !closing else { return }
        closing = true
        capture.stop()
        cancellables.removeAll()
        let finish = { [self] in
            panel.orderOut(nil)
            panel.close()
            onClose(self)
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: finish)
    }

    private func selectPreset(at index: Int) {
        let presets = Store.shared.presets
        guard presets.indices.contains(index) else { return }
        presetID = presets[index].id
        apply()
    }

    private func apply() {
        guard !closing else { return }
        let store = Store.shared
        // A deleted preset falls back to the default.
        if !store.presets.contains(where: { $0.id == presetID }) { presetID = store.defaultID }
        let p = store.preset(presetID)

        panel.appearance = p.appearance.nsAppearance
        root.effect.material = p.material.material
        root.effect.alphaValue = CGFloat(p.blur)
        root.tint.layer?.backgroundColor = p.tint.nsColor.withAlphaComponent(CGFloat(p.tintOpacity)).cgColor

        if p.usesPixelate {
            ScreenPermission.requestIfNeeded()
            root.pixel.alphaValue = CGFloat(p.pixelMix)
            capture.pixelSize = CGFloat(p.pixelSize)
            if !capture.isRunning { capture.start() }
        } else {
            capture.stop()
            root.pixel.alphaValue = 0
            root.pixel.layer?.contents = nil
        }

        root.pill.update(presets: store.presets, activeID: p.id)
        root.layoutPill()
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) { capture.updateGeometry() }
    func windowDidResize(_ notification: Notification) { capture.updateGeometry() }
    func windowDidChangeScreen(_ notification: Notification) { capture.updateGeometry() }
}
