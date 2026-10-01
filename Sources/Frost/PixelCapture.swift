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

/// The mosaic layout: `cols`×`rows` blocks of `block` points, anchored to the
/// window's top-left. The grid overhangs the bottom/right edges rather than
/// squashing blocks, so every visible block is the same size.
struct PixelGrid: Equatable {
    var cols: Int
    var rows: Int
    var block: CGFloat
}

/// Streams a tiny capture (one pixel per block) of whatever sits under `window`,
/// excluding Frost's own windows. The consumer upscales it with nearest-neighbor
/// filtering, which is the pixelation — no per-pixel work on our side.
final class PixelCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private weak var window: NSWindow?
    private let onFrame: (CGImage, PixelGrid) -> Void
    private let queue = DispatchQueue(label: "frost.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID?
    private var starting = false
    private var wanted = false
    private var updateInFlight = false
    private var updatePending = false

    /// The grid the stream is currently configured for; read on the capture queue.
    private let gridLock = NSLock()
    private var _activeGrid: PixelGrid?
    private var activeGrid: PixelGrid? {
        get { gridLock.lock(); defer { gridLock.unlock() }; return _activeGrid }
        set { gridLock.lock(); _activeGrid = newValue; gridLock.unlock() }
    }

    var pixelSize: CGFloat = 16 {
        didSet { if oldValue != pixelSize { updateGeometry() } }
    }

    var isRunning: Bool { stream != nil || starting }

    init(window: NSWindow, onFrame: @escaping (CGImage, PixelGrid) -> Void) {
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
                guard let (config, grid) = self.makeConfig() else { return }
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                self.activeGrid = grid
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
        activeGrid = nil
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
        guard let (config, grid) = makeConfig() else { return }
        updateInFlight = true
        // Switch the expected grid up front: frames still in flight at the old
        // size get dropped instead of being stretched into the new one.
        activeGrid = grid
        stream.updateConfiguration(config) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateInFlight = false
                if self.updatePending { self.updatePending = false; self.updateGeometry() }
            }
        }
    }

    private func makeConfig() -> (SCStreamConfiguration, PixelGrid)? {
        guard let window, let screen = window.screen else { return nil }
        let f = window.frame, s = screen.frame
        let block = max(2, pixelSize)
        let grid = PixelGrid(cols: max(1, Int((f.width / block).rounded(.up))),
                             rows: max(1, Int((f.height / block).rounded(.up))),
                             block: block)
        // SCK wants display-local points with a top-left origin. The source rect
        // covers the whole grid (overhang included) so each block maps to exactly
        // one output pixel.
        let rect = CGRect(x: f.minX - s.minX, y: s.maxY - f.maxY,
                          width: CGFloat(grid.cols) * block,
                          height: CGFloat(grid.rows + Self.marginRows) * block)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = grid.cols * Self.oversample
        config.height = (grid.rows + Self.marginRows) * Self.oversample
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.preservesAspectRatio = false
        return (config, grid)
    }

    /// Captured pixels per block (each side). 2× lets every block average four
    /// real samples instead of trusting SCK's scaler for a single pixel.
    private static let oversample = 2
    /// SCK intermittently fills the last row or two of a frame with junk (shows
    /// up as purple/flicker along the bottom), so capture a little extra below
    /// the window and throw it away.
    private static let marginRows = 2

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let grid = activeGrid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let raw = info[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let k = Self.oversample
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        // Frames from before a resize can still be in flight; drop anything
        // that isn't exactly the size the current grid asked for.
        guard w == grid.cols * k, h == (grid.rows + Self.marginRows) * k else { return }
        // CIImage is bottom-left origin: the margin rows sit at y = 0..<margin*k.
        let content = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: CGRect(x: 0, y: Self.marginRows * k, width: grid.cols * k, height: grid.rows * k))
            .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(-Self.marginRows * k)))
        // Exact 2× box downsample: linear sampling at each destination pixel
        // center lands between four source pixels and averages them.
        let small = content.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: 1 / CGFloat(k), y: 1 / CGFloat(k)))
        guard let cg = ciContext.createCGImage(small, from: CGRect(x: 0, y: 0, width: grid.cols, height: grid.rows)) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeGrid == grid else { return }
            self.onFrame(cg, grid)
        }
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

