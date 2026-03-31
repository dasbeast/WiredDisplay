import AppKit
import Combine
import Foundation

@MainActor
final class ReceiverAppController: ObservableObject {
    @Published private(set) var stateText = "idle"
    @Published private(set) var peerNameText = "-"
    @Published private(set) var receivedFrameCount: UInt64 = 0
    @Published private(set) var lastErrorText = "-"
    @Published private(set) var receivedFramesPerSecondText = "-"
    @Published private(set) var receivedMegabitsPerSecondText = "-"
    @Published private(set) var isStreaming = false
    @Published private(set) var interfaceLines: [String] = []
    @Published private(set) var wiredPathSummary = "unknown"
    @Published private(set) var discoverableName = Host.current().localizedName ?? "DisplayReceiver"
    @Published private(set) var advertisementErrorText: String?
    @Published private(set) var isReceiverWindowVisible = false
    @Published private(set) var powerManagementErrorText: String?
    @Published private(set) var cursorOverlayText = "-"
    @Published private(set) var cursorOverlayNormalizedX: Double?
    @Published private(set) var cursorOverlayNormalizedY: Double?
    @Published private(set) var isCursorOverlayVisible = false
    @Published private(set) var cursorOverlayImage: NSImage?
    @Published private(set) var cursorOverlayHotSpot: CGPoint?
    @Published private(set) var isReceiverWindowFullScreen = false

    let coordinator = ReceiverSessionCoordinator()
    let advertisementService = ReceiverAdvertisementService()
    let powerManagementService = ReceiverPowerManagementService()

    private let windowManager = ReceiverStreamWindowManager()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.refreshFromCoordinator()
            }
        }

        advertisementService.$advertisedName
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAdvertisementState()
            }
            .store(in: &cancellables)

        advertisementService.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshAdvertisementState()
            }
            .store(in: &cancellables)

        powerManagementService.$lastErrorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.powerManagementErrorText = message
            }
            .store(in: &cancellables)

        windowManager.onVisibilityChange = { [weak self] isVisible in
            guard let self else { return }
            Task { @MainActor in
                self.isReceiverWindowVisible = isVisible
                self.isReceiverWindowFullScreen = self.windowManager.isWindowFullScreen()
            }
        }

        start()
    }

    func start() {
        coordinator.startListening(port: NetworkProtocol.defaultPort)
        advertisementService.startAdvertising(
            port: NetworkProtocol.defaultPort,
            name: Host.current().localizedName ?? "DisplayReceiver"
        )
        refreshAdvertisementState()
        refreshFromCoordinator()
    }

    func presentReceiverWindow(fullScreen: Bool) {
        windowManager.present(appController: self, enterFullScreen: fullScreen)
        isReceiverWindowFullScreen = windowManager.isWindowFullScreen()
    }

    func hideReceiverWindow() {
        windowManager.hide()
        isReceiverWindowFullScreen = false
    }

    func toggleReceiverWindow() {
        if isReceiverWindowVisible {
            hideReceiverWindow()
        } else {
            presentReceiverWindow(fullScreen: false)
        }
    }

    func leaveReceiverFullScreen() {
        windowManager.leaveFullScreenIfNeeded()
        isReceiverWindowFullScreen = windowManager.isWindowFullScreen()
    }

    func quitApplication() {
        powerManagementService.stopPreventingSleep()
        NSApplication.shared.terminate(nil)
    }

    private func refreshAdvertisementState() {
        discoverableName = advertisementService.advertisedName ?? Host.current().localizedName ?? "DisplayReceiver"
        advertisementErrorText = advertisementService.lastErrorMessage
    }

    private func refreshFromCoordinator() {
        let newState = coordinator.state
        let wasStreaming = isStreaming
        let newStreaming = (newState == .running)

        stateText = statusText(for: newState)
        peerNameText = coordinator.peerName.isEmpty ? "-" : coordinator.peerName
        isStreaming = newStreaming
        receivedFrameCount = coordinator.receivedFrameCount
        lastErrorText = coordinator.lastErrorMessage ?? "-"
        receivedFramesPerSecondText = formatRate(coordinator.receivedFramesPerSecond, unit: "fps")
        receivedMegabitsPerSecondText = formatRate(coordinator.receivedMegabitsPerSecond, unit: "Mbps")
        wiredPathSummary = coordinator.wiredPathAvailable ? "available" : "not available"
        interfaceLines = coordinator.localInterfaceDescriptions
        cursorOverlayText = coordinator.cursorOverlaySummary
        cursorOverlayNormalizedX = coordinator.cursorOverlayNormalizedX
        cursorOverlayNormalizedY = coordinator.cursorOverlayNormalizedY
        isCursorOverlayVisible = coordinator.isCursorOverlayVisible
        cursorOverlayImage = coordinator.cursorOverlayImage
        cursorOverlayHotSpot = coordinator.cursorOverlayHotSpot

        if newStreaming && !wasStreaming {
            powerManagementService.startPreventingSleep()
            presentReceiverWindow(fullScreen: true)
        } else if !newStreaming && wasStreaming {
            powerManagementService.stopPreventingSleep()
            hideReceiverWindow()
        }
        isReceiverWindowFullScreen = windowManager.isWindowFullScreen()
    }

    private func statusText(for state: ReceiverSessionCoordinator.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .listening:
            return "listening (waiting for sender)"
        case .running:
            return "streaming"
        case .failed(let message):
            return "failed: \(message)"
        }
    }

    private func formatRate(_ value: Double?, unit: String) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f %@", value, unit)
    }
}
