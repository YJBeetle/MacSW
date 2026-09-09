import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = MainView(state: appState)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        window.title = "SolidWorks 2025 (MacSW)"
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
