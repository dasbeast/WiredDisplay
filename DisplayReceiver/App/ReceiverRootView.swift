import Foundation
import SwiftUI

/// Receiver view that presents the Metal render surface as the primary content.
/// A small status overlay shows connection info while the receiver is idle.
struct ReceiverRootView: View {
    @ObservedObject var appController: ReceiverAppController
    @AppStorage(NetworkProtocol.cursorPredictionDefaultsKey)
    private var enableCursorPrediction = true
    @AppStorage(NetworkProtocol.cursorPredictionStrengthDefaultsKey)
    private var cursorPredictionStrength = 1.0

    var body: some View {
        ZStack {
            MetalRenderSurfaceView()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Predict Cursor Motion", isOn: $enableCursorPrediction)
                Text(
                    enableCursorPrediction
                        ? "Draws the cursor slightly ahead to hide network delay."
                        : "Draws only the latest real cursor packet with no prediction."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

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
            }
            .padding(12)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            if !appController.isStreaming {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DisplayReceiver")
                        .font(.title3.bold())

                    Text("State: \(appController.stateText)")
                    Text("Peer: \(appController.peerNameText)")

                    if appController.isStreaming {
                        Text("Frames: \(appController.receivedFrameCount)")
                        Text("Rate: \(appController.receivedFramesPerSecondText)")
                        Text("Throughput: \(appController.receivedMegabitsPerSecondText)")
                        Text("Cursor Overlay: \(appController.cursorOverlayText)")
                    } else {
                        Text("Discoverable As: \(appController.discoverableName)")
                        Text("Wired Path: \(appController.wiredPathSummary)")
                        if !appController.interfaceLines.isEmpty {
                            Text("Local Interfaces:")
                                .padding(.top, 2)
                            ForEach(appController.interfaceLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }

                    if let advertisementError = appController.advertisementErrorText {
                        Text("Discovery Error: \(advertisementError)")
                            .foregroundStyle(.orange)
                    }

                    if let powerManagementError = appController.powerManagementErrorText {
                        Text("Power Error: \(powerManagementError)")
                            .foregroundStyle(.orange)
                    }

                    if appController.lastErrorText != "-" {
                        Text("Error: \(appController.lastErrorText)")
                            .foregroundStyle(.red)
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(!appController.isStreaming)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}
