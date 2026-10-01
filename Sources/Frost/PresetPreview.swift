import AppKit
import SwiftUI

/// Live preview for the Settings window: sample content with a real Frost pane
/// on top. The pane is a borderless child window over this view's rect, so the
/// WindowServer blurs the actual sample content — same blur as a real filter.
struct PresetPreview: View {
    let preset: Preset

    var body: some View {
        ZStack {
            SampleContent()
            // The pane covers only the right half: plain on the left, preset on
            // the right, so the effect reads against the original.
            HStack(spacing: 0) {
                Color.clear
                PreviewPane(preset: preset)
            }
            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(width: 1)
        }
        .frame(height: 120)
        .clipped()
        .overlay(Rectangle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

private struct SampleContent: View {
    private static let sentence = "The quick brown fox jumps over the lazy dog. Sphinx of black quartz, judge my vow."

    var body: some View {
        VStack(spacing: 0) {
            band(text: .black, background: .white)
            band(text: .white, background: .black)
        }
    }

    private func band(text: Color, background: Color) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(background)
            Text(Self.sentence + " " + Self.sentence)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(text)
                .lineLimit(2)
                .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreviewPane: NSViewRepresentable {
    let preset: Preset

    func makeNSView(context: Context) -> PreviewPaneHost { PreviewPaneHost() }
    func updateNSView(_ view: PreviewPaneHost, context: Context) { view.preset = preset }
}

final class PreviewPaneHost: NSView {
    var preset: Preset? { didSet { applyPreset() } }

    private let pane: NSPanel
    private let tint = NSView()
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        pane = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        super.init(frame: frame)
        pane.isOpaque = false
        pane.backgroundColor = .clear
        pane.hasShadow = false
        pane.ignoresMouseEvents = true
        pane.isReleasedWhenClosed = false
        pane.hidesOnDeactivate = false
        pane.animationBehavior = .none
        let content = NSView()
        content.wantsLayer = true
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        content.addSubview(tint)
        pane.contentView = content
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { detach() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        detach()
        guard let window else { return }
        parent = window
        window.addChildWindow(pane, ordered: .above)
        // Child windows outlive a closed parent's view tree otherwise.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.detach() })
        reposition()
        applyPreset()
    }

    override func layout() {
        super.layout()
        reposition()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        reposition()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reposition()
    }

    private func reposition() {
        guard let window, window === parent else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        pane.setFrame(rect, display: true)
        tint.frame = pane.contentView?.bounds ?? .zero
    }

    private func applyPreset() {
        guard let preset else { return }
        WindowBlur.set(pane, radius: preset.blur)
        tint.layer?.backgroundColor = preset.tint.nsColor
            .withAlphaComponent(CGFloat(preset.tintOpacity)).cgColor
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        parent?.removeChildWindow(pane)
        pane.orderOut(nil)
        parent = nil
    }
}
