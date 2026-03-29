import Foundation
import SwiftUI

/// Receiver view that presents the Metal render surface as the primary content.
/// A small status overlay shows connection info and fades out once streaming begins.
struct ReceiverRootView: View {
    @ObservedObject var appController: ReceiverAppController

    @State private var showOverlay = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                MetalRenderSurfaceView()
                    .ignoresSafeArea()

                if shouldShowDebugCursorMarker,
                   let x = appController.cursorOverlayNormalizedX,
                   let y = appController.cursorOverlayNormalizedY {
                    ReceiverDebugCursorMarker()
                        .position(
                            x: max(0, min(geometry.size.width, CGFloat(x) * geometry.size.width)),
                            y: max(0, min(geometry.size.height, CGFloat(y) * geometry.size.height))
                        )
                        .allowsHitTesting(false)
                }

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
                    .onTapGesture {
                        withAnimation { showOverlay = false }
                    }
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

    private var shouldShowDebugCursorMarker: Bool {
        NetworkProtocol.useDebugCursorOverlayMarker &&
            appController.isStreaming &&
            appController.isCursorOverlayVisible
    }
}

private struct ReceiverDebugCursorMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.red.opacity(0.95))
                .frame(width: 26, height: 26)

            Circle()
                .stroke(Color.white.opacity(0.95), lineWidth: 3)
                .frame(width: 26, height: 26)

            Rectangle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 18, height: 3)

            Rectangle()
                .fill(Color.white.opacity(0.95))
                .frame(width: 3, height: 18)
        }
        .shadow(color: .black.opacity(0.45), radius: 6, x: 0, y: 2)
    }
}
