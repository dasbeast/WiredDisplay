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
