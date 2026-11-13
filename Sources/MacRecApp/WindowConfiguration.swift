import SwiftUI
import AppKit

enum MacRecWindowFrames {
    private static let undockedControlFrameKey = "MacRecUndockedControlFrame"

    @MainActor
    static var controlWindow: NSWindow? {
        if let keyWindow = NSApp.keyWindow, keyWindow.title == "MacRec" {
            return keyWindow
        }
        return NSApp.windows.first(where: { $0.title == "MacRec" })
    }

    @MainActor
    static func rememberUndockedControlFrame() {
        guard let frame = controlWindow?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: undockedControlFrameKey)
    }

    @MainActor
    static func restoreUndockedControlFrame() {
        guard let value = UserDefaults.standard.string(forKey: undockedControlFrameKey),
              let window = controlWindow else { return }
        let frame = NSRectFromString(value)
        guard frame.width >= 820, frame.height >= 600 else { return }
        window.setFrame(frame, display: true, animate: true)
    }
}

@MainActor
final class MacRecWindowCoordinator {
    static let shared = MacRecWindowCoordinator()

    private var usesManualWindows = false
    private var manualControlWindow: NSWindow?
    private var manualCompanionWindow: NSWindow?

    func reopenManualControlWindowIfNeeded() -> Bool {
        guard usesManualWindows else { return false }
        showManualControlWindow()
        return true
    }

    func showManualControlWindow() {
        usesManualWindows = true
        if let manualControlWindow {
            manualControlWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = ContentView()
            .environmentObject(AppModel.shared)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacRec"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameAutosaveName("MacRecControlWindow")
        if !window.setFrameUsingName("MacRecControlWindow") {
            window.center()
        }
        manualControlWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showCompanion(using sceneAction: OpenWindowAction) {
        if let existing = NSApp.windows.first(where: { $0.title == "Live transcript" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard usesManualWindows else {
            sceneAction(id: "live-companion")
            return
        }

        if let manualCompanionWindow {
            manualCompanionWindow.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = LiveCompanionView()
            .environmentObject(AppModel.shared)
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Live transcript"
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setFrameAutosaveName("MacRecLiveCompanionWindow")
        if !window.setFrameUsingName("MacRecLiveCompanionWindow") {
            window.center()
        }
        manualCompanionWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func closeCompanion() {
        NSApp.windows.first(where: { $0.title == "Live transcript" })?.close()
    }
}

struct WindowConfiguration: NSViewRepresentable {
    let autosaveName: String
    let minSize: NSSize
    let maxSize: NSSize
    let supportsFullScreenOverlay: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            applySizing(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applySizing(to: nsView.window)
    }

    private func applySizing(to window: NSWindow?) {
        guard let window else { return }
        if window.frameAutosaveName != autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }
        if window.minSize != minSize {
            window.minSize = minSize
        }
        if window.maxSize != maxSize {
            window.maxSize = maxSize
        }
        if window.level != .normal {
            window.level = .normal
        }

        let isFullScreenAuxiliary = window.collectionBehavior.contains(.fullScreenAuxiliary)
        if supportsFullScreenOverlay, !isFullScreenAuxiliary {
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else if !supportsFullScreenOverlay, isFullScreenAuxiliary {
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }

        let current = window.frame
        let clampedWidth = min(max(current.width, minSize.width), maxSize.width)
        let clampedHeight = min(max(current.height, minSize.height), maxSize.height)
        guard clampedWidth != current.width || clampedHeight != current.height else { return }

        let newOrigin = NSPoint(
            x: current.midX - clampedWidth / 2,
            y: current.midY - clampedHeight / 2
        )
        window.setFrame(NSRect(origin: newOrigin, size: NSSize(width: clampedWidth, height: clampedHeight)), display: true)
    }
}
