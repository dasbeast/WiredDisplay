import AppKit
import Foundation
import SwiftUI

@MainActor
private enum SenderRuntime {
    static let coordinator = SenderSessionCoordinator()
    static let discoveryService = ReceiverDiscoveryService()
}

/// Sender control panel for wired endpoint setup and session lifecycle.
struct SenderRootView: View {
    private let coordinator = SenderRuntime.coordinator
    @ObservedObject private var discoveryService = SenderRuntime.discoveryService

    private static let savedHostKey = "lastReceiverHost"
    private static let savedPortKey = "lastReceiverPort"
    private static let savedDisplayResolutionPreferenceKey = "displayResolutionPreference"
    private static let savedFixedDisplayPresetKey = "fixedDisplayPreset"
    private static let savedStreamingPipelinePreferenceKey = "streamingPipelinePreference"
    private static let savedUseSideCursorOverlayKey = "useSideCursorOverlay"
    private static let savedUseDynamicCursorAppearanceMirroringKey = "useDynamicCursorAppearanceMirroring"

    @State private var receiverHostInput = UserDefaults.standard.string(forKey: SenderRootView.savedHostKey) ?? ""
    @State private var portInput = UserDefaults.standard.string(forKey: SenderRootView.savedPortKey) ?? String(NetworkProtocol.defaultPort)
    @State private var selectedReceiverID: String?
    @State private var selectedReceiverPathIDs: [String: String] = [:]
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
    @State private var captureToEncodeLatencyText = "-"
    @State private var encodeToReceiveLatencyText = "-"
    @State private var receiveToRenderLatencyText = "-"

    @State private var endpointSummary = "-"
    @State private var negotiatedResolutionText = "-"
    @State private var videoTransportText = "TCP"
    @State private var tcpVideoFramesSent: UInt64 = 0
    @State private var tcpVideoFramesDropped: UInt64 = 0
    @State private var tcpCursorFramesSent: UInt64 = 0
    @State private var cursorDatagramMotionPacketsSent: UInt64 = 0
    @State private var cursorDatagramQueuedPacketsSent: UInt64 = 0
    @State private var cursorDatagramQueuedPacketsDropped: UInt64 = 0
    @State private var cursorDatagramPendingPackets: Int = 0
    @State private var cursorDatagramSendErrors: UInt64 = 0
    @State private var resolvedStreamingPipelineText = "-"
    @State private var wiredPathSummary = "unknown"
    @State private var wiredWarning = ""
    @State private var interfaceLines: [String] = []
    @State private var selectedStreamingPipelinePreference =
        NetworkProtocol.StreamingPipelinePreference(
            rawValue: UserDefaults.standard.string(forKey: SenderRootView.savedStreamingPipelinePreferenceKey) ?? ""
        ) ?? .automatic
    @State private var useSideCursorOverlay =
        UserDefaults.standard.object(forKey: SenderRootView.savedUseSideCursorOverlayKey) as? Bool ?? false
    @State private var useDynamicCursorAppearanceMirroring =
        UserDefaults.standard.object(forKey: SenderRootView.savedUseDynamicCursorAppearanceMirroringKey) as? Bool ??
        NetworkProtocol.enableDynamicCursorAppearanceMirroring
    @State private var isAdvancedResolutionsExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerSection
                receiverSection
                displayResolutionSection
                streamingPipelineSection
                actionSection
                statusSection
                nerdStatsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(minWidth: 800, minHeight: 540)
        .onAppear {
            let persistedPreset = VirtualDisplayPreset.preset(forID: selectedFixedDisplayPresetID) ?? .defaultFixed
            if selectedFixedDisplayPresetID != persistedPreset.id {
                selectedFixedDisplayPresetID = persistedPreset.id
                UserDefaults.standard.set(persistedPreset.id, forKey: Self.savedFixedDisplayPresetKey)
            }
            coordinator.setPreferredDisplayPreset(persistedPreset)
            coordinator.setDisplayResolutionPreference(selectedDisplayResolutionPreference)
            coordinator.setStreamingPipelinePreference(selectedStreamingPipelinePreference)
            coordinator.setUseReceiverSideCursorOverlay(useSideCursorOverlay)
            coordinator.setUseDynamicCursorAppearanceMirroring(useDynamicCursorAppearanceMirroring)
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
                            selectedPathID: selectedPathID(for: receiver),
                            isSelected: selectedReceiverID == receiver.id,
                            onSelectPath: { pathID in
                                selectedReceiverPathIDs[receiver.id] = pathID
                            },
                            onSelect: {
                                selectedReceiverID = receiver.id
                            }
                        )
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
                        ForEach(VirtualDisplayPreset.standardPresets) { preset in
                            Text(preset.label).tag(preset.id)
                        }
                    }
                    .onChange(of: selectedFixedDisplayPresetID) { _, newID in
                        guard let preset = VirtualDisplayPreset.preset(forID: newID) else { return }
                        UserDefaults.standard.set(newID, forKey: Self.savedFixedDisplayPresetKey)
                        coordinator.setPreferredDisplayPreset(preset)
                        refreshFromCoordinator()
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            isAdvancedResolutionsExpanded.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isAdvancedResolutionsExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text("Advanced Resolutions")
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)

                        if isAdvancedResolutionsExpanded {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("This exposes a much larger set of display modes, including non-HiDPI 4K, Retina variants, MacBook panel sizes, ultrawides, and higher-end panels like 6K and 8K-class experiments.")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)

                                Picker("All Presets", selection: $selectedFixedDisplayPresetID) {
                                    ForEach(VirtualDisplayPreset.allPresets) { preset in
                                        Text(preset.label).tag(preset.id)
                                    }
                                }
                                .labelsHidden()
                                .onChange(of: selectedFixedDisplayPresetID) { _, newID in
                                    guard let preset = VirtualDisplayPreset.preset(forID: newID) else { return }
                                    UserDefaults.standard.set(newID, forKey: Self.savedFixedDisplayPresetKey)
                                    coordinator.setPreferredDisplayPreset(preset)
                                    refreshFromCoordinator()
                                }

                                if !VirtualDisplayPreset.standardPresets.contains(selectedFixedDisplayPreset) {
                                    Text("Selected advanced preset: \(selectedFixedDisplayPreset.label)")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                }

                                if isSessionActive && !coordinator.availableDisplayModes.isEmpty {
                                    Text("Live modes macOS is currently advertising:")
                                        .font(.callout.weight(.medium))
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 4) {
                                            ForEach(coordinator.availableDisplayModes) { mode in
                                                Text(mode.label)
                                                    .font(.system(.caption, design: .monospaced))
                                                    .foregroundStyle(mode == coordinator.activeDisplayMode ? Color.accentColor : .secondary)
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 140)
                                }
                            }
                            .padding(.top, 6)
                            .padding(.leading, 19)
                        }
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

    private var streamingPipelineSection: some View {
        GroupBox("Streaming Pipeline") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic uses direct/native capture on stronger Apple Silicon. Adaptive Upscale always captures below native resolution and lets the receiver scale back up for lower latency.")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Picker("Pipeline", selection: $selectedStreamingPipelinePreference) {
                    ForEach(NetworkProtocol.StreamingPipelinePreference.allCases) { preference in
                        Text(preference.shortLabel).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedStreamingPipelinePreference) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: Self.savedStreamingPipelinePreferenceKey)
                    coordinator.setStreamingPipelinePreference(newValue)
                    refreshFromCoordinator()
                }

                Text("Resolved for this Mac: \(resolvedStreamingPipelineText)")
                    .foregroundStyle(.secondary)
                    .font(.system(.body, design: .monospaced))

                Toggle("Use Side Cursor Overlay", isOn: $useSideCursorOverlay)
                    .onChange(of: useSideCursorOverlay) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: Self.savedUseSideCursorOverlayKey)
                        coordinator.setUseReceiverSideCursorOverlay(newValue)
                        refreshFromCoordinator()
                    }

                Toggle("Mirror Cursor Shapes", isOn: $useDynamicCursorAppearanceMirroring)
                    .disabled(!useSideCursorOverlay)
                    .onChange(of: useDynamicCursorAppearanceMirroring) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: Self.savedUseDynamicCursorAppearanceMirroringKey)
                        coordinator.setUseDynamicCursorAppearanceMirroring(newValue)
                        refreshFromCoordinator()
                    }

                Text(
                    useSideCursorOverlay
                        ? "Uses the receiver-side cursor overlay path. Native cursor capture is disabled in the video stream."
                        : "Captures the macOS cursor directly inside the video stream and skips the side cursor path."
                )
                .foregroundStyle(.secondary)
                .font(.callout)

                Text(
                    useSideCursorOverlay
                        ? (
                            useDynamicCursorAppearanceMirroring
                                ? "Also mirrors cursor shapes like I-beam, resize arrows, and pointing hands."
                                : "Cursor shape mirroring is off, so the receiver stays on the default arrow cursor."
                        )
                        : "Cursor shape mirroring only applies when Side Cursor Overlay is enabled."
                )
                .foregroundStyle(.secondary)
                .font(.callout)

                if isSessionActive {
                    Text("Changes restart capture automatically while streaming.")
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
                Button("Connect & Stream") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canConnect)
            }
        }
    }

    private var statusSection: some View {
        GroupBox("Connection") {
            VStack(alignment: .leading, spacing: 6) {
                Text(connectionSummaryText)
                    .font(.headline)

                Text(connectionDetailText)
                    .foregroundStyle(.secondary)

                if lastErrorText != "-" {
                    Text("Last Error: \(lastErrorText)")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var nerdStatsSection: some View {
        DisclosureGroup("Stats for Nerds") {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("State: \(stateText)")
                        Text("Connection: \(connectionText)")
                        Text("Sent Frames: \(sentFrameCount)")
                        Text("Dropped Outbound Frames: \(droppedOutboundFrameCount)")
                        Text("TCP Video Frames Sent: \(tcpVideoFramesSent)")
                        Text("TCP Video Frames Dropped: \(tcpVideoFramesDropped)")
                        Text("TCP Cursor Frames Sent: \(tcpCursorFramesSent)")
                        Text("Cursor UDP Motion Packets Sent: \(cursorDatagramMotionPacketsSent)")
                        Text("Cursor UDP Queued Packets Sent: \(cursorDatagramQueuedPacketsSent)")
                        Text("Cursor UDP Queued Packets Dropped: \(cursorDatagramQueuedPacketsDropped)")
                        Text("Cursor UDP Pending Packets: \(cursorDatagramPendingPackets)")
                        Text("Cursor UDP Send Errors: \(cursorDatagramSendErrors)")
                        Text("Send Rate: \(sentFramesPerSecondText)")
                        Text("Send Throughput: \(sentMegabitsPerSecondText)")
                        Text("Heartbeat RTT: \(heartbeatRoundTripText)")
                        Text("Est. Display Latency: \(estimatedDisplayLatencyText)")
                        Text("Capture -> Encode: \(captureToEncodeLatencyText)")
                        Text("Encode -> Receive: \(encodeToReceiveLatencyText)")
                        Text("Receive -> Render: \(receiveToRenderLatencyText)")
                    }
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected Receiver: \(selectedReceiver()?.displayName ?? "manual")")
                        Text("Configured Endpoint: \(endpointSummary)")
                        Text("Video Transport: \(videoTransportText)")
                        Text("Display Resolution: \(displayResolutionSummaryText)")
                        Text("Streaming Pipeline: \(selectedStreamingPipelinePreference.label) -> \(resolvedStreamingPipelineText)")
                        Text("Cursor Mode: \(cursorModeSummaryText)")
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
            .padding(.top, 8)
        }
    }

    private var canConnect: Bool {
        resolvedConnectionTarget() != nil
    }

    private func connect() {
        guard let target = resolvedConnectionTarget() else { return }
        let alternateHosts: [String]
        if let receiver = selectedReceiver() {
            let primaryHost = selectedPath(for: receiver)?.host ?? receiver.host
            alternateHosts = ([receiver.host] + receiver.pathOptions.map(\.host))
                .filter { $0 != primaryHost }
        } else {
            alternateHosts = []
        }

        UserDefaults.standard.set(target.host, forKey: Self.savedHostKey)
        UserDefaults.standard.set(String(target.port), forKey: Self.savedPortKey)

        coordinator.connect(
            receiverHost: target.host,
            alternateReceiverHosts: alternateHosts,
            port: target.port,
            videoTransportMode: .tcp
        )
        refreshFromCoordinator()
    }

    private func selectedReceiver() -> DiscoveredReceiver? {
        guard let selectedReceiverID else { return nil }
        return discoveryService.receivers.first(where: { $0.id == selectedReceiverID })
    }

    private var selectedFixedDisplayPreset: VirtualDisplayPreset {
        VirtualDisplayPreset.preset(forID: selectedFixedDisplayPresetID) ?? .defaultFixed
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
            let selectedPathHost = selectedPath(for: selectedReceiver)?.host ?? selectedReceiver.host
            return (host: selectedPathHost, port: selectedReceiver.port)
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
            selectedReceiverPathIDs.removeAll()
            return
        }

        let validReceiverIDs = Set(receivers.map(\.id))
        selectedReceiverPathIDs = selectedReceiverPathIDs.filter { validReceiverIDs.contains($0.key) }

        for receiver in receivers {
            guard let defaultPath = receiver.pathOptions.first else { continue }
            if selectedReceiverPathIDs[receiver.id] == nil ||
                !receiver.pathOptions.contains(where: { $0.id == selectedReceiverPathIDs[receiver.id] }) {
                selectedReceiverPathIDs[receiver.id] = defaultPath.id
            }
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

    private func selectedPathID(for receiver: DiscoveredReceiver) -> String {
        selectedReceiverPathIDs[receiver.id] ?? receiver.pathOptions.first?.id ?? receiver.host
    }

    private func selectedPath(for receiver: DiscoveredReceiver) -> DiscoveryPathOption? {
        let currentPathID = selectedPathID(for: receiver)
        return receiver.pathOptions.first(where: { $0.id == currentPathID }) ?? receiver.pathOptions.first
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
        captureToEncodeLatencyText = formatRate(coordinator.captureToEncodeLatencyMilliseconds, unit: "ms")
        encodeToReceiveLatencyText = formatRate(coordinator.encodeToReceiveLatencyMilliseconds, unit: "ms")
        receiveToRenderLatencyText = formatRate(coordinator.receiveToRenderLatencyMilliseconds, unit: "ms")

        endpointSummary = coordinator.configuredEndpointSummary
        videoTransportText = coordinator.negotiatedVideoTransportMode.rawValue.uppercased()
        tcpVideoFramesSent = coordinator.tcpVideoFramesSent
        tcpVideoFramesDropped = coordinator.tcpVideoFramesDropped
        tcpCursorFramesSent = coordinator.tcpCursorFramesSent
        cursorDatagramMotionPacketsSent = coordinator.cursorDatagramMotionPacketsSent
        cursorDatagramQueuedPacketsSent = coordinator.cursorDatagramQueuedPacketsSent
        cursorDatagramQueuedPacketsDropped = coordinator.cursorDatagramQueuedPacketsDropped
        cursorDatagramPendingPackets = coordinator.cursorDatagramPendingPackets
        cursorDatagramSendErrors = coordinator.cursorDatagramSendErrors
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
        if useSideCursorOverlay != coordinator.useReceiverSideCursorOverlay {
            useSideCursorOverlay = coordinator.useReceiverSideCursorOverlay
        }
        if useDynamicCursorAppearanceMirroring != coordinator.useDynamicCursorAppearanceMirroring {
            useDynamicCursorAppearanceMirroring = coordinator.useDynamicCursorAppearanceMirroring
        }
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

    private var connectionSummaryText: String {
        switch coordinator.state {
        case .running:
            return "Connected"
        case .connected:
            return "Connected, waiting to start"
        case .waitingForAck:
            return "Connecting"
        case .connecting:
            return "Connecting"
        case .failed:
            return "Connection Failed"
        case .idle:
            return "Idle"
        }
    }

    private var connectionDetailText: String {
        switch coordinator.state {
        case .running, .connected, .waitingForAck, .connecting:
            let path = coordinator.wiredPathAvailable ? "Wired" : "Wireless"
            let cursorPath = coordinator.useReceiverSideCursorOverlay ? " + Cursor UDP" : ""
            return "\(path) via \(videoTransportText)\(cursorPath)"
        case .failed:
            return wiredPathSummary == "available" ? "Wired path available" : "Wireless or no wired path detected"
        case .idle:
            return wiredPathSummary == "available" ? "Ready on wired network" : "No wired path detected"
        }
    }

    private var cursorModeSummaryText: String {
        if coordinator.useReceiverSideCursorOverlay {
            return coordinator.useDynamicCursorAppearanceMirroring
                ? "Side Cursor Overlay + Shape Mirroring"
                : "Side Cursor Overlay + Arrow Cursor"
        }

        return "Native Cursor Capture"
    }
}

private struct ReceiverOptionRow: View {
    let receiver: DiscoveredReceiver
    let selectedPathID: String
    let isSelected: Bool
    let onSelectPath: (String) -> Void
    let onSelect: () -> Void

    var body: some View {
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
                Text(pathSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if receiver.prefersWiredPath {
                    Text("Wired")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }

                if receiver.pathOptions.count > 1 {
                    Menu {
                        ForEach(receiver.pathOptions, id: \.id) { option in
                            Button {
                                onSelectPath(option.id)
                            } label: {
                                if option.id == selectedPathID {
                                    Label(option.kind.discoveryLabel, systemImage: "checkmark")
                                } else {
                                    Text(option.kind.discoveryLabel)
                                }
                            }
                        }
                    } label: {
                        Label(selectedPathLabel, systemImage: "arrow.triangle.branch")
                            .font(.caption.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                }
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
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
    }

    private var backgroundStyle: some ShapeStyle {
        isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)
    }

    private var selectedPath: DiscoveryPathOption? {
        receiver.pathOptions.first(where: { $0.id == selectedPathID }) ?? receiver.pathOptions.first
    }

    private var selectedPathLabel: String {
        selectedPath?.kind.discoveryLabel ?? "Path"
    }

    private var pathSummaryText: String {
        guard let defaultPath = receiver.pathOptions.first else {
            return "Default: Unknown"
        }

        let alternateLabels = receiver.pathOptions.dropFirst().map(\.kind.discoveryLabel)
        if alternateLabels.isEmpty {
            return "Default: \(defaultPath.kind.discoveryLabel)"
        }

        return "Default: \(defaultPath.kind.discoveryLabel)  Also available: \(alternateLabels.joined(separator: ", "))"
    }
}

private struct ReceiverThumbnailView: View {
    let kind: DiscoveredReceiverVisualKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundGradient)

            if let systemIcon = ReceiverSystemIconCatalog.image(for: kind) {
                Image(nsImage: systemIcon)
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                fallbackArtwork
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    @ViewBuilder
    private var fallbackArtwork: some View {
        switch kind {
        case .imac:
            iMacArtwork
        case .macMini, .macStudio:
            desktopDisplayArtwork
        case .macbookAir:
            macBookArtwork
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

private enum ReceiverSystemIconCatalog {
    private static let basePath = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources"

    static func image(for kind: DiscoveredReceiverVisualKind) -> NSImage? {
        guard let path = iconPath(for: kind) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    private static func iconPath(for kind: DiscoveredReceiverVisualKind) -> String? {
        let fileName: String
        switch kind {
        case .imac:
            fileName = "com.apple.imac-2021-silver.icns"
        case .macMini:
            fileName = "com.apple.macmini-2020.icns"
        case .macStudio:
            fileName = "com.apple.macstudio.icns"
        case .macbookAir:
            fileName = "com.apple.macbookair-13-2022-space-gray.icns"
        case .studioDisplay:
            fileName = "com.apple.studio-display.icns"
        case .macbookPro:
            fileName = "com.apple.macbookpro-16-2021-space-gray.icns"
        case .display:
            fileName = "com.apple.pro-display-xdr.icns"
        }

        return "\(basePath)/\(fileName)"
    }
}
