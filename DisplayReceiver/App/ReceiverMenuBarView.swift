import AppKit
import AVFoundation
import SwiftUI

struct ReceiverMenuBarView: View {
    @ObservedObject var appController: ReceiverAppController
    @ObservedObject var updater: DisplayReceiverUpdater
    @AppStorage(NetworkProtocol.cursorPredictionDefaultsKey)
    private var enableCursorPrediction = true
    @AppStorage(NetworkProtocol.cursorPredictionStrengthDefaultsKey)
    private var cursorPredictionStrength = 0.75

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appController.discoverableName)
                    .font(.headline)
                Text(appController.stateText)
                    .foregroundStyle(.secondary)
            }

            if appController.isStreaming {
                VStack(alignment: .leading, spacing: 4) {
                    if appController.isCaptureCardMode {
                        if let name = appController.captureDeviceName {
                            Text("Device: \(name)")
                        }
                    } else {
                        Text("Peer: \(appController.peerNameText)")
                        Text("Cursor RX Rate: \(appController.cursorPacketsReceivedPerSecondText)")
                        Text("Throughput: \(appController.receivedMegabitsPerSecondText)")
                    }
                    Text("Frames: \(appController.receivedFrameCount)")
                    Text("Rate: \(appController.receivedFramesPerSecondText)")
                }
                .font(.subheadline)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wired Path: \(appController.wiredPathSummary)")
                    if !appController.interfaceLines.isEmpty {
                        ForEach(appController.interfaceLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let advertisementErrorText = appController.advertisementErrorText {
                Text(advertisementErrorText)
                    .foregroundStyle(.orange)
            }

            if let powerManagementErrorText = appController.powerManagementErrorText {
                Text(powerManagementErrorText)
                    .foregroundStyle(.orange)
            }

            if appController.lastErrorText != "-" {
                Text(appController.lastErrorText)
                    .foregroundStyle(.red)
            }

            Divider()

            Button(appController.isReceiverWindowVisible ? "Hide Receiver Window" : "Open Receiver Window") {
                appController.toggleReceiverWindow()
            }

            Button(appController.isStatsWindowVisible ? "Show Stats for Nerds" : "Stats for Nerds") {
                appController.presentStatsWindow()
            }

            if appController.isStreaming {
                Button("Bring Stream Full Screen") {
                    appController.presentReceiverWindow(fullScreen: true)
                }
                if appController.isReceiverWindowFullScreen {
                    Button("Leave Full Screen") {
                        appController.leaveReceiverFullScreen()
                    }
                }
            }

            Divider()

            InputSourceSection(appController: appController)

            Divider()

            if !appController.isCaptureCardMode {
                Toggle("Predict Cursor Motion", isOn: $enableCursorPrediction)

                if enableCursorPrediction {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Prediction Strength")
                            Spacer()
                            Text("\(Int(cursorPredictionStrength * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $cursorPredictionStrength, in: 0...1)
                        Text("Lower values reduce overshoot. Higher values feel snappier.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
            }

            DisplayReceiverCheckForUpdatesView(updater: updater.updater)

            Divider()

            Button("Quit DisplayReceiver") {
                appController.quitApplication()
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 280, alignment: .leading)
    }
}

struct ReceiverStatsWindowView: View {
    @ObservedObject var appController: ReceiverAppController
    @ObservedObject private var diagnostics = ReceiverDiagnosticsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stats for Nerds")
                        .font(.title2.weight(.semibold))
                    Text(appController.isCaptureCardMode ? "Capture card diagnostics" : "Network stream diagnostics")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyStats()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(title: "Input", value: appController.isCaptureCardMode ? "Capture Card" : "Network")
                StatTile(title: "State", value: appController.stateText)
                StatTile(title: "Frames", value: "\(appController.receivedFrameCount)")
                StatTile(title: "Rate", value: appController.receivedFramesPerSecondText)
                StatTile(title: "Throughput", value: appController.receivedMegabitsPerSecondText)
                StatTile(title: "Frame", value: diagnostics.latestFrameText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Pacing")
                    .font(.headline)
                DiagnosticLine(title: "Capture", value: diagnostics.capturePacingText)
                DiagnosticLine(title: "Display", value: diagnostics.drawPacingText)
                if !appController.isCaptureCardMode {
                    DiagnosticLine(title: "Cursor", value: appController.cursorPacketsReceivedPerSecondText)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Latency Notes")
                    .font(.headline)
                Text("These stats show whether our app is keeping a fresh 60 fps capture-to-display pipeline. Console button-to-photon lag still needs an external test, because macOS never sees the moment your controller input happened.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent Logs")
                        .font(.headline)
                    Spacer()
                    Text("Last update \(diagnostics.lastUpdated.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(diagnostics.recentLogLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(18)
        .frame(minWidth: 430, minHeight: 420)
    }

    private func copyStats() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics.exportText, forType: .string)
    }
}

private struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DiagnosticLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct InputSourceSection: View {
    @ObservedObject var appController: ReceiverAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input Source")
                .font(.subheadline.weight(.medium))

            // Network stream option
            Button {
                if appController.isCaptureCardMode {
                    appController.switchToNetworkStream()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appController.isCaptureCardMode ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(appController.isCaptureCardMode ? Color.secondary : Color.accentColor)
                    Text("Network Stream (DisplaySender)")
                }
            }
            .buttonStyle(.plain)

            // Capture card options — one per detected device
            if appController.availableCaptureDevices.isEmpty {
                Text("No capture devices detected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 22)
            } else {
                ForEach(appController.availableCaptureDevices, id: \.uniqueID) { device in
                    let isActive = appController.isCaptureCardMode &&
                        appController.captureDeviceName == device.localizedName
                    let selectedResolution = appController.preferredCaptureResolution(for: device)
                    Button {
                        appController.startCaptureCard(device: device, resolution: selectedResolution)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                            Text(device.localizedName)
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(appController.captureResolutions(for: device)) { resolution in
                        let isSelected = appController.preferredCaptureResolution(for: device) == resolution
                        Button {
                            appController.setCaptureResolution(resolution, for: device)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isSelected ? "checkmark" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                Text(resolution.label)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 22)
                    }
                }
            }
        }
    }
}
