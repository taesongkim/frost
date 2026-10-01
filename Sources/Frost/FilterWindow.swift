import AppKit
import Combine

// MARK: - Panel

/// Titled (for native edge-resizing, rounded corners and shadow) but with the
/// title bar made invisible and the traffic lights hidden. Non-activating, so
/// summoning it never steals focus from what you're typing in.
final class FilterPanel: NSPanel {
    var onClick: (() -> Void)?
    /// A click that didn't turn into a drag or resize.
    var onPlainClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDismissKey: (() -> Void)?
    var onNumberKey: ((Int) -> Void)?
    /// Tab (+1) / Shift-Tab (-1).
    var onCycleKey: ((Int) -> Void)?
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

    private var mouseDownFrame: NSRect?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where !(isControlHit?(event.locationInWindow) ?? false):
            if event.clickCount >= 2 {
                mouseDownFrame = nil
                onDoubleClick?()
                return
            }
            mouseDownFrame = frame
            onClick?()
        case .leftMouseUp:
            if let start = mouseDownFrame, start == frame, event.clickCount == 1 { onPlainClick?() }
            mouseDownFrame = nil
        default:
            break
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDismissKey?(); return } // Esc
        if event.keyCode == 48 { // Tab
            onCycleKey?(event.modifierFlags.contains(.shift) ? -1 : 1)
            return
        }
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

private final class DragThroughView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// Small dark capsule with a single line (or wrapped lines) of white text. Clicks
/// pass to the window as if it weren't there, so it can still be dragged by it.
final class Bubble: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let padX: CGFloat, padY: CGFloat

    init(fontSize: CGFloat, padX: CGFloat, padY: CGFloat, radius: CGFloat?) {
        self.padX = padX
        self.padY = padY
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        label.font = .systemFont(ofSize: fontSize, weight: .medium)
        label.textColor = NSColor(white: 1, alpha: 0.95)
        label.alignment = .center
        label.isSelectable = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        self.radius = radius
    }

    required init?(coder: NSCoder) { fatalError() }

    private var radius: CGFloat?
    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    var maxLines = 1 { didSet { label.maximumNumberOfLines = maxLines } }

    override var mouseDownCanMoveWindow: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Sizes to fit the text, never wider than `maxWidth`.
    func fit(maxWidth: CGFloat) -> NSSize {
        label.maximumNumberOfLines = maxLines
        label.preferredMaxLayoutWidth = max(10, maxWidth - padX * 2)
        let natural = label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 1000))
        let textW = min(ceil(natural.width), maxWidth - padX * 2)
        let textH = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 1000)).height)
        let lines = maxLines == 1 ? ceil(natural.height) : textH
        let size = NSSize(width: textW + padX * 2, height: lines + padY * 2)
        label.frame = NSRect(x: padX, y: padY, width: textW, height: lines)
        layer?.cornerRadius = radius ?? size.height / 2
        return size
    }
}

final class FilterRootView: NSView {
    fileprivate let tint = DragThroughView()
    fileprivate let flashView = DragThroughView()
    let pill = PresetPill()
    let nameBubble = Bubble(fontSize: 11, padX: 9, padY: 3, radius: nil)
    let hint = Bubble(fontSize: 13, padX: 14, padY: 8, radius: 10)

    private var hovering = false
    /// Keeps the switcher up briefly after a keyboard preset change.
    private var peeking = false
    private var peekToken = 0
    private var hintToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        // A hair of opacity so a fully clear preset still catches clicks
        // instead of letting them fall through to the window underneath.
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.012).cgColor

        tint.wantsLayer = true

        flashView.wantsLayer = true
        flashView.layer?.backgroundColor = NSColor.white.cgColor
        flashView.layer?.opacity = 0

        for v in [tint, flashView] {
            v.frame = bounds
            v.autoresizingMask = [.width, .height]
            addSubview(v)
        }

        pill.alphaValue = 0
        nameBubble.alphaValue = 0
        hint.alphaValue = 0
        hint.maxLines = 3
        hint.text = "To dismiss: Press ESC or double-click."
        addSubview(pill)
        addSubview(nameBubble)
        addSubview(hint)
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
        layoutHint()
    }

    // MARK: Pill + name

    func layoutPill() {
        let size = pill.fittingSize
        pill.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                            y: 8, width: size.width, height: size.height)
        layoutName()
        updatePillVisibility()
    }

    func setName(_ name: String) {
        nameBubble.text = name
        layoutName()
    }

    private func layoutName() {
        let size = nameBubble.fit(maxWidth: max(40, bounds.width - 24))
        nameBubble.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                                  y: pill.frame.maxY + 4, width: size.width, height: size.height)
    }

    func updatePillVisibility() {
        let fits = pill.frame.width + 16 <= bounds.width && bounds.height >= 70
        let show = (hovering || peeking) && fits && pill.dotCount > 1
        let showName = show && bounds.height >= 100
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = show ? 1 : 0
            nameBubble.animator().alphaValue = showName ? 1 : 0
        }
    }

    /// Briefly shows the dots + name after switching presets from the keyboard.
    func peek() {
        peekToken += 1
        let token = peekToken
        peeking = true
        updatePillVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.peekToken == token else { return }
            self.peeking = false
            self.updatePillVisibility()
        }
    }

    // MARK: Hint

    private func layoutHint() {
        let size = hint.fit(maxWidth: max(60, min(320, bounds.width - 24)))
        hint.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                            y: ((bounds.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
    }

    func showHint() {
        hintToken += 1
        let token = hintToken
        layoutHint()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            hint.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.hintToken == token else { return }
            self.hideHint(duration: 0.4)
        }
    }

    func hideHint(duration: TimeInterval = 0.15) {
        hintToken += 1
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            hint.animator().alphaValue = 0
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

/// Compact in-window preset switcher: just the dots, so its width depends only
/// on how many presets exist (capped at Preset.maxCount) and the dots never
/// shift around. The preset name lives in a separate bubble above it.
final class PresetPill: NSView {
    var onSelect: ((Int) -> Void)?
    /// Index of the dot under the cursor, or nil when the cursor leaves the dots.
    var onHover: ((Int?) -> Void)?
    private(set) var dotCount = 0

    private var dots: [PresetDot] = []

    private let dotWidth: CGFloat = 22
    private let height: CGFloat = 30
    private let pad: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.42).cgColor
        layer?.cornerRadius = height / 2
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
                d.onHover = { [weak self] inside in self?.onHover?(inside ? i : nil) }
                addSubview(d)
                return d
            }
            needsLayout = true
        }
        dotCount = presets.count
        for (d, p) in zip(dots, presets) {
            d.isActive = p.id == activeID
        }
    }

    override var fittingSize: NSSize {
        NSSize(width: pad * 2 + CGFloat(dots.count) * dotWidth, height: height)
    }

    override func layout() {
        super.layout()
        for (i, d) in dots.enumerated() {
            d.frame = NSRect(x: pad + CGFloat(i) * dotWidth, y: 0, width: dotWidth, height: height)
        }
    }
}

private final class PresetDot: NSView {
    var onClick: (() -> Void)?
    /// A click that didn't turn into a drag or resize.
    var onPlainClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
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

    override func mouseEntered(with event: NSEvent) { hovered = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { hovered = false; onHover?(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let d: CGFloat = hovered ? 15 : 13
        let r = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        let path = NSBezierPath(ovalIn: r)
        NSColor(white: 1, alpha: isActive ? 1 : (hovered ? 0.75 : 0.4)).setFill()
        path.fill()
    }
}

// MARK: - Controller

final class FilterController: NSObject, NSWindowDelegate {
    let panel: FilterPanel
    private let root: FilterRootView
    private(set) var presetID: UUID
    /// Preset shown while hovering a dot; nil when not previewing.
    private var previewID: UUID?
    private var previewRevert: DispatchWorkItem?
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

        panel.onClick = { [weak self] in self?.root.flash() }
        panel.onPlainClick = { [weak self] in self?.root.showHint() }
        panel.onDoubleClick = { [weak self] in self?.dismiss() }
        panel.onDismissKey = { [weak self] in self?.dismiss() }
        panel.onNumberKey = { [weak self] i in self?.selectPreset(at: i, peek: true) }
        panel.onCycleKey = { [weak self] step in self?.cyclePreset(step) }
        panel.isControlHit = { [weak self] point in
            guard let pill = self?.root.pill, pill.alphaValue > 0.01 else { return false }
            return pill.bounds.contains(pill.convert(point, from: nil))
        }
        root.pill.onSelect = { [weak self] i in self?.selectPreset(at: i) }
        root.pill.onHover = { [weak self] i in self?.preview(at: i) }

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

    private func selectPreset(at index: Int, peek: Bool = false) {
        let presets = Store.shared.presets
        guard presets.indices.contains(index) else { return }
        presetID = presets[index].id
        apply()
        if peek { root.peek() }
    }

    private func cyclePreset(_ step: Int) {
        let presets = Store.shared.presets
        guard presets.count > 1 else { return }
        let current = presets.firstIndex { $0.id == presetID } ?? 0
        selectPreset(at: (current + step + presets.count) % presets.count, peek: true)
    }

    /// Hovering a dot previews that preset; leaving the dots reverts. The revert
    /// is deferred a beat so sliding from one dot to the next doesn't bounce
    /// through the active preset in between.
    private func preview(at index: Int?) {
        previewRevert?.cancel()
        previewRevert = nil
        if let index {
            let presets = Store.shared.presets
            guard presets.indices.contains(index) else { return }
            previewID = presets[index].id
            apply()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.previewID = nil
                self?.apply()
            }
            previewRevert = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        }
    }

    private func apply() {
        guard !closing else { return }
        let store = Store.shared
        // A deleted preset falls back to the default.
        if !store.presets.contains(where: { $0.id == presetID }) { presetID = store.defaultID }
        if let id = previewID, !store.presets.contains(where: { $0.id == id }) { previewID = nil }
        let active = store.preset(presetID)
        let p = previewID.map { store.preset($0) } ?? active

        WindowBlur.set(panel, radius: p.blur)
        root.tint.layer?.backgroundColor = p.tint.nsColor.withAlphaComponent(CGFloat(p.tintOpacity)).cgColor

        root.pill.update(presets: store.presets, activeID: active.id)
        root.setName(p.name.isEmpty ? "Untitled" : p.name)
        root.layoutPill()
    }

}
