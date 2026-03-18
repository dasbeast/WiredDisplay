import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class DisplaySenderUpdater: ObservableObject {
    private static let feedURLPlaceholder = "https://example.com/displaysender/appcast.xml"
    private static let publicKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED25519_KEY"

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
            configurationError =
                "Configure SUFeedURL and SUPublicEDKey in DisplaySender build settings to enable updates."
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
            value != feedURLPlaceholder,
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "https"
        else {
            return false
        }

        return true
    }

    private static func isValidPublicEDKey(_ value: String?) -> Bool {
        guard let value, !value.isEmpty, value != publicKeyPlaceholder else {
            return false
        }

        return true
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
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

struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater?

    init(updater: SPUUpdater?) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…") {
            updater?.checkForUpdates()
        }
        .disabled(updater == nil || !viewModel.canCheckForUpdates)
    }
}

struct UpdaterSettingsView: View {
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

                CheckForUpdatesView(updater: updater)
            }

            if let configurationError {
                Section("Configuration") {
                    Text(configurationError)
                        .foregroundStyle(.secondary)
                    Text("Current implementation is ready, but Sparkle will stay disabled until those Info.plist values are replaced with production values.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .padding()
        .frame(width: 420)
    }
}
