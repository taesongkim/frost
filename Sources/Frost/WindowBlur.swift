import AppKit

/// Variable Gaussian blur of whatever is behind a window, done by the
/// WindowServer. This is private API (it's what NSVisualEffectView uses under
/// the hood, minus the fixed radius and material tint) — looked up at runtime
/// so a future macOS that drops it degrades to "no blur" instead of crashing.
enum WindowBlur {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetBlurFn = @convention(c) (Int32, Int32, Int32) -> Int32

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

    private static func symbol<T>(_ names: String...) -> T? {
        for name in names {
            if let p = dlsym(rtldDefault, name) { return unsafeBitCast(p, to: T.self) }
        }
        return nil
    }

    private static let mainConnection: ConnectionFn? =
        symbol("CGSMainConnectionID", "SLSMainConnectionID")
    private static let setBlurRadius: SetBlurFn? =
        symbol("CGSSetWindowBackgroundBlurRadius", "SLSSetWindowBackgroundBlurRadius")

    static var isAvailable: Bool { mainConnection != nil && setBlurRadius != nil }

    static func set(_ window: NSWindow, radius: Double) {
        guard let mainConnection, let setBlurRadius, window.windowNumber > 0 else { return }
        _ = setBlurRadius(mainConnection(), Int32(window.windowNumber), Int32(radius.rounded()))
    }
}


/// Background apps normally can't change the cursor — the frontmost app owns
/// it — and Frost is never frontmost. This private connection property lets
/// the resize cursors show anyway.
enum BackgroundCursor {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    static func enable() {
        let h = UnsafeMutableRawPointer(bitPattern: -2)
        guard let c = dlsym(h, "CGSMainConnectionID") ?? dlsym(h, "SLSMainConnectionID"),
              let s = dlsym(h, "CGSSetConnectionProperty") ?? dlsym(h, "SLSSetConnectionProperty") else { return }
        let conn = unsafeBitCast(c, to: ConnectionFn.self)()
        _ = unsafeBitCast(s, to: SetPropertyFn.self)(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
