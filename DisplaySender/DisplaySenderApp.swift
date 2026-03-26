//
//  DisplaySenderApp.swift
//  DisplaySender
//
//  Created by Bailey Kiehl on 3/7/26.
//

import AppKit
import Sparkle
import SwiftUI

@main
struct DisplaySenderApp: App {
    @NSApplicationDelegateAdaptor(DisplaySenderAppDelegate.self) private var appDelegate
    @StateObject private var updater = DisplaySenderUpdater()

    var body: some Scene {
        WindowGroup(id: "main") {
            SenderRootView()
        }
        .defaultSize(width: 900, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.updater?.checkForUpdates()
                }
                .disabled(updater.updater == nil || !(updater.updater?.canCheckForUpdates ?? false))
            }
        }

        MenuBarExtra("DisplaySender", systemImage: "display.2") {
            DisplaySenderMenuBarView(updater: updater)
        }

        Settings {
            UpdaterSettingsView(updater: updater.updater, configurationError: updater.configurationError)
        }
    }
}

final class DisplaySenderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ApplicationInstallPrompter.promptToMoveToApplicationsIfNeeded(appName: "DisplaySender")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }

        sender.activate(ignoringOtherApps: true)
        if let window = sender.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
        return true
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

private struct DisplaySenderMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater: DisplaySenderUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open DisplaySender") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            CheckForUpdatesView(updater: updater.updater)

            Divider()

            Button("Quit DisplaySender") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}
