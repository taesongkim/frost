# Frost

A tiny macOS menu bar app that puts a frosted-glass pane over anything on your screen.

Press **⇧⌘/** and a filter window appears in the middle of the screen your cursor is on. It floats above everything else. Drag it anywhere, resize it from any edge, and dismiss it with a double-click (or click it, then press Esc or ⌘W). Press the shortcut again for another one.

## Presets

You get up to five presets, starting with Cover and Focus. Each one sets:

- **Blur**: a Gaussian blur radius from 0 (clear) to 80.
- **Tint**: a color wash with its own opacity. Good for dimming a distraction.

Hover over a filter to switch presets with the dots at the bottom (hovering a dot previews it), or click the filter and press Tab, Shift-Tab, or 1–5.

The variable blur uses a private WindowServer call (`CGSSetWindowBackgroundBlurRadius`). That's why Frost can never be on the App Store, and it could break in a future macOS. If it does, the blur just won't show up; the app won't crash.

## Scripting

- `open frost://new` opens a filter
- `open frost://close-all` closes all filters
- `open frost://settings` opens Settings

## Building

Requires Xcode 15+ (Swift 5.9+). No Xcode project; it's a Swift package plus a bundling script.

```sh
swift run                      # quick run (no bundle; hotkey + menu bar still work)
scripts/build.sh --dev         # signed dist/Frost.app
scripts/build.sh               # signed + notarized dist/Frost-<version>.dmg
swift scripts/make-icon.swift  # regenerate the icon set (then iconutil)
```

`build.sh` signs with `$SIGNING_IDENTITY` and notarizes with the App Store Connect API key variables in `$FROST_NOTARIZE_ENV`. If you're building it yourself, point both at your own credentials.

## License

MIT
