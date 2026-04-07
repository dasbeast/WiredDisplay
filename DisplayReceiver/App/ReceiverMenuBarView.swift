import SwiftUI

struct ReceiverMenuBarView: View {
    @ObservedObject var appController: ReceiverAppController
    @ObservedObject var updater: DisplayReceiverUpdater
    @AppStorage(NetworkProtocol.cursorPredictionDefaultsKey)
    private var enableCursorPrediction = true
    @AppStorage(NetworkProtocol.cursorPredictionStrengthDefaultsKey)
    private var cursorPredictionStrength = 0.75

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
                    Text("Cursor RX Rate: \(appController.cursorPacketsReceivedPerSecondText)")
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
                if appController.isReceiverWindowFullScreen {
                    Button("Leave Full Screen") {
                        appController.leaveReceiverFullScreen()
                    }
                }
            }

            Divider()

            Toggle("Predict Cursor Motion", isOn: $enableCursorPrediction)

            if enableCursorPrediction {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Prediction Strength")
                        Spacer()
                        Text("\(Int(cursorPredictionStrength * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $cursorPredictionStrength, in: 0...1)
                    Text("Lower values reduce overshoot. Higher values feel snappier.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            DisplayReceiverCheckForUpdatesView(updater: updater.updater)

            Divider()

            Button("Quit DisplayReceiver") {
                appController.quitApplication()
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 280, alignment: .leading)
    }
}
