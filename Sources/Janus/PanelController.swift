import AppKit
import Combine
import SwiftUI
import JanusCore

/// Owns everything on screen: the status item, the widget it opens, and the
/// window behind the widget's Manage tile.
///
/// The widget is an `NSPopover` rather than a SwiftUI `MenuBarExtra`, for two
/// things the extra cannot do: draw the arrow back to the status item, and be
/// closed by the app when a tile hands off to the window.
@MainActor
final class PanelController: NSObject, NSApplicationDelegate {

    let accounts = AccountsModel()
    let codex = CodexModel()
    let caches = CachesModel()
    let router = ManageRouter()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var window: NSWindow?
    private var subscriptions: Set<AnyCancellable> = []

    /// When the popover last closed. A click on the status item while the
    /// popover is open closes it on mouse-down, as a click outside a transient
    /// popover does, and then the button's action arrives on mouse-up and would
    /// open it straight back up.
    private var closedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon until the window is open. Info.plist says so too; saying
        // it here as well keeps `swift run` behaving like the built app.
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle",
                                   accessibilityDescription: "Janus")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item

        let content = NSHostingController(rootView: WidgetView(
            accounts: accounts, codex: codex, caches: caches,
            manage: { [weak self] section in self?.showWindow(at: section) }))
        // The popover follows the widget's own size, which changes as accounts
        // are saved and messages come and go.
        content.sizingOptions = .preferredContentSize
        popover.contentViewController = content
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // The status item's title is the Claude Code account in use, as it
        // always has been. objectWillChange fires before the change lands, so
        // the title is read on the next turn of the run loop.
        accounts.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitle() } }
            .store(in: &subscriptions)
        updateTitle()

        caches.scan()
    }

    /// Opening Janus again from Finder or Spotlight opens the window, since there
    /// is no Dock icon to click instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(at: router.section)
        return false
    }

    private func updateTitle() {
        let name = accounts.active?.shortName ?? ""
        statusItem?.button?.title = name.isEmpty ? "" : " " + name
    }

    // MARK: - The widget

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard Date().timeIntervalSince(closedAt) > 0.25 else { return }

        accounts.reload()
        codex.reload()

        // The app has to be active for the widget's shortcuts to reach it.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - The window

    func showWindow(at section: MainWindow.Section) {
        popover.performClose(nil)
        router.section = section

        let window = self.window ?? makeWindow()
        self.window = window

        // A Dock icon while the window is open, so it can be found again with
        // ⌘-Tab, and so it has a menu bar for its own shortcuts.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: MainWindow(
            accounts: accounts, codex: codex, caches: caches, router: router))
        let window = NSWindow(contentViewController: content)
        window.title = "Janus"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 600))
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("Janus.manage")
        window.delegate = self
        return window
    }
}

extension PanelController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        closedAt = Date()
    }
}

extension PanelController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
