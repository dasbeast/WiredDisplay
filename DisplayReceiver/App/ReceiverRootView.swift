import AppKit
import AVFoundation
import Foundation
import SwiftUI

struct ReceiverRootView: View {
    @ObservedObject var appController: ReceiverAppController

    var body: some View {
        ZStack {
            // Metal surface always mounted so the cursor host and frame pipeline
            // stay ready; hidden behind the connect page when not streaming.
            MetalRenderSurfaceView()
                .ignoresSafeArea()
                .opacity(appController.isStreaming ? 1 : 0)

            if !appController.isStreaming {
                ReceiverConnectPageView(appController: appController)
                    .transition(.opacity)
            }

            if appController.isStreaming, appController.isCaptureCardMode,
               let name = appController.captureDeviceName {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                            if appController.captureCardHasAudio {
                                Button {
                                    appController.toggleCaptureCardAudioMute()
                                } label: {
                                    Image(systemName: appController.captureCardAudioMuted
                                          ? "speaker.slash.fill"
                                          : "speaker.wave.2.fill")
                                        .font(.caption)
                                        .foregroundStyle(appController.captureCardAudioMuted
                                                         ? Color.orange
                                                         : .white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appController.isStreaming)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appController.isStreaming ? .black : Color(.windowBackgroundColor))
    }
}

private struct ReceiverConnectPageView: View {
    @ObservedObject var appController: ReceiverAppController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: "display.2")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DisplayReceiver")
                            .font(.title2.bold())
                        Text(appController.stateText)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                // Connection info
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Discoverable As") {
                            Text(appController.discoverableName)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        LabeledContent("Wired Path") {
                            Text(appController.wiredPathSummary)
                                .foregroundStyle(
                                    appController.wiredPathSummary == "available" ? Color.green : Color.secondary
                                )
                        }
                    }
                    .padding(4)
                } label: {
                    Label("Connection", systemImage: "network")
                        .font(.subheadline.weight(.medium))
                }

                // Network interfaces
                if !appController.interfaceLines.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(appController.interfaceLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        Label("Network Interfaces", systemImage: "cable.connector.horizontal")
                            .font(.subheadline.weight(.medium))
                    }
                }

                // Input source
                GroupBox {
                    ConnectPageInputSourceView(appController: appController)
                        .padding(4)
                } label: {
                    Label("Input Source", systemImage: "cable.connector")
                        .font(.subheadline.weight(.medium))
                }

                // Errors
                if let advertisementError = appController.advertisementErrorText {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(advertisementError)
                            .foregroundStyle(.orange)
                    }
                }
                if let powerManagementError = appController.powerManagementErrorText {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(powerManagementError)
                            .foregroundStyle(.orange)
                    }
                }
                if appController.lastErrorText != "-" {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(appController.lastErrorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }
}

private struct ConnectPageInputSourceView: View {
    @ObservedObject var appController: ReceiverAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Camera permission denied banner
            if appController.cameraPermissionDenied {
                HStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Camera access denied")
                            .fontWeight(.medium)
                            .foregroundStyle(.orange)
                        Text("DisplayReceiver needs camera access to use capture cards.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
                        )
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Divider()
            }

            // Network stream row
            Button {
                if appController.isCaptureCardMode {
                    appController.switchToNetworkStream()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: appController.isCaptureCardMode ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(appController.isCaptureCardMode ? Color.secondary : Color.accentColor)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Network Stream")
                            .fontWeight(.medium)
                        Text("Receive from DisplaySender over Thunderbolt / USB-C")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            // Capture card rows
            if appController.availableCaptureDevices.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "circle")
                        .foregroundStyle(Color.secondary)
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Capture Card")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text("No capture devices detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(Array(appController.availableCaptureDevices.enumerated()), id: \.element.uniqueID) { index, device in
                    let isActive = appController.isCaptureCardMode &&
                        appController.captureDeviceName == device.localizedName
                    let resolutions = appController.captureResolutions(for: device)
                    let selectedResolution = appController.preferredCaptureResolution(for: device)
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Button {
                            appController.startCaptureCard(device: device, resolution: selectedResolution)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                                    .font(.system(size: 16))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.localizedName)
                                        .fontWeight(.medium)
                                    Text("Capture card · zero-latency raw input")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !resolutions.isEmpty {
                            Picker("Resolution", selection: captureResolutionBinding(for: device)) {
                                ForEach(resolutions) { resolution in
                                    Text(resolution.label).tag(Optional(resolution))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 110)
                        }
                    }
                }
            }
        }
    }

    private func captureResolutionBinding(for device: AVCaptureDevice) -> Binding<CaptureCardResolution?> {
        Binding {
            appController.preferredCaptureResolution(for: device)
        } set: { resolution in
            guard let resolution else { return }
            appController.setCaptureResolution(resolution, for: device)
        }
    }
}
