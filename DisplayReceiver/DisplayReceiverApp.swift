import SwiftUI

@main
struct DisplayReceiverApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverRootView()
        }
        .defaultSize(width: 2560, height: 1440)
    }
}
