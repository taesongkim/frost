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

