import AppKit
import SwiftUI

@MainActor
final class ReceiverStreamWindowManager: NSObject, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    private weak var window: NSWindow?
    private var hostingController: NSHostingController<ReceiverRootView>?
    private var isCursorHidden = false
    private var wantsFullScreenPresentation = false

    func present(appController: ReceiverAppController, enterFullScreen: Bool) {
        let window = ensureWindow(appController: appController)
        wantsFullScreenPresentation = enterFullScreen
        prepareWindowForPresentation(window, enterFullScreen: enterFullScreen)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        setCursorHidden(appController.isStreaming)
        onVisibilityChange?(true)
        requestFullScreenIfNeeded()
    }

    func hide() {
        guard let window else { return }
        wantsFullScreenPresentation = false
        setCursorHidden(false)

        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.window?.orderOut(nil)
                self.onVisibilityChange?(false)
            }
        } else {
            window.orderOut(nil)
            onVisibilityChange?(false)
        }
    }

    func leaveFullScreenIfNeeded() {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        wantsFullScreenPresentation = false
        window.toggleFullScreen(nil)
    }

    func isWindowFullScreen() -> Bool {
        window?.styleMask.contains(.fullScreen) ?? false
    }

    func windowWillClose(_ notification: Notification) {
        wantsFullScreenPresentation = false
        setCursorHidden(false)
        onVisibilityChange?(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        requestFullScreenIfNeeded()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        requestFullScreenIfNeeded()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        onVisibilityChange?(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        onVisibilityChange?(window?.isVisible ?? false)
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        [.fullScreen, .hideMenuBar, .hideDock, .disableMenuBarTransparency]
    }

    private func ensureWindow(appController: ReceiverAppController) -> NSWindow {
        if let window, let hostingController {
            hostingController.rootView = ReceiverRootView(appController: appController)
            return window
        }

        let contentView = ReceiverRootView(appController: appController)
        let hostingController = NSHostingController(rootView: contentView)
        let initialFrame = preferredWindowFrame()
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DisplayReceiver"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling, .managed]
        window.toolbar = NSToolbar()
        window.contentViewController = hostingController
        window.delegate = self
        window.center()

        self.window = window
        self.hostingController = hostingController
        return window
    }

    private func prepareWindowForPresentation(_ window: NSWindow, enterFullScreen: Bool) {
        guard let screenFrame = targetScreenFrame(for: window) else { return }

        if enterFullScreen {
            window.setFrame(screenFrame, display: false)
        } else if window.frame.width < 300 || window.frame.height < 200 {
            window.setFrame(preferredWindowFrame(for: screenFrame), display: false)
        }
    }

    private func preferredWindowFrame() -> NSRect {
        preferredWindowFrame(for: targetScreenFrame(for: nil))
    }

    private func preferredWindowFrame(for screenFrame: NSRect?) -> NSRect {
        guard let screenFrame else {
            return NSRect(x: 0, y: 0, width: 1280, height: 800)
        }

        let width = max(960, screenFrame.width * 0.8)
        let height = max(600, screenFrame.height * 0.8)
        let originX = screenFrame.midX - (width / 2)
        let originY = screenFrame.midY - (height / 2)
        return NSRect(x: originX, y: originY, width: width, height: height)
    }

    private func targetScreenFrame(for window: NSWindow?) -> NSRect? {
        window?.screen?.frame ?? NSScreen.main?.frame ?? NSScreen.screens.first?.frame
    }

    private func requestFullScreenIfNeeded() {
        guard wantsFullScreenPresentation,
              let window,
              window.isVisible,
              !window.styleMask.contains(.fullScreen) else {
            return
        }

        DispatchQueue.main.async {
            guard self.wantsFullScreenPresentation,
                  let window = self.window,
                  window.isVisible,
                  !window.styleMask.contains(.fullScreen) else {
                return
            }
            window.toggleFullScreen(nil)
        }
    }

    private func setCursorHidden(_ hidden: Bool) {
        let effectiveHidden =
            hidden &&
            NetworkProtocol.hideReceiverLocalCursorWhileStreaming &&
            !NetworkProtocol.useReceiverSystemCursorMirror
        guard effectiveHidden != isCursorHidden else { return }

        if effectiveHidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }

        isCursorHidden = effectiveHidden
    }
}
