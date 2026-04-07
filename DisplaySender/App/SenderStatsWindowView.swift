import Combine
import Foundation
import SwiftUI

struct SenderStatsWindowView: View {
    private let coordinator = SenderRuntime.coordinator
    private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

    @State private var snapshot = SenderStatsSnapshot()
    @State private var placedWindowNumber: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Status") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("State: \(snapshot.stateText)")
                        Text("Connection: \(snapshot.connectionText)")
                        Text("Sent Frames: \(snapshot.sentFrameCount)")
                        Text("Dropped Outbound Frames: \(snapshot.droppedOutboundFrameCount)")
                        Text("TCP Video Frames Sent: \(snapshot.tcpVideoFramesSent)")
                        Text("TCP Video Frames Dropped: \(snapshot.tcpVideoFramesDropped)")
                        Text("TCP Cursor Frames Sent: \(snapshot.tcpCursorFramesSent)")
                        Text("Cursor UDP Motion Packets Sent: \(snapshot.cursorDatagramMotionPacketsSent)")
                        Text("Cursor UDP Queued Packets Sent: \(snapshot.cursorDatagramQueuedPacketsSent)")
                        Text("Cursor UDP Queued Packets Dropped: \(snapshot.cursorDatagramQueuedPacketsDropped)")
                        Text("Cursor UDP Pending Packets: \(snapshot.cursorDatagramPendingPackets)")
                        Text("Cursor UDP Send Errors: \(snapshot.cursorDatagramSendErrors)")
                        Text("Cursor Refresh Driver Mode: \(snapshot.cursorRefreshDriverMode)")
                        Text("Cursor Refresh Source Callbacks: \(snapshot.cursorRefreshSourceCallbacksPerSecondText)")
                        Text("Cursor Display-Link Callbacks: \(snapshot.cursorDisplayLinkCallbacksPerSecondText)")
                        Text("Cursor Main-Actor Refresh Ticks: \(snapshot.cursorRefreshTicksPerSecondText)")
                        Text("Cursor Poll Requests: \(snapshot.cursorPollRequestsPerSecondText)")
                        Text("Cursor Poll Executions: \(snapshot.cursorPollExecutionsPerSecondText)")
                        Text("Cursor Poll Coalesced: \(snapshot.cursorPollCoalescedPerSecondText)")
                        Text("Cursor Packets Suppressed: \(snapshot.cursorPacketsSuppressedPerSecondText)")
                        Text("Cursor Packets Sent Rate: \(snapshot.cursorPacketsSentPerSecondText)")
                        Text("Send Rate: \(snapshot.sentFramesPerSecondText)")
                        Text("Send Throughput: \(snapshot.sentMegabitsPerSecondText)")
                        Text("Heartbeat RTT: \(snapshot.heartbeatRoundTripText)")
                        Text("Est. Display Latency: \(snapshot.estimatedDisplayLatencyText)")
                        Text("Capture -> Encode: \(snapshot.captureToEncodeLatencyText)")
                        Text("Encode -> Receive: \(snapshot.encodeToReceiveLatencyText)")
                        Text("Receive -> Render: \(snapshot.receiveToRenderLatencyText)")
                    }
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Configured Endpoint: \(snapshot.configuredEndpointSummary)")
                        Text("Video Transport: \(snapshot.videoTransportText)")
                        Text("Display Resolution: \(snapshot.displayResolutionSummaryText)")
                        Text("Streaming Pipeline: \(snapshot.streamingPipelineSummaryText)")
                        Text("Cursor Mode: \(snapshot.cursorModeSummaryText)")
                        Text("Negotiated Display: \(snapshot.negotiatedDisplayText)")
                        Text("Wired Path: \(snapshot.wiredPathText)")

                        if !snapshot.wiredWarning.isEmpty {
                            Text(snapshot.wiredWarning)
                                .foregroundStyle(.orange)
                        }

                        if snapshot.localInterfaceDescriptions.isEmpty {
                            Text("Local Interfaces: none detected")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Local Interfaces:")
                            ForEach(snapshot.localInterfaceDescriptions, id: \.self) { line in
                                Text(line)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(minWidth: 420, minHeight: 620)
        .navigationTitle("Stats for Nerds")
        .background(
            SenderStatsWindowAccessor { window in
                moveWindowOffCapturedDisplayIfNeeded(window)
            }
        )
        .onAppear {
            refreshSnapshot()
        }
        .onReceive(refreshTimer) { _ in
            refreshSnapshot()
        }
    }

    private func refreshSnapshot() {
        snapshot = SenderStatsSnapshot(coordinator: coordinator)
    }

    private func moveWindowOffCapturedDisplayIfNeeded(_ window: NSWindow) {
        let capturedDisplayID = coordinator.activeVirtualDisplayID
        guard capturedDisplayID != 0 else { return }
        guard window.screen?.displayID == capturedDisplayID else { return }

        let isFirstPlacementForWindow = placedWindowNumber != window.windowNumber
        if isFirstPlacementForWindow {
            placedWindowNumber = window.windowNumber
        }

        guard isFirstPlacementForWindow || window.screen?.displayID == capturedDisplayID else { return }
        guard let targetScreen = preferredLocalScreen(for: window, avoiding: capturedDisplayID) else { return }

        let visibleFrame = targetScreen.visibleFrame
        let windowSize = window.frame.size
        let nextOrigin = CGPoint(
            x: visibleFrame.midX - (windowSize.width / 2),
            y: visibleFrame.midY - (windowSize.height / 2)
        )
        let nextFrame = CGRect(origin: nextOrigin, size: windowSize)
        window.setFrame(nextFrame, display: true, animate: false)
        print("[Sender] Moved stats window off captured display \(capturedDisplayID)")
    }

    private func preferredLocalScreen(for window: NSWindow, avoiding capturedDisplayID: CGDirectDisplayID) -> NSScreen? {
        if let siblingScreen = NSApp.windows.first(where: { candidate in
            candidate !== window &&
                candidate.isVisible &&
                candidate.screen?.displayID != capturedDisplayID
        })?.screen {
            return siblingScreen
        }

        return NSScreen.screens.first(where: { $0.displayID != capturedDisplayID })
    }
}

private struct SenderStatsWindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onResolveWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onResolveWindow(window)
            }
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

private struct SenderStatsSnapshot {
    var stateText = "idle"
    var connectionText = "not_connected"
    var sentFrameCount: UInt64 = 0
    var droppedOutboundFrameCount: UInt64 = 0
    var tcpVideoFramesSent: UInt64 = 0
    var tcpVideoFramesDropped: UInt64 = 0
    var tcpCursorFramesSent: UInt64 = 0
    var cursorDatagramMotionPacketsSent: UInt64 = 0
    var cursorDatagramQueuedPacketsSent: UInt64 = 0
    var cursorDatagramQueuedPacketsDropped: UInt64 = 0
    var cursorDatagramPendingPackets: Int = 0
    var cursorDatagramSendErrors: UInt64 = 0
    var cursorRefreshDriverMode = "-"
    var cursorRefreshSourceCallbacksPerSecondText = "-"
    var cursorDisplayLinkCallbacksPerSecondText = "-"
    var cursorRefreshTicksPerSecondText = "-"
    var cursorPollRequestsPerSecondText = "-"
    var cursorPollExecutionsPerSecondText = "-"
    var cursorPollCoalescedPerSecondText = "-"
    var cursorPacketsSuppressedPerSecondText = "-"
    var cursorPacketsSentPerSecondText = "-"
    var sentFramesPerSecondText = "-"
    var sentMegabitsPerSecondText = "-"
    var heartbeatRoundTripText = "-"
    var estimatedDisplayLatencyText = "-"
    var captureToEncodeLatencyText = "-"
    var encodeToReceiveLatencyText = "-"
    var receiveToRenderLatencyText = "-"
    var configuredEndpointSummary = "-"
    var videoTransportText = "TCP"
    var displayResolutionSummaryText = "-"
    var streamingPipelineSummaryText = "-"
    var cursorModeSummaryText = "-"
    var negotiatedDisplayText = "-"
    var wiredPathText = "unknown"
    var wiredWarning = ""
    var localInterfaceDescriptions: [String] = []

    @MainActor
    init(coordinator: SenderSessionCoordinator? = nil) {
        guard let coordinator else { return }

        stateText = statusText(for: coordinator.state)
        connectionText = connectionText(for: coordinator.state)
        sentFrameCount = coordinator.sentFrameCount
        droppedOutboundFrameCount = coordinator.droppedOutboundFrameCount
        tcpVideoFramesSent = coordinator.tcpVideoFramesSent
        tcpVideoFramesDropped = coordinator.tcpVideoFramesDropped
        tcpCursorFramesSent = coordinator.tcpCursorFramesSent
        cursorDatagramMotionPacketsSent = coordinator.cursorDatagramMotionPacketsSent
        cursorDatagramQueuedPacketsSent = coordinator.cursorDatagramQueuedPacketsSent
        cursorDatagramQueuedPacketsDropped = coordinator.cursorDatagramQueuedPacketsDropped
        cursorDatagramPendingPackets = coordinator.cursorDatagramPendingPackets
        cursorDatagramSendErrors = coordinator.cursorDatagramSendErrors
        cursorRefreshDriverMode = coordinator.cursorRefreshDriverMode
        cursorRefreshSourceCallbacksPerSecondText = formatRate(coordinator.cursorRefreshSourceCallbacksPerSecond, unit: "fps")
        cursorDisplayLinkCallbacksPerSecondText = formatRate(coordinator.cursorDisplayLinkCallbacksPerSecond, unit: "fps")
        cursorRefreshTicksPerSecondText = formatRate(coordinator.cursorRefreshTicksPerSecond, unit: "fps")
        cursorPollRequestsPerSecondText = formatRate(coordinator.cursorPollRequestsPerSecond, unit: "fps")
        cursorPollExecutionsPerSecondText = formatRate(coordinator.cursorPollExecutionsPerSecond, unit: "fps")
        cursorPollCoalescedPerSecondText = formatRate(coordinator.cursorPollCoalescedPerSecond, unit: "fps")
        cursorPacketsSuppressedPerSecondText = formatRate(coordinator.cursorPacketsSuppressedPerSecond, unit: "fps")
        cursorPacketsSentPerSecondText = formatRate(coordinator.cursorPacketsSentPerSecond, unit: "fps")
        sentFramesPerSecondText = formatRate(coordinator.sentFramesPerSecond, unit: "fps")
        sentMegabitsPerSecondText = formatRate(coordinator.sentMegabitsPerSecond, unit: "Mbps")
        heartbeatRoundTripText = formatRate(coordinator.heartbeatRoundTripMilliseconds, unit: "ms")
        estimatedDisplayLatencyText = formatRate(coordinator.estimatedDisplayLatencyMilliseconds, unit: "ms")
        captureToEncodeLatencyText = formatRate(coordinator.captureToEncodeLatencyMilliseconds, unit: "ms")
        encodeToReceiveLatencyText = formatRate(coordinator.encodeToReceiveLatencyMilliseconds, unit: "ms")
        receiveToRenderLatencyText = formatRate(coordinator.receiveToRenderLatencyMilliseconds, unit: "ms")
        configuredEndpointSummary = coordinator.configuredEndpointSummary
        videoTransportText = coordinator.negotiatedVideoTransportMode.rawValue.uppercased()
        switch coordinator.displayResolutionPreference {
        case .matchReceiver:
            displayResolutionSummaryText = "Match Receiver"
        case .fixedPreset:
            displayResolutionSummaryText = "Fixed \(coordinator.preferredDisplayPreset.label)"
        }
        streamingPipelineSummaryText =
            "\(coordinator.streamingPipelinePreference.label) -> \(coordinator.resolvedStreamingPipelineMode.label)"
        if coordinator.useReceiverSideCursorOverlay {
            cursorModeSummaryText = coordinator.useDynamicCursorAppearanceMirroring
                ? "Side Cursor Overlay + Shape Mirroring"
                : "Side Cursor Overlay + Arrow Cursor"
        } else {
            cursorModeSummaryText = "Native Cursor Capture"
        }
        negotiatedDisplayText = "\(coordinator.targetWidth)x\(coordinator.targetHeight)"
        wiredPathText = coordinator.wiredPathAvailable ? "available" : "not available"
        wiredWarning = coordinator.wiredPathAvailable
            ? ""
            : "No wired route currently available. Verify Thunderbolt Bridge and cable link."
        localInterfaceDescriptions = coordinator.localInterfaceDescriptions
    }

    private func formatRate(_ value: Double?, unit: String) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f %@", value, unit)
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
}
