import Foundation
import SwiftUI

/// Receiver view that presents the Metal render surface as the primary content.
/// A small status overlay shows connection info and fades out once streaming begins.
struct ReceiverRootView: View {
    @ObservedObject var appController: ReceiverAppController

    @State private var showOverlay = true

    var body: some View {
        ZStack {
            MetalRenderSurfaceView()
                .ignoresSafeArea()

            if showOverlay {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DisplayReceiver")
                        .font(.title3.bold())

                    Text("State: \(appController.stateText)")
                    Text("Peer: \(appController.peerNameText)")

                    if appController.isStreaming {
                        Text("Frames: \(appController.receivedFrameCount)")
                        Text("Rate: \(appController.receivedFramesPerSecondText)")
                        Text("Throughput: \(appController.receivedMegabitsPerSecondText)")
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
                .onTapGesture {
                    withAnimation { showOverlay = false }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .onTapGesture {
            if appController.isStreaming {
                withAnimation { showOverlay.toggle() }
            }
        }
        .onChange(of: appController.isStreaming) { isStreaming in
            if isStreaming {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { showOverlay = false }
                }
            } else {
                withAnimation { showOverlay = true }
            }
        }
    }
}
