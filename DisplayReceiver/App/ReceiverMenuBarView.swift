import SwiftUI

struct ReceiverMenuBarView: View {
    @ObservedObject var appController: ReceiverAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appController.discoverableName)
                    .font(.headline)
                Text(appController.stateText)
                    .foregroundStyle(.secondary)
            }

            if appController.isStreaming {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Peer: \(appController.peerNameText)")
                    Text("Frames: \(appController.receivedFrameCount)")
                    Text("Rate: \(appController.receivedFramesPerSecondText)")
                    Text("Throughput: \(appController.receivedMegabitsPerSecondText)")
                }
                .font(.subheadline)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wired Path: \(appController.wiredPathSummary)")
                    if !appController.interfaceLines.isEmpty {
                        ForEach(appController.interfaceLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let advertisementErrorText = appController.advertisementErrorText {
                Text(advertisementErrorText)
                    .foregroundStyle(.orange)
            }

            if let powerManagementErrorText = appController.powerManagementErrorText {
                Text(powerManagementErrorText)
                    .foregroundStyle(.orange)
            }

            if appController.lastErrorText != "-" {
                Text(appController.lastErrorText)
                    .foregroundStyle(.red)
            }

            Divider()

            Button(appController.isReceiverWindowVisible ? "Hide Receiver Window" : "Open Receiver Window") {
                appController.toggleReceiverWindow()
            }

            if appController.isStreaming {
                Button("Bring Stream Full Screen") {
                    appController.presentReceiverWindow(fullScreen: true)
                }
            }

            Divider()

            Button("Quit DisplayReceiver") {
                appController.quitApplication()
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 280, alignment: .leading)
    }
}
