//
//  DisplaySenderApp.swift
//  DisplaySender
//
//  Created by Bailey Kiehl on 3/7/26.
//

import AppKit
import SwiftUI

@main
struct DisplaySenderApp: App {
    @NSApplicationDelegateAdaptor(DisplaySenderAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            SenderRootView()
        }
        .defaultSize(width: 900, height: 720)

        MenuBarExtra("DisplaySender", systemImage: "display.2") {
            DisplaySenderMenuBarView()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Open DisplaySender") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Divider()

            Button("Quit DisplaySender") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}
