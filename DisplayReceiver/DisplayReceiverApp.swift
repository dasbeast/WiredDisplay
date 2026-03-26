import AppKit
import Sparkle
import SwiftUI

final class DisplayReceiverAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ApplicationInstallPrompter.promptToMoveToApplicationsIfNeeded(appName: "DisplayReceiver")
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

private enum ApplicationInstallPrompter {
    static func promptToMoveToApplicationsIfNeeded(appName: String) {
        guard let bundleURL = Bundle.main.bundleURL.standardizedFileURL as URL?,
              bundleURL.pathExtension == "app",
              !isRunningFromApplications(bundleURL) else {
            return
        }

        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Move \(appName) to Applications?"
            alert.informativeText =
                "\(appName) updates work best when the app is installed in your Applications folder. Move it there now?"
            alert.addButton(withTitle: "Move to Applications")
            alert.addButton(withTitle: "Not Now")

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            do {
                try moveAppToApplicationsAndRelaunch(from: bundleURL)
            } catch {
                let failureAlert = NSAlert(error: error)
                failureAlert.runModal()
            }
        }
    }

    private static func isRunningFromApplications(_ bundleURL: URL) -> Bool {
        let path = bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private static func moveAppToApplicationsAndRelaunch(from sourceURL: URL) throws {
        let fileManager = FileManager.default
        let applicationsDirectoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let destinationURL = applicationsDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)

        if fileManager.fileExists(atPath: destinationURL.path) {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: destinationURL, resultingItemURL: &trashedURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: destinationURL, configuration: configuration)
        NSApp.terminate(nil)
    }
}
