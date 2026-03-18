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
