import Foundation
import SwiftUI

/// Sender control panel for wired endpoint setup and session lifecycle.
struct SenderRootView: View {
    @State private var coordinator = SenderSessionCoordinator()

    @State private var receiverHostInput = ""
    @State private var portInput = String(NetworkProtocol.defaultPort)
    @State private var widthInput = "2560"
    @State private var heightInput = "1440"

    @State private var stateText = "idle"
    @State private var connectionText = "not_connected"
    @State private var isSessionActive = false
    @State private var sentFrameCount: UInt64 = 0
    @State private var droppedOutboundFrameCount: UInt64 = 0
    @State private var lastErrorText = "-"
    @State private var sentFramesPerSecondText = "-"
    @State private var sentMegabitsPerSecondText = "-"

    @State private var endpointSummary = "-"
    @State private var wiredPathSummary = "unknown"
    @State private var wiredWarning = ""
    @State private var interfaceLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DisplaySender")
                .font(.title2)

            Text("Connect to receiver over Thunderbolt/USB-C and stream your display.")
                .foregroundStyle(.secondary)

            GroupBox("Endpoint") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Receiver host (e.g. 169.254.x.x)", text: $receiverHostInput)
                    HStack {
                        TextField("Port", text: $portInput)
                        TextField("Width", text: $widthInput)
                        TextField("Height", text: $heightInput)
                    }
                }
            }

            HStack(spacing: 10) {
                if isSessionActive {
                    Button("Stop") {
                        coordinator.stopSession()
                        refreshFromCoordinator()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("Connect & Stream") {
                        connect()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(receiverHostInput.isEmpty)
                }
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("State: \(stateText)")
                    Text("Connection: \(connectionText)")
                    Text("Sent Frames: \(sentFrameCount)")
                    Text("Dropped Outbound Frames: \(droppedOutboundFrameCount)")
                    Text("Send Rate: \(sentFramesPerSecondText)")
                    Text("Send Throughput: \(sentMegabitsPerSecondText)")
                    Text("Last Error: \(lastErrorText)")
                        .foregroundStyle(lastErrorText == "-" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }
            }

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Configured Endpoint: \(endpointSummary)")
                    Text("Wired Path: \(wiredPathSummary)")
                    if !wiredWarning.isEmpty {
                        Text(wiredWarning)
                            .foregroundStyle(.orange)
                    }

                    if interfaceLines.isEmpty {
                        Text("Local Interfaces: none detected")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Local Interfaces:")
                        ForEach(interfaceLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 420)
        .onAppear {
            coordinator.onChange = {
                refreshFromCoordinator()
            }
            refreshFromCoordinator()
        }
    }

    private func connect() {
        guard !receiverHostInput.isEmpty else { return }
        guard let port = UInt16(portInput), let width = Int(widthInput), let height = Int(heightInput) else { return }

        coordinator.connect(
            receiverHost: receiverHostInput,
            port: port,
            targetWidth: width,
            targetHeight: height
        )
        refreshFromCoordinator()
    }

    private func refreshFromCoordinator() {
        stateText = statusText(for: coordinator.state)
        connectionText = connectionText(for: coordinator.state)
        isSessionActive = coordinator.isSessionActive
        sentFrameCount = coordinator.sentFrameCount
        droppedOutboundFrameCount = coordinator.droppedOutboundFrameCount
        lastErrorText = coordinator.lastErrorMessage ?? "-"
        sentFramesPerSecondText = formatRate(coordinator.sentFramesPerSecond, unit: "fps")
        sentMegabitsPerSecondText = formatRate(coordinator.sentMegabitsPerSecond, unit: "Mbps")

        endpointSummary = coordinator.configuredEndpointSummary
        wiredPathSummary = coordinator.wiredPathAvailable ? "available" : "not available"
        wiredWarning = coordinator.wiredPathAvailable ? "" : "No wired route currently available. Verify Thunderbolt Bridge and cable link."
        interfaceLines = coordinator.localInterfaceDescriptions
    }

    private func statusText(for state: SenderSessionCoordinator.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .connecting:
            return "connecting"
        case .waitingForAck:
            return "waiting_for_ack"
        case .connected:
            return "connected"
        case .running:
            return "streaming"
        case .failed(let message):
            return "failed: \(message)"
        }
    }

    private func connectionText(for state: SenderSessionCoordinator.SessionState) -> String {
        switch state {
        case .connected, .running:
            return "success"
        case .waitingForAck:
            return "handshaking"
        case .connecting:
            return "connecting"
        case .failed:
            return "failed"
        case .idle:
            return "not_connected"
        }
    }

    private func formatRate(_ value: Double?, unit: String) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f %@", value, unit)
    }
}
