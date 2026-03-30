import Foundation
import SwiftUI

/// Receiver view that presents the Metal render surface as the primary content.
/// A small status overlay shows connection info while the receiver is idle.
struct ReceiverRootView: View {
    @ObservedObject var appController: ReceiverAppController

    var body: some View {
        ZStack {
            MetalRenderSurfaceView()
                .ignoresSafeArea()

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
