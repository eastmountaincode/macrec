import SwiftUI
import AppKit

@MainActor
private final class MacRecApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        scheduleControlWindowCheck(after: 0.4, allowManualFallback: false)
        scheduleControlWindowCheck(after: 1.5, allowManualFallback: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        scheduleControlWindowCheck(after: 0, allowManualFallback: true)
        return true
    }

    private func scheduleControlWindowCheck(after delay: TimeInterval, allowManualFallback: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.ensureControlWindowIsVisible(allowManualFallback: allowManualFallback)
        }
    }

    private static func ensureControlWindowIsVisible(allowManualFallback: Bool) {
        let newWindowItem = NSApp.mainMenu?
            .item(withTitle: "File")?
            .submenu?
            .items
            .first(where: { $0.title == "New MacRec Window" })
        if let window = MacRecWindowFrames.controlWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }
        if MacRecWindowCoordinator.shared.reopenManualControlWindowIfNeeded() {
            return
        }
        if let newWindowItem, let action = newWindowItem.action {
            NSApp.sendAction(action, to: newWindowItem.target, from: newWindowItem)
        }
        guard allowManualFallback else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if MacRecWindowFrames.controlWindow == nil {
                MacRecWindowCoordinator.shared.showManualControlWindow()
            }
        }
    }
}

@main
struct MacRecApp: App {
    @NSApplicationDelegateAdaptor(MacRecApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared
    @AppStorage("MacRecCompanionIsDocked") private var companionIsDocked = false

    var body: some Scene {
        WindowGroup("MacRec", id: "controls") {
            ContentView()
                .environmentObject(model)
                .frame(
                    minWidth: companionIsDocked ? 1200 : 820,
                    idealWidth: companionIsDocked ? 1240 : 900,
                    maxWidth: companionIsDocked ? 1440 : 1050,
                    minHeight: 600,
                    idealHeight: 640,
                    maxHeight: 800
                )
        }
        .windowResizability(.contentSize)
        .defaultSize(width: companionIsDocked ? 1240 : 900, height: 640)

        Window("Live transcript", id: "live-companion") {
            LiveCompanionView()
                .environmentObject(model)
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 760, minHeight: 420, idealHeight: 680, maxHeight: 1000)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 680)
    }
}
