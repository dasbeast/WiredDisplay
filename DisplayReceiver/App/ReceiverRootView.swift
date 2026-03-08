import Foundation
import SwiftUI

/// Receiver view that presents the Metal render surface as the primary content.
/// A small status overlay shows connection info and fades out once streaming begins.
struct ReceiverRootView: View {
    @State private var coordinator = ReceiverSessionCoordinator()

    @State private var stateText = "idle"
    @State private var peerNameText = "-"
    @State private var receivedFrameCount: UInt64 = 0
    @State private var lastErrorText = "-"
    @State private var receivedFramesPerSecondText = "-"
    @State private var receivedMegabitsPerSecondText = "-"
    @State private var isStreaming = false
    @State private var showOverlay = true
    @State private var interfaceLines: [String] = []
    @State private var wiredPathSummary = "unknown"

    var body: some View {
        ZStack {
            // Full-window Metal render surface
            MetalRenderSurfaceView()
                .ignoresSafeArea()

            // Status overlay – visible until streaming, then auto-hides
            if showOverlay {
                VStack(alignment: .leading, spacing: 8) {
                    Text("DisplayReceiver")
                        .font(.title3.bold())

                    Text("State: \(stateText)")
                    Text("Peer: \(peerNameText)")

                    if isStreaming {
                        Text("Frames: \(receivedFrameCount)")
                        Text("Rate: \(receivedFramesPerSecondText)")
                        Text("Throughput: \(receivedMegabitsPerSecondText)")
                    } else {
                        Text("Wired Path: \(wiredPathSummary)")
                        if !interfaceLines.isEmpty {
                            Text("Local Interfaces:")
                                .padding(.top, 2)
                            ForEach(interfaceLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }

                    if lastErrorText != "-" {
                        Text("Error: \(lastErrorText)")
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
        .onAppear {
            coordinator.onChange = {
                refreshFromCoordinator()
            }
            // Auto-start listening immediately
            coordinator.startListening(port: NetworkProtocol.defaultPort)
            refreshFromCoordinator()
        }
        .onTapGesture {
            // Toggle overlay on tap when streaming
            if isStreaming {
                withAnimation { showOverlay.toggle() }
            }
        }
    }

    private func refreshFromCoordinator() {
        let newState = coordinator.state
        stateText = statusText(for: newState)
        peerNameText = coordinator.peerName.isEmpty ? "-" : coordinator.peerName

        let wasStreaming = isStreaming
        isStreaming = (newState == .running)
        receivedFrameCount = coordinator.receivedFrameCount
        lastErrorText = coordinator.lastErrorMessage ?? "-"
        receivedFramesPerSecondText = formatRate(coordinator.receivedFramesPerSecond, unit: "fps")
        receivedMegabitsPerSecondText = formatRate(coordinator.receivedMegabitsPerSecond, unit: "Mbps")
        wiredPathSummary = coordinator.wiredPathAvailable ? "available" : "not available"
        interfaceLines = coordinator.localInterfaceDescriptions

        // Auto-hide overlay after receiving some frames
        if isStreaming && !wasStreaming {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation { showOverlay = false }
            }
        }
    }

    private func statusText(for state: ReceiverSessionCoordinator.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .listening:
            return "listening (waiting for sender)"
        case .running:
            return "streaming"
        case .failed(let message):
            return "failed: \(message)"
        }
    }

    private func formatRate(_ value: Double?, unit: String) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f %@", value, unit)
    }
}
