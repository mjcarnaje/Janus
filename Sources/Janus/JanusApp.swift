import AppKit
import SwiftUI
import JanusCore

@main
struct JanusApp: App {

    // The widget in the menu bar is the main surface, and the window sits behind
    // its Manage tile. Both are AppKit's, so they live in the controller.
    @NSApplicationDelegateAdaptor(PanelController.self) private var panel

    var body: some Scene {
        // SwiftUI needs a scene. This one never opens; it is here so the app
        // keeps SwiftUI's main menu, which the window's shortcuts go through.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .appInfo) {
                    Button("About Janus") { AboutPanel.show() }
                }
            }
    }
}

/// The standard About panel, filled in from the bundle so the version shown is
/// always the version running.
enum AboutPanel {
    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: Build.version,
            .init(rawValue: "Copyright"): "MIT licensed. github.com/RamitVishwakarma/Janus"
        ])
    }
}
