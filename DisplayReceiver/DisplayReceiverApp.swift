import AppKit
import Sparkle
import SwiftUI

final class DisplayReceiverAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct DisplayReceiverApp: App {
    @NSApplicationDelegateAdaptor(DisplayReceiverAppDelegate.self) private var appDelegate
    @StateObject private var appController = ReceiverAppController()
    @StateObject private var updater = DisplayReceiverUpdater()

    var body: some Scene {
        MenuBarExtra("DisplayReceiver", systemImage: appController.isStreaming ? "display.and.arrow.down" : "display.2") {
            ReceiverMenuBarView(appController: appController, updater: updater)
        }

        Settings {
            DisplayReceiverUpdaterSettingsView(
                updater: updater.updater,
                configurationError: updater.configurationError
            )
        }
    }
}
