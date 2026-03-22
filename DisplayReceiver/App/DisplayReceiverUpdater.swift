import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class DisplayReceiverUpdater: ObservableObject {
    let updaterController: SPUStandardUpdaterController?
    let configurationError: String?

    var updater: SPUUpdater? {
        updaterController?.updater
    }

    init(bundle: Bundle = .main) {
        let feedURLString = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicEDKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String

        guard Self.isValidFeedURL(feedURLString), Self.isValidPublicEDKey(publicEDKey) else {
            updaterController = nil
            configurationError = "Configure SUFeedURL and SUPublicEDKey in DisplayReceiver/Info.plist to enable updates."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        configurationError = nil
        controller.startUpdater()
    }

    private static func isValidFeedURL(_ value: String?) -> Bool {
        guard
            let value,
            !value.isEmpty,
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "https"
        else {
            return false
        }

        return true
    }

    private static func isValidPublicEDKey(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else {
            return false
        }

        return true
    }
}

@MainActor
final class DisplayReceiverCheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater?) {
        guard let updater else {
            return
        }

        canCheckForUpdates = updater.canCheckForUpdates
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheckForUpdates in
                self?.canCheckForUpdates = canCheckForUpdates
            }
    }
}

struct DisplayReceiverCheckForUpdatesView: View {
    @StateObject private var viewModel: DisplayReceiverCheckForUpdatesViewModel
    private let updater: SPUUpdater?

    init(updater: SPUUpdater?) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: DisplayReceiverCheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater?.checkForUpdates()
        }
        .disabled(updater == nil || !viewModel.canCheckForUpdates)
    }
}

struct DisplayReceiverUpdaterSettingsView: View {
    private let updater: SPUUpdater?
    private let configurationError: String?

    @State private var automaticallyChecksForUpdates = false
    @State private var automaticallyDownloadsUpdates = false

    init(updater: SPUUpdater?, configurationError: String?) {
        self.updater = updater
        self.configurationError = configurationError
        _automaticallyChecksForUpdates = State(initialValue: updater?.automaticallyChecksForUpdates ?? false)
        _automaticallyDownloadsUpdates = State(initialValue: updater?.automaticallyDownloadsUpdates ?? false)
    }

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .disabled(updater == nil)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        updater?.automaticallyChecksForUpdates = newValue
                    }

                Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                    .disabled(updater == nil || !automaticallyChecksForUpdates)
                    .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                        updater?.automaticallyDownloadsUpdates = newValue
                    }

                DisplayReceiverCheckForUpdatesView(updater: updater)
            }

            if let configurationError {
                Section("Configuration") {
                    Text(configurationError)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 420)
    }
}
