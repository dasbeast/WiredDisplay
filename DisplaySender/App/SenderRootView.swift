import Foundation
import SwiftUI

/// Sender control panel for wired endpoint setup and session lifecycle.
struct SenderRootView: View {
    @State private var coordinator = SenderSessionCoordinator()
    @StateObject private var discoveryService = ReceiverDiscoveryService()

    private static let savedHostKey = "lastReceiverHost"
    private static let savedPortKey = "lastReceiverPort"

    @State private var receiverHostInput = UserDefaults.standard.string(forKey: SenderRootView.savedHostKey) ?? ""
    @State private var portInput = UserDefaults.standard.string(forKey: SenderRootView.savedPortKey) ?? String(NetworkProtocol.defaultPort)
    @State private var selectedReceiverID: String?

    @State private var stateText = "idle"
    @State private var connectionText = "not_connected"
    @State private var isSessionActive = false
    @State private var sentFrameCount: UInt64 = 0
    @State private var droppedOutboundFrameCount: UInt64 = 0
    @State private var lastErrorText = "-"
    @State private var sentFramesPerSecondText = "-"
    @State private var sentMegabitsPerSecondText = "-"
    @State private var heartbeatRoundTripText = "-"
    @State private var estimatedDisplayLatencyText = "-"

    @State private var endpointSummary = "-"
    @State private var negotiatedResolutionText = "-"
    @State private var videoTransportText = "TCP"
    @State private var wiredPathSummary = "unknown"
    @State private var wiredWarning = ""
    @State private var interfaceLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            receiverSection
            actionSection
            statusSection
            diagnosticsSection
        }
        .padding()
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            coordinator.onChange = {
                refreshFromCoordinator()
            }
            discoveryService.startBrowsing()
            refreshFromCoordinator()
        }
        .onDisappear {
            discoveryService.stopBrowsing()
        }
        .onReceive(discoveryService.$receivers) { receivers in
            reconcileDiscoveredReceivers(receivers)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("DisplaySender")
                .font(.title2)

            Text("Pick a discoverable receiver on the wired network and start streaming.")
                .foregroundStyle(.secondary)
        }
    }

    private var receiverSection: some View {
        GroupBox("Receivers") {
            VStack(alignment: .leading, spacing: 10) {
                receiverDiscoveryContent

                if let discoveryError = discoveryService.lastErrorMessage {
                    Text(discoveryError)
                        .foregroundStyle(.orange)
                }

                manualEndpointSection
            }
        }
    }

    @ViewBuilder
    private var receiverDiscoveryContent: some View {
        if discoveryService.receivers.isEmpty {
            HStack(spacing: 8) {
                if discoveryService.isBrowsing {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(discoveryService.isBrowsing ? "Searching for receivers..." : "Discovery is idle.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Select the Mac you want to stream to.")
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(discoveryService.receivers) { receiver in
                        ReceiverOptionRow(
                            receiver: receiver,
                            isSelected: selectedReceiverID == receiver.id
                        ) {
                            selectedReceiverID = receiver.id
                        }
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    private var manualEndpointSection: some View {
        DisclosureGroup("Manual Endpoint (Fallback)") {
            VStack(alignment: .leading, spacing: 8) {
                if selectedReceiver() != nil {
                    Text("Manual host entry is only used when no discovered receiver is selected.")
                        .foregroundStyle(.secondary)

                    Button("Use Manual Endpoint Instead") {
                        selectedReceiverID = nil
                    }
                }

                TextField("Receiver host", text: $receiverHostInput)
                TextField("Port", text: $portInput)
                Text("Resolution: auto-match receiver display")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            if isSessionActive {
                Button("Stop") {
                    coordinator.stopSession()
                    refreshFromCoordinator()
                }
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Connect & Stream TCP") {
                    connect(using: .tcp)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)

                Button("Connect & Stream UDP") {
                    connect(using: .udp)
                }
                .disabled(!canConnect)
            }
        }
    }

    private var statusSection: some View {
        GroupBox("Status") {
            VStack(alignment: .leading, spacing: 6) {
                Text("State: \(stateText)")
                Text("Connection: \(connectionText)")
                Text("Sent Frames: \(sentFrameCount)")
                Text("Dropped Outbound Frames: \(droppedOutboundFrameCount)")
                Text("Send Rate: \(sentFramesPerSecondText)")
                Text("Send Throughput: \(sentMegabitsPerSecondText)")
                Text("Heartbeat RTT: \(heartbeatRoundTripText)")
                Text("Est. Display Latency: \(estimatedDisplayLatencyText)")
                Text("Last Error: \(lastErrorText)")
                    .foregroundStyle(lastErrorText == "-" ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
            }
        }
    }

    private var diagnosticsSection: some View {
        GroupBox("Diagnostics") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected Receiver: \(selectedReceiver()?.displayName ?? "manual")")
                Text("Configured Endpoint: \(endpointSummary)")
                Text("Video Transport: \(videoTransportText)")
                Text("Negotiated Display: \(negotiatedResolutionText)")
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

    private var canConnect: Bool {
        resolvedConnectionTarget() != nil
    }

    private func connect(using videoTransportMode: NetworkProtocol.VideoTransportMode) {
        guard let target = resolvedConnectionTarget() else { return }

        UserDefaults.standard.set(target.host, forKey: Self.savedHostKey)
        UserDefaults.standard.set(String(target.port), forKey: Self.savedPortKey)

        coordinator.connect(
            receiverHost: target.host,
            port: target.port,
            videoTransportMode: videoTransportMode
        )
        refreshFromCoordinator()
    }

    private func selectedReceiver() -> DiscoveredReceiver? {
        guard let selectedReceiverID else { return nil }
        return discoveryService.receivers.first(where: { $0.id == selectedReceiverID })
    }

    private func resolvedConnectionTarget() -> (host: String, port: UInt16)? {
        if let selectedReceiver = selectedReceiver() {
            return (host: selectedReceiver.host, port: selectedReceiver.port)
        }

        let manualHost = receiverHostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manualHost.isEmpty, let manualPort = UInt16(portInput) else {
            return nil
        }

        return (host: manualHost, port: manualPort)
    }

    private func reconcileDiscoveredReceivers(_ receivers: [DiscoveredReceiver]) {
        guard !receivers.isEmpty else {
            selectedReceiverID = nil
            return
        }

        if let selectedReceiverID,
           receivers.contains(where: { $0.id == selectedReceiverID }) {
            return
        }

        let savedHost = UserDefaults.standard.string(forKey: Self.savedHostKey)
        if let savedHost,
           let matchingReceiver = receivers.first(where: {
               $0.host == savedHost || $0.displayName == savedHost
           }) {
            selectedReceiverID = matchingReceiver.id
            return
        }

        selectedReceiverID = receivers.first?.id
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
        heartbeatRoundTripText = formatRate(coordinator.heartbeatRoundTripMilliseconds, unit: "ms")
        estimatedDisplayLatencyText = formatRate(coordinator.estimatedDisplayLatencyMilliseconds, unit: "ms")

        endpointSummary = coordinator.configuredEndpointSummary
        videoTransportText = coordinator.negotiatedVideoTransportMode.rawValue.uppercased()
        negotiatedResolutionText = "\(coordinator.targetWidth)x\(coordinator.targetHeight)"
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

private struct ReceiverOptionRow: View {
    let receiver: DiscoveredReceiver
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.displayName)
                        .font(.headline)
                    Text(receiver.endpointSummary)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if receiver.prefersWiredPath {
                    Text("Wired")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(backgroundStyle)
        }
        .buttonStyle(.plain)
    }

    private var backgroundStyle: some ShapeStyle {
        isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)
    }
}
