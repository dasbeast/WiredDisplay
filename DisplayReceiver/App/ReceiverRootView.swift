import AppKit
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

                if shouldShowCursorOverlay,
                   let overlayPosition = cursorOverlayPosition(in: geometry.size) {
                    ReceiverCursorOverlayVisual()
                        .position(overlayPosition)
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

    private var shouldShowCursorOverlay: Bool {
        NetworkProtocol.enableReceiverSideCursorOverlay &&
            NetworkProtocol.useSwiftUIReceiverCursorOverlay &&
            appController.isStreaming &&
            appController.isCursorOverlayVisible
    }

    private func cursorOverlayPosition(in size: CGSize) -> CGPoint? {
        guard let normalizedX = appController.cursorOverlayNormalizedX,
              let normalizedY = appController.cursorOverlayNormalizedY else {
            return nil
        }

        let anchorPoint = CGPoint(
            x: CGFloat(normalizedX) * size.width,
            y: CGFloat(normalizedY) * size.height
        )
        let centerOffset = ReceiverCursorOverlayVisual.centerOffset
        return CGPoint(
            x: anchorPoint.x + centerOffset.x,
            y: anchorPoint.y + centerOffset.y
        )
    }
}

private struct ReceiverCursorOverlayVisual: View {
    private static let arrowCursorImage = NSCursor.arrow.image
    private static let arrowImageSize = arrowCursorImage.size
    private static let arrowHotSpotFromTop = NSCursor.arrow.hotSpot

    static var centerOffset: CGPoint {
        if NetworkProtocol.useDebugCursorOverlayMarker {
            return .zero
        }

        return CGPoint(
            x: (arrowImageSize.width / 2.0) - arrowHotSpotFromTop.x,
            y: (arrowImageSize.height / 2.0) - arrowHotSpotFromTop.y
        )
    }

    var body: some View {
        Group {
            if NetworkProtocol.useDebugCursorOverlayMarker {
                ReceiverDebugCursorMarker()
            } else {
                Image(nsImage: Self.arrowCursorImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.arrowImageSize.width, height: Self.arrowImageSize.height)
            }
        }
        .shadow(color: .black.opacity(NetworkProtocol.useDebugCursorOverlayMarker ? 0.45 : 0.15), radius: 6, x: 0, y: 2)
        .accessibilityHidden(true)
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
    }
}
