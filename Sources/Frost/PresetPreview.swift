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
            PreviewPane(preset: preset)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct SampleContent: View {
    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.orange).frame(width: 70).offset(x: -18, y: -14)
                Circle().fill(Color.pink).frame(width: 60).offset(x: 20, y: 16)
                Circle().fill(Color.blue).frame(width: 44).offset(x: 26, y: -24)
            }
            .frame(width: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text("Quarterly Notes").font(.system(size: 17, weight: .semibold))
                Text("The quick brown fox jumps over the lazy dog. Meeting moved to 3:30 — bring the draft and the numbers from last week.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
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
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
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
