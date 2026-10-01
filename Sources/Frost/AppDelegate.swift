import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var filters: [FilterController] = []
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var newFilterItem: NSMenuItem!
    private var closeAllItem: NSMenuItem!

    static let defaultSize = NSSize(width: 640, height: 420)

    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundCursor.enable()
        setUpStatusItem()

        HotKey.shared.handler = { [weak self] in self?.newFilter() }
        Store.shared.$hotKey
            .sink { [weak self] combo in
                HotKey.shared.register(combo)
                self?.updateMenuShortcut(combo)
            }
            .store(in: &cancellables)
    }

    /// frost://new — summon a filter (Raycast, Shortcuts, scripts).
    /// frost://close-all — dismiss every filter.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "frost" {
            switch url.host {
            case "new": newFilter()
            case "close-all": closeAll()
            case "settings": openSettings()
            default: break
            }
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.filters", accessibilityDescription: "Frost")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        newFilterItem = NSMenuItem(title: "New Filter", action: #selector(newFilterFromMenu), keyEquivalent: "")
        closeAllItem = NSMenuItem(title: "Close All Filters", action: #selector(closeAll), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quit = NSMenuItem(title: "Quit Frost", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in [newFilterItem!, closeAllItem!, settings] { item.target = self }
        menu.items = [newFilterItem, closeAllItem, .separator(), settings, .separator(), quit]
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        closeAllItem.isEnabled = !filters.isEmpty
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item == closeAllItem ? !filters.isEmpty : true
    }

    /// Mirrors the global shortcut on the menu item as a hint (only when it's a
    /// plain printable key — menus can't render arbitrary combos).
    private func updateMenuShortcut(_ combo: KeyCombo) {
        guard let item = newFilterItem else { return }
        let key = String(combo.display.drop { "⌃⌥⇧⌘".contains($0) })
        if key.count == 1 {
            item.keyEquivalent = key.lowercased()
            item.keyEquivalentModifierMask = combo.flags.intersection([.command, .shift, .option, .control])
        } else {
            item.keyEquivalent = ""
        }
    }

    // MARK: Filters

    @objc private func newFilterFromMenu() { newFilter() }

    func newFilter() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let size = NSSize(width: min(Self.defaultSize.width, visible.width - 40),
                          height: min(Self.defaultSize.height, visible.height - 40))
        var origin = NSPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.midY - size.height / 2).rounded())
        // Cascade so a second summon doesn't land exactly on top of the first.
        let taken = Set(filters.map { "\(Int($0.panel.frame.minX)),\(Int($0.panel.frame.minY))" })
        var steps = 0
        while taken.contains("\(Int(origin.x)),\(Int(origin.y))"), steps < 20 {
            origin.x += 24; origin.y -= 24; steps += 1
        }

        let controller = FilterController(frame: NSRect(origin: origin, size: size),
                                          presetID: Store.shared.defaultID) { [weak self] closed in
            self?.filters.removeAll { $0 === closed }
        }
        filters.append(controller)
        controller.show()
    }

    @objc private func closeAll() {
        filters.forEach { $0.dismiss() }
    }

    // MARK: Settings

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(Store.shared))
            let window = NSWindow(contentViewController: host)
            window.title = "Frost Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 560, height: 600))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Don't drop the cursor into the first text field on open.
        DispatchQueue.main.async { self.settingsWindow?.makeFirstResponder(nil) }
    }

    // Rebuild Settings fresh each time so its preview pane re-attaches cleanly.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        DispatchQueue.main.async { self.settingsWindow = nil }
    }
}
