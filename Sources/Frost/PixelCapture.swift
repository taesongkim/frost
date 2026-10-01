import AppKit
import CoreImage
import ScreenCaptureKit

enum ScreenPermission {
    private static var askedThisLaunch = false

    static var granted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt at most once per launch. macOS only shows it the
    /// very first time anyway; after that the user has to flip it in Settings.
    static func requestIfNeeded() {
        guard !granted, !askedThisLaunch else { return }
        askedThisLaunch = true
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Streams a tiny, downscaled capture of whatever sits under `window` (excluding
/// Frost's own windows). The consumer upscales it with nearest-neighbor filtering,
/// which is the pixelation — no per-pixel work on our side.
final class PixelCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var window: NSWindow?
    private let onFrame: (CGImage) -> Void
    private let queue = DispatchQueue(label: "frost.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID?
    private var starting = false
    private var wanted = false
    private var updateInFlight = false
    private var updatePending = false

    var pixelSize: CGFloat = 16 {
        didSet { if oldValue != pixelSize { updateGeometry() } }
    }

    var isRunning: Bool { stream != nil || starting }

    init(window: NSWindow, onFrame: @escaping (CGImage) -> Void) {
        self.window = window
        self.onFrame = onFrame
    }

    func start() {
        wanted = true
        guard !isRunning, ScreenPermission.granted, let screen = window?.screen else { return }
        starting = true
        let targetID = screen.displayID
        Task { @MainActor in
            defer { self.starting = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == targetID }) else { return }
                let me = content.applications.filter { $0.processID == getpid() }
                let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
                guard let config = self.makeConfig() else { return }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                guard self.wanted else { try? await stream.stopCapture(); return }
                self.stream = stream
                self.displayID = targetID
            } catch {
                NSLog("Frost: capture failed to start: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        wanted = false
        guard let stream else { return }
        self.stream = nil
        displayID = nil
        Task { try? await stream.stopCapture() }
    }

    /// Call on move/resize. Coalesces so a live drag doesn't pile up reconfigures.
    func updateGeometry() {
        guard let stream else { return }
        if window?.screen?.displayID != displayID {
            stop(); start()
            return
        }
        if updateInFlight { updatePending = true; return }
        guard let config = makeConfig() else { return }
        updateInFlight = true
        stream.updateConfiguration(config) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateInFlight = false
                if self.updatePending { self.updatePending = false; self.updateGeometry() }
            }
        }
    }

    private func makeConfig() -> SCStreamConfiguration? {
        guard let window, let screen = window.screen else { return nil }
        let f = window.frame, s = screen.frame
        // SCK wants display-local points with a top-left origin.
        let rect = CGRect(x: f.minX - s.minX, y: s.maxY - f.maxY, width: f.width, height: f.height)
        let block = max(2, pixelSize)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = max(1, Int((rect.width / block).rounded(.up)))
        config.height = max(1, Int((rect.height / block).rounded(.up)))
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        if #available(macOS 14.0, *) { config.preservesAspectRatio = false }
        return config
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return }
        DispatchQueue.main.async { [weak self] in self?.onFrame(cg) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.displayID = nil
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
