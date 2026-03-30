import AppKit
import SwiftUI

@MainActor
final class ReceiverStreamWindowManager: NSObject, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    private weak var window: NSWindow?
    private var hostingController: NSHostingController<ReceiverRootView>?
    private var isCursorHidden = false
    private var previousPresentationOptions: NSApplication.PresentationOptions?

    func present(appController: ReceiverAppController, enterFullScreen: Bool) {
        let window = ensureWindow(appController: appController)
        applyStreamingPresentation()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        setCursorHidden(appController.isStreaming)
        onVisibilityChange?(true)

        guard enterFullScreen, !window.styleMask.contains(.fullScreen) else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            guard let window = self.window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    func hide() {
        guard let window else { return }
        setCursorHidden(false)
        restorePresentation()

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

    func windowWillClose(_ notification: Notification) {
        setCursorHidden(false)
        onVisibilityChange?(false)
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1728, height: 1117),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "DisplayReceiver"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling, .managed]
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].forEach { buttonType in
            window.standardWindowButton(buttonType)?.isHidden = true
        }

        self.window = window
        self.hostingController = hostingController
        return window
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

    private func applyStreamingPresentation() {
        if previousPresentationOptions == nil {
            previousPresentationOptions = NSApplication.shared.presentationOptions
        }

        NSApplication.shared.presentationOptions = [
            .autoHideDock,
            .autoHideMenuBar,
            .disableMenuBarTransparency
        ]
    }

    private func restorePresentation() {
        if let previousPresentationOptions {
            NSApplication.shared.presentationOptions = previousPresentationOptions
            self.previousPresentationOptions = nil
        }
    }
}
