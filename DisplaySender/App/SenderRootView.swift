import Foundation
import SwiftUI

/// Sender control panel for wired endpoint setup and session lifecycle.
struct SenderRootView: View {
    @State private var coordinator = SenderSessionCoordinator()
    @StateObject private var discoveryService = ReceiverDiscoveryService()

    private static let savedHostKey = "lastReceiverHost"
    private static let savedPortKey = "lastReceiverPort"
    private static let savedDisplayResolutionPreferenceKey = "displayResolutionPreference"
    private static let savedFixedDisplayPresetKey = "fixedDisplayPreset"

    @State private var receiverHostInput = UserDefaults.standard.string(forKey: SenderRootView.savedHostKey) ?? ""
    @State private var portInput = UserDefaults.standard.string(forKey: SenderRootView.savedPortKey) ?? String(NetworkProtocol.defaultPort)
    @State private var selectedReceiverID: String?
    @State private var selectedDisplayResolutionPreference =
        SenderSessionCoordinator.DisplayResolutionPreference(
            rawValue: UserDefaults.standard.string(forKey: SenderRootView.savedDisplayResolutionPreferenceKey) ?? ""
        ) ?? .matchReceiver
    @State private var selectedFixedDisplayPresetID =
        UserDefaults.standard.string(forKey: SenderRootView.savedFixedDisplayPresetKey) ?? VirtualDisplayPreset.defaultFixed.id

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
    @State private var resolvedStreamingPipelineText = "-"
    @State private var wiredPathSummary = "unknown"
    @State private var wiredWarning = ""
    @State private var interfaceLines: [String] = []
    @State private var selectedStreamingPipelinePreference: NetworkProtocol.StreamingPipelinePreference = .automatic

    // Display mode state
    @State private var availableDisplayModes: [VirtualDisplayMode] = []
    @State private var activeDisplayModeText = "-"
    @State private var selectedModeID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            receiverSection
            displayResolutionSection
            streamingPipelineSection
            actionSection
            if !availableDisplayModes.isEmpty {
                displayModeSection
            }
            statusSection
            diagnosticsSection
        }
        .padding()
        .frame(minWidth: 800, minHeight: 540)
        .onAppear {
            coordinator.onChange = {
                refreshFromCoordinator()
            }
            if let preset = VirtualDisplayPreset.commonPresets.first(where: { $0.id == selectedFixedDisplayPresetID }) {
                coordinator.setPreferredDisplayPreset(preset)
            }
            coordinator.setDisplayResolutionPreference(selectedDisplayResolutionPreference)
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
                Text("Resolution is configured in Display Resolution.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var displayResolutionSection: some View {
        GroupBox("Display Resolution") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Choose how the virtual display starts. Match Receiver follows the receiver's display metrics. Fixed Preset lets you force pixel sizes like 3008×1692.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Picker("Resolution", selection: $selectedDisplayResolutionPreference) {
                    ForEach(SenderSessionCoordinator.DisplayResolutionPreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedDisplayResolutionPreference) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: Self.savedDisplayResolutionPreferenceKey)
                    coordinator.setDisplayResolutionPreference(newValue)
                    refreshFromCoordinator()
                }

                if selectedDisplayResolutionPreference == .fixedPreset {
                    Picker("Preset", selection: $selectedFixedDisplayPresetID) {
                        ForEach(VirtualDisplayPreset.commonPresets) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    .onChange(of: selectedFixedDisplayPresetID) { _, newID in
                        guard let preset = VirtualDisplayPreset.commonPresets.first(where: { $0.id == newID }) else { return }
                        UserDefaults.standard.set(newID, forKey: Self.savedFixedDisplayPresetKey)
                        coordinator.setPreferredDisplayPreset(preset)
                        refreshFromCoordinator()
                    }
                }

                Text("Configured startup mode: \(displayResolutionSummaryText)")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))

                if isSessionActive {
                    Text("Resolution changes restart capture automatically when the requested mode changes.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
    }

    private var displayModeSection: some View {
        GroupBox("Display Mode") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Active:")
                        .foregroundStyle(.secondary)
                    Text(activeDisplayModeText)
                        .font(.system(.body, design: .monospaced))
                }

                if availableDisplayModes.count > 1 {
                    Divider()

                    Text("Switch mode live — capture restarts automatically.")
                        .foregroundStyle(.secondary)
                        .font(.callout)

                    Picker("Mode", selection: $selectedModeID) {
                        ForEach(availableDisplayModes) { mode in
                            Text(mode.label).tag(Optional(mode.id))
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: selectedModeID) { _, newID in
                        guard let newID,
                              let mode = availableDisplayModes.first(where: { $0.id == newID }),
                              newID != coordinator.activeDisplayMode?.id
                        else { return }
                        coordinator.changeDisplayMode(mode)
                    }
                }
            }
        }
    }

    private var streamingPipelineSection: some View {
        GroupBox("Streaming Pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic uses direct/native capture on stronger Apple Silicon and adaptive low-res capture plus upscale on base-tier machines.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Picker("Pipeline", selection: $selectedStreamingPipelinePreference) {
                    ForEach(NetworkProtocol.StreamingPipelinePreference.allCases) { preference in
                        Text(preference.shortLabel).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedStreamingPipelinePreference) { _, newValue in
                    coordinator.setStreamingPipelinePreference(newValue)
                    refreshFromCoordinator()
                }

                Text("Resolved for this Mac: \(resolvedStreamingPipelineText)")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))

                if isSessionActive {
                    Text("Changes take effect the next time capture starts.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
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
                Text("Display Resolution: \(displayResolutionSummaryText)")
                Text("Streaming Pipeline: \(selectedStreamingPipelinePreference.label) -> \(resolvedStreamingPipelineText)")
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

    private var selectedFixedDisplayPreset: VirtualDisplayPreset {
        VirtualDisplayPreset.commonPresets.first(where: { $0.id == selectedFixedDisplayPresetID }) ?? .defaultFixed
    }

    private var displayResolutionSummaryText: String {
        switch selectedDisplayResolutionPreference {
        case .matchReceiver:
            return "Match Receiver"
        case .fixedPreset:
            return "Fixed \(selectedFixedDisplayPreset.label)"
        }
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
        resolvedStreamingPipelineText = coordinator.resolvedStreamingPipelineMode.label
        if selectedDisplayResolutionPreference != coordinator.displayResolutionPreference {
            selectedDisplayResolutionPreference = coordinator.displayResolutionPreference
        }
        if selectedFixedDisplayPresetID != coordinator.preferredDisplayPreset.id {
            selectedFixedDisplayPresetID = coordinator.preferredDisplayPreset.id
        }
        if selectedStreamingPipelinePreference != coordinator.streamingPipelinePreference {
            selectedStreamingPipelinePreference = coordinator.streamingPipelinePreference
        }
        negotiatedResolutionText = "\(coordinator.targetWidth)x\(coordinator.targetHeight)"
        wiredPathSummary = coordinator.wiredPathAvailable ? "available" : "not available"
        wiredWarning = coordinator.wiredPathAvailable ? "" : "No wired route currently available. Verify Thunderbolt Bridge and cable link."
        interfaceLines = coordinator.localInterfaceDescriptions

        availableDisplayModes = coordinator.availableDisplayModes
        if let active = coordinator.activeDisplayMode {
            activeDisplayModeText = active.shortDescription
            // Keep the picker in sync with the active mode without triggering onChange.
            if selectedModeID != active.id {
                selectedModeID = active.id
            }
        } else if coordinator.availableDisplayModes.isEmpty {
            activeDisplayModeText = "-"
            selectedModeID = nil
        }
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
                ReceiverThumbnailView(kind: receiver.visualKind)
                    .frame(width: 132, height: 88)

                VStack(alignment: .leading, spacing: 4) {
                    Text(receiver.displayName)
                        .font(.headline)
                    if let displayDescriptor = receiver.displayDescriptor {
                        Text(displayDescriptor)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(receiver.endpointSummary)
                        .font(.system(.caption, design: .monospaced))
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
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var backgroundStyle: some ShapeStyle {
        isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)
    }
}

private struct ReceiverThumbnailView: View {
    let kind: DiscoveredReceiverVisualKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundGradient)

            deviceArtwork
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    @ViewBuilder
    private var deviceArtwork: some View {
        switch kind {
        case .imac:
            iMacArtwork
        case .studioDisplay:
            studioDisplayArtwork
        case .macbookPro:
            macBookArtwork
        case .display:
            desktopDisplayArtwork
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.14, green: 0.16, blue: 0.20),
                Color(red: 0.09, green: 0.10, blue: 0.13)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var wallpaperGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.19, green: 0.55, blue: 0.84),
                Color(red: 0.36, green: 0.77, blue: 0.88),
                Color(red: 0.92, green: 0.86, blue: 0.58)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var desktopDisplayArtwork: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 92, height: 54)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .inset(by: 4)
                            .fill(wallpaperGradient)
                    )

                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 28, height: 2)
                    .offset(y: 6)
            }

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(silverGradient)
                .frame(width: 16, height: 16)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(silverGradient)
                .frame(width: 42, height: 4)
        }
    }

    private var studioDisplayArtwork: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.10))
                .frame(width: 96, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .inset(by: 4)
                        .fill(wallpaperGradient)
                )

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(silverGradient)
                .frame(width: 16, height: 18)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(silverGradient)
                .frame(width: 40, height: 6)
        }
    }

    private var iMacArtwork: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.86, green: 0.86, blue: 0.88))
                .frame(width: 98, height: 58)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .inset(by: 4)
                        .fill(wallpaperGradient)
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                )

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(silverGradient)
                .frame(width: 16, height: 18)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(silverGradient)
                .frame(width: 42, height: 6)
        }
    }

    private var macBookArtwork: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.13))
                .frame(width: 88, height: 54)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .inset(by: 4)
                        .fill(wallpaperGradient)
                )
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 18, height: 2)
                        .padding(.bottom, 4)
                }

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(silverGradient)
                .frame(width: 104, height: 10)
                .overlay(
                    Capsule()
                        .fill(Color.black.opacity(0.14))
                        .frame(width: 26, height: 2)
                )
        }
    }

    private var silverGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.92, green: 0.92, blue: 0.94),
                Color(red: 0.74, green: 0.75, blue: 0.78)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
