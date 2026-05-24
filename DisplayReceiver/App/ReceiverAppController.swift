import AppKit
import AVFoundation
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
    @Published private(set) var cursorPacketsReceivedPerSecondText = "-"
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
    @Published private(set) var availableCaptureDevices: [AVCaptureDevice] = []
    @Published private(set) var captureDeviceName: String?
    @Published private(set) var selectedCaptureResolution: CaptureCardResolution?
    @Published private(set) var isCaptureCardMode = false
    @Published private(set) var cameraPermissionDenied = false
    @Published private(set) var captureCardHasAudio = false
    @Published private(set) var captureCardAudioMuted = false

    let coordinator = ReceiverSessionCoordinator()
    let advertisementService = ReceiverAdvertisementService()
    let powerManagementService = ReceiverPowerManagementService()

    private let windowManager = ReceiverStreamWindowManager()
    private let captureResolutionDefaultsKeyPrefix = "DisplayReceiver.captureResolution."
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

        NotificationCenter.default.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleSystemWillSleep()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleSystemDidWake()
            }
            .store(in: &cancellables)

        windowManager.onVisibilityChange = { [weak self] isVisible in
            guard let self else { return }
            Task { @MainActor in
                self.isReceiverWindowVisible = isVisible
                self.isReceiverWindowFullScreen = self.windowManager.isWindowFullScreen()
            }
        }
        windowManager.onCloseRequest = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleReceiverWindowCloseRequest()
            }
        }

        NotificationCenter.default.publisher(for: .receiverReopenMainWindow)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.presentReceiverWindow(fullScreen: false)
            }
            .store(in: &cancellables)

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
        // Defer past the SwiftUI @StateObject initialization cycle so that
        // the onVisibilityChange @Published write doesn't land during a view update.
        Task { @MainActor in
            self.presentReceiverWindow(fullScreen: false)
        }
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

    func captureResolutions(for device: AVCaptureDevice) -> [CaptureCardResolution] {
        CaptureCardService.availableResolutions(for: device)
    }

    func preferredCaptureResolution(for device: AVCaptureDevice) -> CaptureCardResolution? {
        let resolutions = captureResolutions(for: device)
        if let selectedCaptureResolution,
           captureDeviceName == device.localizedName,
           resolutions.contains(selectedCaptureResolution) {
            return selectedCaptureResolution
        }
        if let savedResolution = savedCaptureResolution(for: device),
           resolutions.contains(savedResolution) {
            return savedResolution
        }
        return resolutions.first
    }

    func startCaptureCard(device: AVCaptureDevice, resolution: CaptureCardResolution? = nil) {
        let preferredResolution = resolution ?? preferredCaptureResolution(for: device)
        if let preferredResolution {
            saveCaptureResolution(preferredResolution, for: device)
        }
        coordinator.startCaptureCard(
            device: device,
            preferredResolution: preferredResolution
        )
        refreshFromCoordinator()
    }

    func setCaptureResolution(_ resolution: CaptureCardResolution, for device: AVCaptureDevice) {
        saveCaptureResolution(resolution, for: device)
        coordinator.startCaptureCard(device: device, preferredResolution: resolution)
        refreshFromCoordinator()
    }

    func switchToNetworkStream() {
        coordinator.switchToNetworkStream()
        refreshFromCoordinator()
    }

    func toggleCaptureCardAudioMute() {
        coordinator.toggleCaptureCardAudioMute()
        refreshFromCoordinator()
    }

    private func refreshAdvertisementState() {
        discoverableName = advertisementService.advertisedName ?? Host.current().localizedName ?? "DisplayReceiver"
        advertisementErrorText = advertisementService.lastErrorMessage
    }

    private func handleReceiverWindowCloseRequest() {
        if isCaptureCardMode {
            switchToNetworkStream()
        }
        hideReceiverWindow()
    }

    private func savedCaptureResolution(for device: AVCaptureDevice) -> CaptureCardResolution? {
        guard let id = UserDefaults.standard.string(forKey: captureResolutionDefaultsKey(for: device)) else {
            return nil
        }
        let parts = id.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return nil
        }
        return CaptureCardResolution(width: width, height: height)
    }

    private func saveCaptureResolution(_ resolution: CaptureCardResolution, for device: AVCaptureDevice) {
        UserDefaults.standard.set(resolution.id, forKey: captureResolutionDefaultsKey(for: device))
    }

    private func captureResolutionDefaultsKey(for device: AVCaptureDevice) -> String {
        captureResolutionDefaultsKeyPrefix + device.uniqueID
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
        cursorPacketsReceivedPerSecondText = formatRate(coordinator.cursorPacketsReceivedPerSecond, unit: "fps")
        wiredPathSummary = coordinator.wiredPathAvailable ? "available" : "not available"
        interfaceLines = coordinator.localInterfaceDescriptions
        cursorOverlayText = coordinator.cursorOverlaySummary
        cursorOverlayNormalizedX = coordinator.cursorOverlayNormalizedX
        cursorOverlayNormalizedY = coordinator.cursorOverlayNormalizedY
        isCursorOverlayVisible = coordinator.isCursorOverlayVisible
        cursorOverlayImage = coordinator.cursorOverlayImage
        cursorOverlayHotSpot = coordinator.cursorOverlayHotSpot
        availableCaptureDevices = coordinator.availableCaptureDevices
        captureDeviceName = coordinator.captureDeviceName
        selectedCaptureResolution = coordinator.selectedCaptureResolution
        cameraPermissionDenied = coordinator.cameraPermissionDenied
        captureCardHasAudio = coordinator.captureCardHasAudio
        captureCardAudioMuted = coordinator.captureCardAudioMuted
        if case .captureCard = coordinator.inputMode {
            isCaptureCardMode = true
        } else {
            isCaptureCardMode = false
        }

        if newStreaming {
            if !powerManagementService.isPreventingSleep {
                powerManagementService.startPreventingSleep()
            }
        } else if wasStreaming {
            powerManagementService.stopPreventingSleep()
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

    private func handleSystemWillSleep() {
        guard powerManagementService.isPreventingSleep else { return }
        powerManagementService.stopPreventingSleep()
    }

    private func handleSystemDidWake() {
        refreshFromCoordinator()
    }
}
