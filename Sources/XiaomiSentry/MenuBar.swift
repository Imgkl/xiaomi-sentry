import AppKit
import Combine
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app has no windows most of the time; stop macOS from ending it as idle.
        ProcessInfo.processInfo.disableAutomaticTermination("Menu bar camera viewer")
        LoginItem.enableOnFirstLaunch()
        menuBar = MenuBarController(model: model)
        model.start()
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the panel.
    /// This also works when the menu bar hides the icon, for example behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.show()
        return false
    }
}

/// Starts the app at login through SMAppService. Turned on once at first launch; the menu toggles it.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static func enableOnFirstLaunch() {
        let key = "loginItemSetUp"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    static func toggle() {
        switch status {
        case .enabled: try? SMAppService.mainApp.unregister()
        case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
        default: try? SMAppService.mainApp.register()
        }
    }
}

/// Borderless, transparent panel so the Handheld body keeps its own shape.
/// The window server draws the shadow from the body's rounded outline, like system panels.
final class FloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A menu bar only app has no Edit menu, which is what normally turns ⌘V, ⌘C, ⌘X, ⌘A
    /// and ⌘Z into actions. Send those actions to the focused field ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch (event.charactersIgnoringModifiers?.lowercased(), flags.contains(.shift)) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Status item: left click toggles the panel, right click opens a small menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: FloatingPanel
    private var keyMonitor: Any?
    private var layoutSubscription: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        let host = NSHostingView(rootView: PanelRoot().environmentObject(model))
        // The panel size comes from model.layout; the hosting view must not drive it.
        host.sizingOptions = []
        panel = FloatingPanel(content: host)
        super.init()
        applyAppearance()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "web.camera", accessibilityDescription: "Cameras")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.requestOpen = { [weak self] in self?.show() }
        layoutSubscription = model.$layout.sink { [weak self] layout in
            self?.resizePanel(to: layout.size)
        }
        // A held arrow key never gets its key-up once the panel loses focus, so stop the hold here.
        NotificationCenter.default.addObserver(self, selector: #selector(panelResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
    }

    @objc private func panelResignedKey() { model.endHold() }

    @objc private func panelMoved() {
        AppSettings.panelTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // Already open: just bring it forward; adding the key monitor again would leak it.
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let size = model.layout.size
        panel.setFrame(NSRect(origin: savedOrigin(for: size) ?? firstPlacement(for: size), size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        // SwiftUI draws after the window is ordered in; rebuild the shadow from the drawn outline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.panel.invalidateShadow() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        model.panelDidOpen()
    }

    /// The remembered spot, clamped so the whole window is on the screen it overlaps.
    /// Nil when nothing is saved or that spot is no longer on any connected screen.
    private func savedOrigin(for size: CGSize) -> NSPoint? {
        guard let topLeft = AppSettings.panelTopLeft else { return nil }
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard let visible = NSScreen.screens.map(\.visibleFrame).first(where: { $0.intersects(frame) }) else { return nil }
        return NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - size.width),
                       y: min(max(frame.minY, visible.minY), visible.maxY - size.height))
    }

    /// On macOS 27 the status item's own window can be a 0x0 placeholder, so its frame
    /// is not a safe anchor. Use the pointer (it is on the icon after a click) and the
    /// screen it is on. The menu bar is the gap above that screen's visible frame.
    private func firstPlacement(for size: CGSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let x = min(max(mouse.x - size.width / 2, visible.minX + 6), visible.maxX - size.width - 6)
        return NSPoint(x: x, y: visible.maxY - 6 - size.height)
    }

    /// Keeps the top-left corner fixed so the panel grows down and to the right from under the menu bar.
    private func resizePanel(to size: CGSize) {
        guard panel.isVisible else { return }
        let old = panel.frame
        let maxX = (panel.screen ?? NSScreen.main)?.visibleFrame.maxX ?? .infinity
        let x = min(old.minX, maxX - 6 - size.width)
        panel.setFrame(NSRect(x: x, y: old.maxY - size.height, width: size.width, height: size.height), display: false)
        // Lay out and draw the content in the same pass as the frame change, or the drag shows
        // a frame where the content still has the previous size: clipped or empty edges.
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        // The system shadow follows the drawn outline, so rebuild it once SwiftUI has drawn the new size.
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.panelDidClose()
    }

    /// Arrow keys pan and tilt while held, Escape closes. Text fields in setup keep their arrows.
    private func handleKey(_ event: NSEvent) -> Bool {
        let arrows: [UInt16: Int] = [123: 1, 124: 2, 126: 3, 125: 4]
        if event.type == .keyUp {
            guard arrows[event.keyCode] != nil, !(panel.firstResponder is NSText), !model.showingSetup else { return false }
            model.endHold()
            return true
        }
        if event.keyCode == 53 { // Escape
            hide()
            return true
        }
        if panel.firstResponder is NSText || model.showingSetup { return false }
        // Number keys 1 to 9 pick a camera.
        if let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit),
           digit <= model.cameras.count {
            model.select(digit - 1)
            return true
        }
        guard let operation = arrows[event.keyCode] else { return false }
        // Key repeat events are swallowed: the hold itself keeps the camera stepping.
        if !event.isARepeat { model.beginHold(operation) }
        return true
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Reconnect", action: #selector(reconnect), keyEquivalent: "r").target = self
        if model.cameras.count > 1 {
            for (index, camera) in model.cameras.enumerated() {
                let item = menu.addItem(withTitle: camera.name, action: #selector(chooseCamera(_:)),
                                        keyEquivalent: index < 9 ? String(index + 1) : "")
                item.target = self
                item.tag = index
                item.state = index == model.selected ? .on : .off
            }
            menu.addItem(.separator())
        }
        let appearance = NSMenu()
        for choice in AppSettings.Appearance.allCases {
            let item = appearance.addItem(withTitle: choice.title, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = choice == AppSettings.appearance ? .on : .off
        }
        menu.addItem(withTitle: "Appearance", action: nil, keyEquivalent: "").submenu = appearance
        let login = menu.addItem(withTitle: LoginItem.status == .requiresApproval
                                    ? "Open at Login (approve in System Settings)" : "Open at Login",
                                 action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func openSettings() { model.openSetup() }

    @objc private func toggleLoginItem() { LoginItem.toggle() }

    @objc private func chooseCamera(_ sender: NSMenuItem) {
        model.select(sender.tag)
        show()
    }

    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let choice = AppSettings.Appearance(rawValue: raw) else { return }
        AppSettings.appearance = choice
        applyAppearance()
        show()
    }

    /// The light body is the default. The screen stays dark in both themes.
    private func applyAppearance() {
        switch AppSettings.appearance {
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        case .system: panel.appearance = nil
        }
    }

    @objc private func reconnect() {
        model.reconnect()
        show()
    }
}
