import AppKit
import Combine

// MARK: - Panel

struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let bottom = ResizeEdges(rawValue: 1 << 2)
    static let top = ResizeEdges(rawValue: 1 << 3)
}

/// Borderless, square-cornered pane. (The WindowServer blur fills the window's
/// full rectangle, so a titled window's rounded corners left blur wedges
/// poking out.) Borderless windows don't get system edge-resizing, so the
/// panel does its own. Non-activating, so summoning it never steals focus.
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
    /// After a move/resize drag: hover state may be stale (the tracking loop
    /// swallows enter/exit events), so the content needs to re-sync.
    var onTrackingEnded: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Moving is handled in sendEvent. AppKit's background-drag starts at the
        // WindowServer level on mouse-down, so it would also move the window
        // while we're resizing from a corner.
        isMovableByWindowBackground = false
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

    // MARK: Resizing

    static let edgeZone: CGFloat = 10
    static let cornerZone: CGFloat = 16

    /// Which edges a point (window coords) would grab, if any.
    func resizeEdges(at p: NSPoint) -> ResizeEdges {
        let w = frame.width, h = frame.height
        guard p.x >= 0, p.y >= 0, p.x <= w, p.y <= h else { return [] }
        let nearL = p.x < Self.cornerZone, nearR = p.x > w - Self.cornerZone
        let nearB = p.y < Self.cornerZone, nearT = p.y > h - Self.cornerZone
        let onL = p.x < Self.edgeZone, onR = p.x > w - Self.edgeZone
        let onB = p.y < Self.edgeZone, onT = p.y > h - Self.edgeZone
        var e: ResizeEdges = []
        if onL || (nearL && (onB || onT)) { e.insert(.left) }
        if onR || (nearR && (onB || onT)) { e.insert(.right) }
        if onB || (nearB && (onL || onR)) { e.insert(.bottom) }
        if onT || (nearT && (onL || onR)) { e.insert(.top) }
        return e
    }

    static func cursor(for edges: ResizeEdges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition
            switch edges {
            case [.top, .left]: pos = .topLeft
            case [.top, .right]: pos = .topRight
            case [.bottom, .left]: pos = .bottomLeft
            case [.bottom, .right]: pos = .bottomRight
            case .top: pos = .top
            case .bottom: pos = .bottom
            case .left: pos = .left
            default: pos = .right
            }
            return .frameResize(position: pos, directions: .all)
        }
        return edges.contains(.left) || edges.contains(.right) ? .resizeLeftRight : .resizeUpDown
    }

    private func trackResize(_ edges: ResizeEdges) {
        let startMouse = NSEvent.mouseLocation
        let start = frame.integral
        let cursor = Self.cursor(for: edges)
        while let e = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type != .leftMouseUp {
            cursor.set()
            let m = NSEvent.mouseLocation
            // Whole-point deltas keep the opposite (anchored) edges exactly put.
            let dx = (m.x - startMouse.x).rounded(), dy = (m.y - startMouse.y).rounded()
            var f = start
            if edges.contains(.left) {
                f.size.width = max(minSize.width, start.width - dx)
                f.origin.x = start.maxX - f.width
            } else if edges.contains(.right) {
                f.size.width = max(minSize.width, start.width + dx)
            }
            if edges.contains(.bottom) {
                f.size.height = max(minSize.height, start.height - dy)
                f.origin.y = start.maxY - f.height
            } else if edges.contains(.top) {
                f.size.height = max(minSize.height, start.height + dy)
            }
            setFrame(f, display: true)
        }
        onTrackingEnded?()
    }

    /// Moves the window with the mouse. Returns true if it moved at all (i.e.
    /// this was a drag, not a click).
    private func trackMove() -> Bool {
        let startMouse = NSEvent.mouseLocation
        let start = frame.origin
        var moved = false
        while let e = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type != .leftMouseUp {
            let m = NSEvent.mouseLocation
            let dx = (m.x - startMouse.x).rounded(), dy = (m.y - startMouse.y).rounded()
            if !moved && abs(dx) < 3 && abs(dy) < 3 { continue }
            moved = true
            setFrameOrigin(NSPoint(x: start.x + dx, y: start.y + dy))
        }
        if moved { onTrackingEnded?() }
        return moved
    }

    // MARK: Events

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where !(isControlHit?(event.locationInWindow) ?? false):
            let edges = resizeEdges(at: event.locationInWindow)
            if !edges.isEmpty, event.clickCount == 1 {
                makeKey()
                trackResize(edges)
                return
            }
            if event.clickCount >= 2 {
                onDoubleClick?()
                return
            }
            // Still give AppKit the mouse-down so the panel becomes key (Esc/Tab).
            super.sendEvent(event)
            onClick?()
            if !trackMove() { onPlainClick?() }
            return
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

/// White text with a soft shadow (no background), sized to fit. Clicks pass to
/// the window as if it weren't there, so it can still be dragged by it.
final class Bubble: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let padX: CGFloat, padY: CGFloat

    init(fontSize: CGFloat, padX: CGFloat, padY: CGFloat, radius: CGFloat?) {
        self.padX = padX
        self.padY = padY
        super.init(frame: .zero)
        wantsLayer = true
        // The shadow keeps white text readable over light content.
        let glow = NSShadow()
        glow.shadowColor = NSColor(white: 0, alpha: 0.55)
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        label.shadow = glow
        label.font = .systemFont(ofSize: fontSize, weight: .semibold)
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
    let closeButton = CloseButton()
    let grip = ResizeGripView()
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
        // Hairline so the pane's edge reads even at low blur.
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor

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
        closeButton.alphaValue = 0
        nameBubble.alphaValue = 0
        hint.alphaValue = 0
        hint.maxLines = 3
        hint.text = "To dismiss: Press ESC or double-click."
        grip.frame = bounds
        grip.autoresizingMask = [.width, .height]
        addSubview(grip)
        addSubview(pill)
        addSubview(closeButton)
        addSubview(nameBubble)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updatePillVisibility() }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        updatePillVisibility()
        grip.show([])
        NSCursor.arrow.set()
    }

    /// Cursor + grip dots for whatever resize zone (if any) is under `p`.
    private func updateResizeAffordance(at p: NSPoint) {
        guard let panel = window as? FilterPanel else { return }
        let local = convert(p, from: nil)
        let overButton = [closeButton, pill].contains { $0.alphaValue > 0.01 && $0.frame.contains(local) }
        let edges = overButton ? [] : panel.resizeEdges(at: p)
        if overButton {
            NSCursor.pointingHand.set()
        } else {
            (edges.isEmpty ? NSCursor.arrow : FilterPanel.cursor(for: edges)).set()
        }
        grip.show(edges)
    }

    /// Re-derives hover from where the mouse actually is. Needed after a
    /// move/resize: the drag loop eats the mouse-exited event, so the dots and
    /// close button would otherwise stay up after you let go outside.
    func syncHover() {
        guard let window else { return }
        let inside = window.frame.contains(NSEvent.mouseLocation)
        if inside != hovering {
            hovering = inside
            updatePillVisibility()
        }
        if inside {
            updateResizeAffordance(at: window.mouseLocationOutsideOfEventStream)
        } else {
            grip.show([])
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeAffordance(at: event.locationInWindow)
    }

    override func layout() {
        super.layout()
        layoutPill()
        layoutHint()
    }

    // MARK: Pill + name

    private func layoutCloseButton() {
        let size = CloseButton.size
        closeButton.frame = NSRect(x: 12, y: bounds.height - 12 - size, width: size, height: size)
    }

    func layoutPill() {
        layoutCloseButton()
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
        let showClose = hovering && bounds.width >= 60 && bounds.height >= 50
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().alphaValue = show ? 1 : 0
            nameBubble.animator().alphaValue = showName ? 1 : 0
            closeButton.animator().alphaValue = showClose ? 1 : 0
        }
    }

    /// Briefly shows the dots + name after switching presets from the keyboard.
    func peek() {
        peekToken += 1
        let token = peekToken
        peeking = true
        updatePillVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
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

// MARK: - Close button

final class CloseButton: NSView {
    static let size: CGFloat = 20
    var onClick: (() -> Void)?

    private let background = CALayer()
    private let glyph = CAShapeLayer()
    private var hovered = false { didSet { updateLook() } }
    private var pressed = false { didSet { updateLook() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        background.opacity = 0
        layer?.addSublayer(background)
        glyph.strokeColor = NSColor.white.cgColor
        glyph.fillColor = nil
        glyph.lineWidth = 1.6
        glyph.lineCap = .round
        // No background at rest, so the × carries its own shadow for contrast.
        glyph.shadowColor = NSColor.black.cgColor
        glyph.shadowOpacity = 0.55
        glyph.shadowRadius = 2
        glyph.shadowOffset = .zero
        layer?.addSublayer(glyph)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        background.frame = bounds
        background.cornerRadius = bounds.width / 2
        glyph.frame = bounds
        let inset: CGFloat = 6.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: inset, y: inset))
        path.addLine(to: CGPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: CGPoint(x: inset, y: bounds.height - inset))
        path.addLine(to: CGPoint(x: bounds.width - inset, y: inset))
        glyph.path = path
        CATransaction.commit()
    }

    private func updateLook() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        background.opacity = pressed ? 1 : (hovered ? 0.8 : 0)
        glyph.shadowOpacity = hovered ? 0 : 0.55
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }
}

// MARK: - Resize grip hint

/// Dotted marks that fade in over whichever resize zone the cursor is on:
/// a dotted line along an edge, a small triangle of dots in a corner.
final class ResizeGripView: NSView {
    private let edgeDots = CAShapeLayer()
    private let cornerDots = CAShapeLayer()
    private(set) var edges: ResizeEdges = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [edgeDots, cornerDots] {
            l.opacity = 0
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0
            l.shadowRadius = 1.5
            l.shadowOffset = .zero
            layer?.addSublayer(l)
        }
        edgeDots.fillColor = NSColor(white: 1, alpha: 0.3).cgColor
        cornerDots.fillColor = NSColor(white: 1, alpha: 0.3).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ new: ResizeEdges) {
        guard new != edges else { return }
        edges = new
        rebuildPaths()
        let isCorner = new.rawValue.nonzeroBitCount == 2
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        edgeDots.opacity = !new.isEmpty && !isCorner ? 1 : 0
        cornerDots.opacity = isCorner ? 1 : 0
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        rebuildPaths()
    }

    // Autoresizing during a live resize doesn't always trigger layout().
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildPaths()
    }

    private func rebuildPaths() {
        guard !edges.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let w = bounds.width, h = bounds.height
        let inset: CGFloat = 4 // corner dots' margin from the edges
        let span = FilterPanel.cornerZone

        if edges.rawValue.nonzeroBitCount == 2 {
            // Corner: a 3-2-1 triangle of dots tucked into the corner.
            let path = CGMutablePath()
            let step: CGFloat = 4.5, r: CGFloat = 1.1
            let sx: CGFloat = edges.contains(.left) ? 1 : -1
            let sy: CGFloat = edges.contains(.bottom) ? 1 : -1
            let ox = edges.contains(.left) ? inset : w - inset
            let oy = edges.contains(.bottom) ? inset : h - inset
            for i in 0..<3 {
                for j in 0..<(3 - i) {
                    let c = CGPoint(x: ox + sx * CGFloat(i) * step, y: oy + sy * CGFloat(j) * step)
                    path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                }
            }
            cornerDots.path = path
        } else {
            // Edge: two staggered rows of small dots running along the edge.
            let path = CGMutablePath()
            let step: CGFloat = 4.5, r: CGFloat = 0.7, gap: CGFloat = 1.6
            let vertical = edges.contains(.left) || edges.contains(.right)
            let length = (vertical ? h : w) - span * 2
            // Rows sit at ~6pt and ~9pt in, inside the 10pt grab zone.
            let edgeInset: CGFloat = 6
            let center = vertical ? (edges.contains(.left) ? edgeInset + gap : w - edgeInset - gap)
                                  : (edges.contains(.bottom) ? edgeInset + gap : h - edgeInset - gap)
            for (row, offset) in [(0, -gap), (1, gap)] {
                var t = CGFloat(row) * step / 2
                while t <= length {
                    let along = span + t, across = center + offset
                    let c = vertical ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
                    path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    t += step
                }
            }
            edgeDots.path = path
        }
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

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        NSCursor.pointingHand.set()
        onHover?(true)
    }
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
            guard let root = self?.root else { return false }
            return [root.pill, root.closeButton].contains { v in
                v.alphaValue > 0.01 && v.bounds.contains(v.convert(point, from: nil))
            }
        }
        root.closeButton.onClick = { [weak self] in self?.dismiss() }
        panel.onTrackingEnded = { [weak self] in self?.root.syncHover() }
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
        // Key on arrival (Esc, Tab, 1–5 work immediately) without activating
        // the app — it's a non-activating panel, like Spotlight.
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        root.showHint()
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
