import AppKit
import SwiftUI
import MetalKit
import MetalFX
import CoreVideo

/// Metal-backed surface that renders the most recent decoded YUV (bi-planar 420v) frame.
/// Two-pass pipeline:
///   Pass 1 — YUV→RGB quad rendered to an offscreen intermediate texture (source resolution).
///   Pass 2 — MetalFX Spatial Scaler upscales intermediate texture → drawable (display resolution).
struct MetalRenderSurfaceView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ReceiverRenderContainerView {
        let view = ReceiverRenderContainerView(device: MTLCreateSystemDefaultDevice())
        view.metalView.delegate = context.coordinator
        context.coordinator.attach(to: view.metalView)
        view.refreshCursorOverlayConfiguration()
        return view
    }

    func updateNSView(_ nsView: ReceiverRenderContainerView, context: Context) {
        nsView.refreshCursorOverlayConfiguration()
        _ = nsView
        _ = context
    }

    final class ReceiverRenderContainerView: NSView {
        let metalView: MTKView
        private let cursorOverlayView = ReceiverCursorOverlayHostView()

        init(device: MTLDevice?) {
            metalView = MTKView(frame: .zero, device: device)
            super.init(frame: .zero)

            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor

            metalView.enableSetNeedsDisplay = false
            metalView.isPaused = false
            metalView.preferredFramesPerSecond = 60
            metalView.clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.framebufferOnly = false
            metalView.autoresizingMask = [.width, .height]
            metalView.frame = bounds
            addSubview(metalView)

            cursorOverlayView.autoresizingMask = [.width, .height]
            cursorOverlayView.frame = bounds
            addSubview(cursorOverlayView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layout() {
            super.layout()
            metalView.frame = bounds
            cursorOverlayView.frame = bounds
            cursorOverlayView.refreshPresentationIfNeeded()
        }

        func refreshCursorOverlayConfiguration() {
            cursorOverlayView.refreshConfiguration()
        }
    }

    final class ReceiverCursorOverlayHostView: NSView {
        private static let transparentCursorImage: NSImage = {
            let image = NSImage(size: NSSize(width: 16, height: 16))
            image.lockFocus()
            NSColor.clear.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
            image.unlockFocus()
            return image
        }()

        private static let displayLinkCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userData in
            guard let userData else { return kCVReturnError }
            let view = Unmanaged<ReceiverCursorOverlayHostView>.fromOpaque(userData).takeUnretainedValue()
            view.scheduleDisplayLinkedRefresh()
            return kCVReturnSuccess
        }

        override var isFlipped: Bool { true }

        private let cursorImageView = NSImageView(frame: .zero)
        private var refreshTimer: DispatchSourceTimer?
        private var displayLink: CVDisplayLink?
        private var displayLinkDisplayID: CGDirectDisplayID?
        private let displayLinkStateLock = NSLock()
        private var displayLinkRefreshScheduled = false
        private var displayedAppearanceSignature: UInt64?
        private var displayedCursorSize: CGSize = .zero
        private var displayedHotSpot: CGPoint = .zero
        private var systemCursor: NSCursor = NSCursor.arrow
        private var systemCursorSignature: UInt64?
        private var lastWarpedScreenPoint: CGPoint?
        private var cursorHiddenSinceNanoseconds: UInt64?
        private var needsCursorReassertion = false
        private var prefersOverlayFallback = false
        private var lastPresentedOwnershipIntent: CursorOwnershipIntent?
        private var trackingArea: NSTrackingArea?
        private var lastLoggedCursorPresentationMode: String?
        private var lastLoggedCursorVisibility: Bool?

        /// Smoothed velocity (normalised units / nanosecond) used for cursor prediction.
        private var smoothedVelocityX: Double = 0
        private var smoothedVelocityY: Double = 0
        /// Exponential-smoothing factor applied to new velocity samples.
        private let velocitySmoothingAlpha: Double = 0.35
        /// Keep the hidden local cursor slightly inset so Universal Control does not
        /// steal it when the visible mirrored cursor reaches a physical screen edge.
        private let hiddenCursorEdgeInsetNormalized: CGFloat = 0.004

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)

            wantsLayer = true
            layer?.masksToBounds = false

            cursorImageView.imageAlignment = .alignTopLeft
            cursorImageView.imageScaling = .scaleProportionallyUpOrDown
            cursorImageView.isHidden = true
            cursorImageView.autoresizingMask = []
            addSubview(cursorImageView)

            installTrackingArea()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            stopDisplayLink()
            stopRefreshTimer()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            guard managesSystemCursorAppearance else { return }
            addCursorRect(bounds, cursor: systemCursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            installTrackingArea()
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            needsCursorReassertion = true
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            needsCursorReassertion = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installTrackingArea()
            syncPresentationDriverState()
        }

        func refreshConfiguration() {
            isHidden = !(NetworkProtocol.enableReceiverSideCursorOverlay && !NetworkProtocol.useSwiftUIReceiverCursorOverlay)
            if isHidden {
                cursorImageView.isHidden = true
            }
            if usesSystemCursorMirror {
                cursorImageView.isHidden = true
            }
            if managesSystemCursorAppearance {
                window?.invalidateCursorRects(for: self)
            }
            syncPresentationDriverState()
            refreshPresentationIfNeeded()
        }

        func refreshPresentationIfNeeded() {
            guard !isHidden else { return }
            refreshCursorPresentation()
        }

        // MARK: - Tracking area

        private func installTrackingArea() {
            if let old = trackingArea {
                removeTrackingArea(old)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        // MARK: - Presentation drivers

        private func syncPresentationDriverState() {
            guard window != nil, !isHidden else {
                stopDisplayLink()
                stopRefreshTimer()
                return
            }

            guard !startDisplayLinkIfPossible() else {
                stopRefreshTimer()
                return
            }

            syncRefreshTimerState()
        }

        private func syncRefreshTimerState() {
            guard refreshTimer == nil else { return }

            let intervalNanoseconds = Int(1_000_000_000 / max(1, NetworkProtocol.cursorOverlayFramesPerSecond))
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(
                deadline: .now(),
                repeating: .nanoseconds(intervalNanoseconds),
                leeway: .microseconds(250)
            )
            timer.setEventHandler { [weak self] in
                self?.refreshCursorPresentation()
            }
            timer.activate()
            refreshTimer = timer
        }

        private func startDisplayLinkIfPossible() -> Bool {
            if displayLink == nil {
                var createdDisplayLink: CVDisplayLink?
                guard CVDisplayLinkCreateWithActiveCGDisplays(&createdDisplayLink) == kCVReturnSuccess,
                      let createdDisplayLink else {
                    return false
                }

                let callbackStatus = CVDisplayLinkSetOutputCallback(
                    createdDisplayLink,
                    Self.displayLinkCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                guard callbackStatus == kCVReturnSuccess else {
                    return false
                }

                displayLink = createdDisplayLink
            }

            guard let displayLink else { return false }
            updateDisplayLinkDisplayIfNeeded(displayLink)

            if !CVDisplayLinkIsRunning(displayLink) {
                guard CVDisplayLinkStart(displayLink) == kCVReturnSuccess else {
                    stopDisplayLink()
                    return false
                }
            }

            return true
        }

        private func updateDisplayLinkDisplayIfNeeded(_ displayLink: CVDisplayLink) {
            guard let screenNumber = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            guard displayLinkDisplayID != displayID else { return }
            if CVDisplayLinkSetCurrentCGDisplay(displayLink, displayID) == kCVReturnSuccess {
                displayLinkDisplayID = displayID
            }
        }

        private func scheduleDisplayLinkedRefresh() {
            displayLinkStateLock.lock()
            if displayLinkRefreshScheduled {
                displayLinkStateLock.unlock()
                return
            }
            displayLinkRefreshScheduled = true
            displayLinkStateLock.unlock()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.displayLinkStateLock.lock()
                self.displayLinkRefreshScheduled = false
                self.displayLinkStateLock.unlock()
                self.refreshCursorPresentation()
            }
        }

        private func stopDisplayLink() {
            if let displayLink, CVDisplayLinkIsRunning(displayLink) {
                CVDisplayLinkStop(displayLink)
            }
            displayLink = nil
            displayLinkDisplayID = nil
        }

        private func stopRefreshTimer() {
            refreshTimer?.setEventHandler {}
            refreshTimer?.cancel()
            refreshTimer = nil
        }

        // MARK: - Cursor presentation (main thread)

        private func refreshCursorPresentation() {
            guard bounds.width > 0, bounds.height > 0 else {
                cursorImageView.isHidden = true
                return
            }

            let now = DispatchTime.now().uptimeNanoseconds
            guard let cursorState = ReceiverCursorStore.shared.snapshot() else {
                logCursorVisibilityIfNeeded(false, detail: "no visible cursor snapshot")
                lastPresentedOwnershipIntent = .hidden
                if managesSystemCursorAppearance {
                    if cursorHiddenSinceNanoseconds == nil {
                        cursorHiddenSinceNanoseconds = now
                    }
                    let hiddenDuration = now - (cursorHiddenSinceNanoseconds ?? now)
                    if hiddenDuration >= 120_000_000 {
                        logCursorDebug("installing transparent cursor after hidden grace period")
                        ensureSystemCursorHidden()
                    }
                }
                cursorImageView.isHidden = true
                return
            }

            if cursorState.ownershipIntent == .localHandoff {
                presentLocalCursorHandoff()
                return
            }

            guard cursorState.ownershipIntent == .remote, cursorState.isVisible else {
                logCursorVisibilityIfNeeded(false, detail: cursorState.ownershipIntent.rawValue)
                lastPresentedOwnershipIntent = cursorState.ownershipIntent
                if managesSystemCursorAppearance {
                    if cursorHiddenSinceNanoseconds == nil {
                        cursorHiddenSinceNanoseconds = now
                    }
                    let hiddenDuration = now - (cursorHiddenSinceNanoseconds ?? now)
                    if hiddenDuration >= 120_000_000 {
                        logCursorDebug("installing transparent cursor after hidden grace period")
                        ensureSystemCursorHidden()
                    }
                }
                cursorImageView.isHidden = true
                return
            }
            cursorHiddenSinceNanoseconds = nil

            if lastPresentedOwnershipIntent == .localHandoff {
                logCursorDebug("reacquiring remote cursor after local handoff")
                prefersOverlayFallback = false
                lastWarpedScreenPoint = nil
                needsCursorReassertion = true
            }
            lastPresentedOwnershipIntent = .remote

            let normalizedPosition = predictedCursorPosition(at: now) ?? CGPoint(
                x: cursorState.normalizedX,
                y: cursorState.normalizedY
            )
            let usingSystemCursorMirror = usesSystemCursorMirror
            logCursorVisibilityIfNeeded(true, detail: usingSystemCursorMirror ? "system-mirror" : "overlay-fallback")
            let cursorPoint = CGPoint(
                x: normalizedPosition.x * bounds.width,
                y: normalizedPosition.y * bounds.height
            )
            let hiddenCursorNormalizedPosition = clampedHiddenCursorPosition(for: normalizedPosition)
            let hiddenCursorPoint = CGPoint(
                x: hiddenCursorNormalizedPosition.x * bounds.width,
                y: hiddenCursorNormalizedPosition.y * bounds.height
            )

            let presentationMode = usingSystemCursorMirror ? "system-mirror" : "overlay-fallback"
            if lastLoggedCursorPresentationMode != presentationMode {
                lastLoggedCursorPresentationMode = presentationMode
                logCursorDebug("presentation mode -> \(presentationMode)")
            }

            // Bug 1 recovery: if the cursor was previously hidden (systemCursorSignature
            // was cleared by ensureSystemCursorHidden) but the cursor is now visible again,
            // force the appearance update to re-establish the non-transparent cursor rect.
            if usingSystemCursorMirror, systemCursorSignature == nil {
                displayedAppearanceSignature = nil
                needsCursorReassertion = true
            }

            if !updateCursorAppearanceIfNeeded(from: cursorState.appearance) {
                cursorImageView.isHidden = true
                return
            }

            if usingSystemCursorMirror {
                if systemCursorSignature != nil {
                    if needsCursorReassertion {
                        window?.invalidateCursorRects(for: self)
                    }
                    systemCursor.set()
                }

                applySystemCursorPosition(
                    cursorPoint,
                    normalizedPosition: normalizedPosition,
                    forceReassertion: needsCursorReassertion
                )
                cursorImageView.isHidden = true
                return
            }

            if managesSystemCursorAppearance {
                installTransparentSystemCursorIfNeeded()
                applySystemCursorPosition(
                    hiddenCursorPoint,
                    normalizedPosition: hiddenCursorNormalizedPosition,
                    forceReassertion: true
                )
            }

            let cursorOrigin = CGPoint(
                x: cursorPoint.x - displayedHotSpot.x,
                y: cursorPoint.y - displayedHotSpot.y
            )

            cursorImageView.frame = CGRect(origin: cursorOrigin, size: displayedCursorSize)
            cursorImageView.isHidden = false
        }

        private func presentLocalCursorHandoff() {
            cursorHiddenSinceNanoseconds = nil
            if lastPresentedOwnershipIntent != .localHandoff {
                logCursorDebug("entering local handoff mode")
                prefersOverlayFallback = false
                lastWarpedScreenPoint = nil
                needsCursorReassertion = true
                lastPresentedOwnershipIntent = .localHandoff
            }
            logCursorVisibilityIfNeeded(false, detail: "local-handoff")
            guard updateCursorAppearanceIfNeeded(from: nil),
                  let localCursorPoint = currentLocalSystemCursorPoint(),
                  bounds.contains(localCursorPoint) else {
                restoreVisibleSystemCursorIfNeeded()
                cursorImageView.isHidden = true
                return
            }

            if managesSystemCursorAppearance {
                installTransparentSystemCursorIfNeeded()
            }

            let cursorOrigin = CGPoint(
                x: localCursorPoint.x - displayedHotSpot.x,
                y: localCursorPoint.y - displayedHotSpot.y
            )
            cursorImageView.frame = CGRect(origin: cursorOrigin, size: displayedCursorSize)
            cursorImageView.isHidden = false
        }

        // MARK: - Cursor prediction

        private func predictedCursorPosition(at nowNanoseconds: UInt64) -> CGPoint? {
            let snapshot = ReceiverCursorStore.shared.snapshotPair()
            guard let latest = snapshot.latest, latest.isVisible else {
                smoothedVelocityX = 0
                smoothedVelocityY = 0
                return nil
            }

            guard let previous = snapshot.previous,
                  previous.isVisible,
                  latest.senderTimestampNanoseconds > previous.senderTimestampNanoseconds,
                  latest.receiverTimestampNanoseconds >= previous.receiverTimestampNanoseconds else {
                smoothedVelocityX = 0
                smoothedVelocityY = 0
                return CGPoint(x: latest.normalizedX, y: latest.normalizedY)
            }

            let senderDeltaNanoseconds = latest.senderTimestampNanoseconds - previous.senderTimestampNanoseconds
            guard senderDeltaNanoseconds > 0 else {
                smoothedVelocityX = 0
                smoothedVelocityY = 0
                return CGPoint(x: latest.normalizedX, y: latest.normalizedY)
            }

            // Instantaneous velocity (normalised units / nanosecond).
            let instantVX = (latest.normalizedX - previous.normalizedX) / Double(senderDeltaNanoseconds)
            let instantVY = (latest.normalizedY - previous.normalizedY) / Double(senderDeltaNanoseconds)

            // If the cursor is essentially stationary, zero out velocity to prevent
            // residual smoothed momentum from causing jittery bounces.
            let motionThreshold = 0.00001
            if abs(instantVX) < motionThreshold && abs(instantVY) < motionThreshold {
                smoothedVelocityX = 0
                smoothedVelocityY = 0
                return CGPoint(x: latest.normalizedX, y: latest.normalizedY)
            }

            // Exponentially-smoothed velocity to reduce jitter from variable sender timing.
            smoothedVelocityX = velocitySmoothingAlpha * instantVX + (1.0 - velocitySmoothingAlpha) * smoothedVelocityX
            smoothedVelocityY = velocitySmoothingAlpha * instantVY + (1.0 - velocitySmoothingAlpha) * smoothedVelocityY

            let elapsedSinceLatestNanoseconds = nowNanoseconds >= latest.receiverTimestampNanoseconds
                ? nowNanoseconds - latest.receiverTimestampNanoseconds
                : 0
            let predictionLeadNanoseconds = min(
                elapsedSinceLatestNanoseconds,
                min(NetworkProtocol.cursorPredictionLeadNanoseconds, senderDeltaNanoseconds)
            )

            let predictedX = latest.normalizedX + smoothedVelocityX * Double(predictionLeadNanoseconds)
            let predictedY = latest.normalizedY + smoothedVelocityY * Double(predictionLeadNanoseconds)

            return CGPoint(
                x: max(0, min(1, predictedX)),
                y: max(0, min(1, predictedY))
            )
        }

        // MARK: - Cursor appearance

        private func updateCursorAppearanceIfNeeded(from appearance: CursorAppearancePayload?) -> Bool {
            let usingSystemCursorMirror = usesSystemCursorMirror
            if NetworkProtocol.useDebugCursorOverlayMarker {
                if displayedAppearanceSignature != UInt64.max {
                    cursorImageView.image = makeDebugCursorImage()
                    displayedAppearanceSignature = UInt64.max
                    displayedCursorSize = CGSize(width: 28, height: 28)
                    displayedHotSpot = CGPoint(x: 14, y: 14)
                    if usingSystemCursorMirror {
                        systemCursor = NSCursor(image: makeDebugCursorImage(), hotSpot: displayedHotSpot)
                        systemCursorSignature = UInt64.max
                        window?.invalidateCursorRects(for: self)
                    }
                }
                return true
            }

            let resolvedAppearance = appearance ?? defaultArrowAppearance()
            if displayedAppearanceSignature == resolvedAppearance.signature,
               (!usingSystemCursorMirror || systemCursorSignature == resolvedAppearance.signature) {
                return true
            }
            guard let image = NSImage(data: resolvedAppearance.pngData) else { return false }

            image.size = CGSize(
                width: resolvedAppearance.widthPoints,
                height: resolvedAppearance.heightPoints
            )
            cursorImageView.image = image
            displayedAppearanceSignature = resolvedAppearance.signature
            displayedCursorSize = image.size
            displayedHotSpot = CGPoint(
                x: resolvedAppearance.hotSpotX,
                y: resolvedAppearance.hotSpotY
            )
            if usingSystemCursorMirror {
                systemCursor = NSCursor(image: image, hotSpot: displayedHotSpot)
                systemCursorSignature = resolvedAppearance.signature
                window?.invalidateCursorRects(for: self)
            }
            return true
        }

        // MARK: - System cursor warp

        private func applySystemCursorPosition(
            _ localPoint: CGPoint,
            normalizedPosition: CGPoint? = nil,
            forceReassertion: Bool = false
        ) {
            guard let window else { return }

            let windowPoint = convert(localPoint, to: nil)
            let appKitScreenPoint = window.convertPoint(toScreen: windowPoint)
            let screenPoint: CGPoint
            if let screen = window.screen {
                screenPoint = CGPoint(
                    x: appKitScreenPoint.x,
                    y: screen.frame.minY + screen.frame.maxY - appKitScreenPoint.y
                )
            } else {
                screenPoint = appKitScreenPoint
            }

            let currentSystemCursorPoint = CGEvent(source: nil)?.location

            if let lastWarpedScreenPoint,
               let currentSystemCursorPoint,
               abs(currentSystemCursorPoint.x - lastWarpedScreenPoint.x) > 2.0 ||
               abs(currentSystemCursorPoint.y - lastWarpedScreenPoint.y) > 2.0 {
                logCursorDebug(
                    String(
                        format: "local cursor drift detected current=(%.1f, %.1f) lastWarped=(%.1f, %.1f)",
                        currentSystemCursorPoint.x,
                        currentSystemCursorPoint.y,
                        lastWarpedScreenPoint.x,
                        lastWarpedScreenPoint.y
                    )
                )
                activateOverlayCursorFallback()
                self.lastWarpedScreenPoint = currentSystemCursorPoint
                needsCursorReassertion = true
            }

            // Skip warp if cursor is already at the target position.
            if let lastWarpedScreenPoint,
               let currentSystemCursorPoint,
               abs(lastWarpedScreenPoint.x - screenPoint.x) < 0.25,
               abs(lastWarpedScreenPoint.y - screenPoint.y) < 0.25,
               abs(currentSystemCursorPoint.x - screenPoint.x) < 0.25,
               abs(currentSystemCursorPoint.y - screenPoint.y) < 0.25,
               !forceReassertion {
                return
            }

            CGWarpMouseCursorPosition(screenPoint)
            lastWarpedScreenPoint = screenPoint
            needsCursorReassertion = false
        }

        private var usesSystemCursorMirror: Bool {
            NetworkProtocol.useReceiverSystemCursorMirror && !prefersOverlayFallback
        }

        private var managesSystemCursorAppearance: Bool {
            NetworkProtocol.useReceiverSystemCursorMirror
        }

        private func activateOverlayCursorFallback() {
            guard NetworkProtocol.useReceiverSystemCursorMirror, !prefersOverlayFallback else { return }
            prefersOverlayFallback = true
            logCursorDebug("activated overlay fallback after local cursor interference")
            installTransparentSystemCursorIfNeeded()
        }

        private func clampedHiddenCursorPosition(for normalizedPosition: CGPoint) -> CGPoint {
            let inset = hiddenCursorEdgeInsetNormalized
            return CGPoint(
                x: min(max(normalizedPosition.x, inset), 1.0 - inset),
                y: min(max(normalizedPosition.y, inset), 1.0 - inset)
            )
        }

        private func installTransparentSystemCursorIfNeeded() {
            guard managesSystemCursorAppearance else { return }
            if systemCursorSignature != nil {
                logCursorDebug("installing transparent cursor")
            }
            systemCursor = NSCursor(image: Self.transparentCursorImage, hotSpot: .zero)
            systemCursorSignature = nil
            window?.invalidateCursorRects(for: self)
        }

        private func restoreVisibleSystemCursorIfNeeded() {
            guard managesSystemCursorAppearance else { return }
            guard systemCursorSignature == nil else { return }
            systemCursor = NSCursor.arrow
            systemCursorSignature = UInt64.max - 1
            window?.invalidateCursorRects(for: self)
        }

        private func currentLocalSystemCursorPoint() -> CGPoint? {
            guard let window else { return nil }
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            return convert(windowPoint, from: nil)
        }

        private func logCursorDebug(_ message: String) {
            guard NetworkProtocol.enableCursorDebugLogging else { return }
            print("[Receiver][CursorHost] \(message)")
        }

        private func logCursorVisibilityIfNeeded(_ isVisible: Bool, detail: String) {
            guard NetworkProtocol.enableCursorDebugLogging else { return }
            guard lastLoggedCursorVisibility != isVisible || lastLoggedCursorPresentationMode == nil else { return }
            lastLoggedCursorVisibility = isVisible
            print("[Receiver][CursorHost] visibility -> \(isVisible ? "visible" : "hidden") (\(detail))")
        }

        /// Returns the window's frame in CG screen coordinates (origin at top-left
        /// of the main display), or nil if unavailable.
        private func windowScreenRect() -> CGRect? {
            guard let window, let screen = window.screen else { return nil }
            let wf = window.frame
            return CGRect(
                x: wf.origin.x,
                y: screen.frame.minY + screen.frame.maxY - wf.maxY,
                width: wf.width,
                height: wf.height
            )
        }

        private func ensureSystemCursorHidden() {
            guard managesSystemCursorAppearance else { return }

            // If there is already a visible cursor state waiting, don't install
            // the transparent cursor — it will just be immediately replaced on the
            // next refresh cycle, and the brief transparent flash is the root cause
            // of the "cursor disappears" bug.
            if let pending = ReceiverCursorStore.shared.snapshot(),
               pending.ownershipIntent == .remote,
               pending.isVisible {
                return
            }

            lastWarpedScreenPoint = nil
            installTransparentSystemCursorIfNeeded()
        }

        private func defaultArrowAppearance() -> CursorAppearancePayload {
            let image = NSCursor.arrow.image
            var proposedRect = CGRect(origin: .zero, size: image.size)
            let pngData: Data
            if let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                pngData = bitmap.representation(using: .png, properties: [:]) ?? Data()
            } else {
                pngData = Data()
            }

            let hotSpot = NSCursor.arrow.hotSpot
            return CursorAppearancePayload(
                signature: 0,
                pngData: pngData,
                widthPoints: image.size.width,
                heightPoints: image.size.height,
                hotSpotX: hotSpot.x,
                hotSpotY: hotSpot.y
            )
        }

        private func makeDebugCursorImage() -> NSImage {
            let size = NSSize(width: 28, height: 28)
            let image = NSImage(size: size)
            image.lockFocus()
            defer { image.unlockFocus() }

            let circleRect = NSRect(x: 2, y: 2, width: 24, height: 24)
            NSColor.systemRed.withAlphaComponent(0.90).setFill()
            NSBezierPath(ovalIn: circleRect).fill()

            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(ovalIn: circleRect.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()

            let vertical = NSBezierPath()
            vertical.move(to: NSPoint(x: 14, y: 6))
            vertical.line(to: NSPoint(x: 14, y: 22))
            vertical.lineWidth = 2
            vertical.stroke()

            let horizontal = NSBezierPath()
            horizontal.move(to: NSPoint(x: 6, y: 14))
            horizontal.line(to: NSPoint(x: 22, y: 14))
            horizontal.lineWidth = 2
            horizontal.stroke()

            return image
        }
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position [[attribute(0)]];
            float2 textureCoordinate [[attribute(1)]];
        };

        struct Uniforms {
            float2 scale;
            float2 offset;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        vertex VertexOut texturedQuadVertex(
            VertexIn in [[stage_in]],
            constant Uniforms &uniforms [[buffer(1)]]
        ) {
            VertexOut out;
            out.position = float4((in.position * uniforms.scale) + uniforms.offset, 0.0, 1.0);
            out.textureCoordinate = in.textureCoordinate;
            return out;
        }

        fragment float4 texturedQuadFragment(
            VertexOut in [[stage_in]],
            texture2d<float> textureY    [[texture(0)]],
            texture2d<float> textureCbCr [[texture(1)]],
            sampler sourceSampler        [[sampler(0)]]
        ) {
            float  y    = textureY.sample(sourceSampler, in.textureCoordinate).r;
            float2 cbcr = textureCbCr.sample(sourceSampler, in.textureCoordinate).rg;

            // Bias for BT.709 limited-range (video range): Y in [16,235], CbCr in [16,240]
            float3 yuv = float3(y - (16.0 / 255.0), cbcr.x - 0.5, cbcr.y - 0.5);

            // BT.709 limited-range YCbCr -> linear RGB (column-major: each float3 is one column)
            // Column 0: Y coefficients for R, G, B
            // Column 1: Cb coefficients for R, G, B
            // Column 2: Cr coefficients for R, G, B
            const float3x3 rec709 = float3x3(
                float3( 1.1644,  1.1644,  1.1644),
                float3( 0.0000, -0.3917,  2.0172),
                float3( 1.5960, -0.8129,  0.0000)
            );

            return float4(clamp(rec709 * yuv, 0.0, 1.0), 1.0);
        }

        fragment float4 bgraQuadFragment(
            VertexOut in [[stage_in]],
            texture2d<float> colorTexture [[texture(0)]],
            sampler sourceSampler [[sampler(0)]]
        ) {
            return colorTexture.sample(sourceSampler, in.textureCoordinate);
        }
        """

        private var commandQueue: MTLCommandQueue?
        private var ycbcrPipelineState: MTLRenderPipelineState?
        private var bgraPipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var samplerState: MTLSamplerState?
        private var textureCache: CVMetalTextureCache?
        private var cursorTexture: MTLTexture?
        private var cursorHotSpotFromTop = CGPoint.zero
        private let cursorOverlayMaxAgeNanoseconds: UInt64 = 250_000_000

        // Retain both planes per slot to prevent premature CVMetalTexture deallocation.
        private var retainedYTextures: [CVMetalTexture?] = Array(repeating: nil, count: 3)
        private var retainedCbCrTextures: [CVMetalTexture?] = Array(repeating: nil, count: 3)
        private var retainedPixelBufferTextureSlot = 0
        private var retainedBGRATextures: [MTLTexture?] = Array(repeating: nil, count: 3)
        private var retainedBGRATextureSlot = 0

        // Triple-buffering semaphore: limits CPU-ahead GPU submissions to 3 frames,
        // preventing the render loop from starving WindowServer during high-motion content.
        private let inFlightSemaphore = DispatchSemaphore(value: 3)

        // MetalFX Spatial Scaler state
        private var spatialScaler: MTLFXSpatialScaler?
        private var intermediateColorTexture: MTLTexture?
        private var upscaledTexture: MTLTexture?
        private var currentInputWidth: Int = 0
        private var currentInputHeight: Int = 0
        private var currentOutputWidth: Int = 0
        private var currentOutputHeight: Int = 0

        func attach(to view: MTKView) {
            guard let device = view.device else { return }

            commandQueue = device.makeCommandQueue()
            vertexBuffer = makeVertexBuffer(device: device)
            samplerState = makeSamplerState(device: device)
            ycbcrPipelineState = makePipelineState(
                device: device,
                colorPixelFormat: .bgra8Unorm,
                fragmentFunctionName: "texturedQuadFragment"
            )
            bgraPipelineState = makePipelineState(
                device: device,
                colorPixelFormat: .bgra8Unorm,
                fragmentFunctionName: "bgraQuadFragment"
            )
            if let cursorAsset = makeCursorTexture(device: device) {
                cursorTexture = cursorAsset.texture
                cursorHotSpotFromTop = cursorAsset.hotSpotFromTop
            }

            var newTextureCache: CVMetalTextureCache?
            let cacheStatus = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &newTextureCache
            )

            if cacheStatus == kCVReturnSuccess {
                textureCache = newTextureCache
            } else {
                print("[MetalRenderSurfaceView] Failed to create CVMetalTextureCache: \(cacheStatus)")
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            _ = view
            _ = size
        }

        func draw(in view: MTKView) {
            _ = inFlightSemaphore.wait(timeout: .distantFuture)

            guard let device = view.device,
                  let commandQueue,
                  let ycbcrPipelineState,
                  let bgraPipelineState,
                  let vertexBuffer,
                  let samplerState,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let drawable = view.currentDrawable else {
                inFlightSemaphore.signal()
                return
            }

            commandBuffer.addCompletedHandler { [weak self] _ in
                self?.inFlightSemaphore.signal()
            }

            let frame = RenderFrameStore.shared.snapshot()
            let renderInput = frame.flatMap { makeRenderInput(from: $0, device: device) }

            guard let renderInput else {
                // No frame available — present a cleared drawable.
                guard let clearPass = view.currentRenderPassDescriptor else {
                    commandBuffer.commit()
                    return
                }
                guard let clearEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) else {
                    commandBuffer.commit()
                    return
                }
                clearEncoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            let inputWidth  = renderInput.width
            let inputHeight = renderInput.height
            let outputWidth  = Int(view.drawableSize.width)
            let outputHeight = Int(view.drawableSize.height)

            let shouldUseSpatialUpscale =
                renderInput.supportsSpatialUpscale &&
                shouldUseSpatialUpscale(
                    inputWidth: inputWidth,
                    inputHeight: inputHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )

            guard shouldUseSpatialUpscale else {
                releaseScalerResources()
                drawDirectToDrawable(
                    view: view,
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    ycbcrPipelineState: ycbcrPipelineState,
                    bgraPipelineState: bgraPipelineState,
                    vertexBuffer: vertexBuffer,
                    samplerState: samplerState,
                    renderInput: renderInput
                )
                return
            }

            // Rebuild intermediate texture and MetalFX scaler when dimensions change.
            if inputWidth != currentInputWidth
                || inputHeight != currentInputHeight
                || outputWidth != currentOutputWidth
                || outputHeight != currentOutputHeight {
                rebuildScalerResources(
                    device: device,
                    inputWidth: inputWidth,
                    inputHeight: inputHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight
                )
            }

            // --- Pass 1: Render YUV→RGB quad to offscreen intermediate texture ---
            guard let intermediateColorTexture else {
                // Scaler setup failed — fall back to direct rendering.
                drawDirectToDrawable(
                    view: view,
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    ycbcrPipelineState: ycbcrPipelineState,
                    bgraPipelineState: bgraPipelineState,
                    vertexBuffer: vertexBuffer,
                    samplerState: samplerState,
                    renderInput: renderInput
                )
                return
            }

            let offscreenPassDescriptor = MTLRenderPassDescriptor()
            offscreenPassDescriptor.colorAttachments[0].texture = intermediateColorTexture
            offscreenPassDescriptor.colorAttachments[0].loadAction = .clear
            offscreenPassDescriptor.colorAttachments[0].storeAction = .store
            offscreenPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)

            guard let offscreenEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenPassDescriptor) else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            // For Pass 1, the intermediate texture matches the input resolution exactly —
            // no aspect-fit scaling needed; fill the entire intermediate surface.
            var uniforms = RenderUniforms(scale: SIMD2<Float>(1.0, 1.0), offset: SIMD2<Float>(0, 0))

            encodeRenderInput(
                renderInput,
                encoder: offscreenEncoder,
                ycbcrPipelineState: ycbcrPipelineState,
                bgraPipelineState: bgraPipelineState,
                vertexBuffer: vertexBuffer,
                samplerState: samplerState,
                uniforms: &uniforms
            )
            offscreenEncoder.endEncoding()

            // --- Pass 2: MetalFX Spatial Upscale → private upscaled texture ---
            guard let spatialScaler, let upscaledTexture else {
                // Scaler unavailable after Pass 1 — fall back to the direct render path.
                drawDirectToDrawable(
                    view: view,
                    commandBuffer: commandBuffer,
                    drawable: drawable,
                    ycbcrPipelineState: ycbcrPipelineState,
                    bgraPipelineState: bgraPipelineState,
                    vertexBuffer: vertexBuffer,
                    samplerState: samplerState,
                    renderInput: renderInput
                )
                return
            }

            spatialScaler.colorTexture = intermediateColorTexture
            spatialScaler.outputTexture = upscaledTexture
            spatialScaler.encode(commandBuffer: commandBuffer)

            // --- Pass 3: Blit private upscaled texture → drawable ---
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            blitEncoder.copy(from: upscaledTexture, to: drawable.texture)
            blitEncoder.endEncoding()

            drawCursorOverlayIfNeeded(
                view: view,
                commandBuffer: commandBuffer,
                drawable: drawable,
                bgraPipelineState: bgraPipelineState,
                vertexBuffer: vertexBuffer,
                samplerState: samplerState,
                contentWidth: inputWidth,
                contentHeight: inputHeight
            )

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Rebuilds the intermediate texture and MetalFX spatial scaler for new dimensions.
        private func rebuildScalerResources(
            device: MTLDevice,
            inputWidth: Int,
            inputHeight: Int,
            outputWidth: Int,
            outputHeight: Int
        ) {
            currentInputWidth  = inputWidth
            currentInputHeight = inputHeight
            currentOutputWidth  = outputWidth
            currentOutputHeight = outputHeight

            // Create intermediate texture at source (input) resolution.
            // Needs .renderTarget (Pass 1 color attachment) + .shaderRead (MetalFX colorTexture input).
            let intermediateDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: inputWidth,
                height: inputHeight,
                mipmapped: false
            )
            intermediateDescriptor.usage = [.renderTarget, .shaderRead]
            intermediateDescriptor.storageMode = .private
            intermediateColorTexture = device.makeTexture(descriptor: intermediateDescriptor)

            guard intermediateColorTexture != nil else {
                print("[MetalRenderSurfaceView] Failed to create intermediate texture \(inputWidth)x\(inputHeight)")
                spatialScaler = nil
                upscaledTexture = nil
                return
            }

            // Create private upscaled texture at output (drawable) resolution.
            // MetalFX requires its outputTexture to have .private storage mode,
            // but MTKView drawables use .managed — so we upscale to this private
            // texture and then blit it to the drawable.
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: outputWidth,
                height: outputHeight,
                mipmapped: false
            )
            outputDescriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
            outputDescriptor.storageMode = .private
            upscaledTexture = device.makeTexture(descriptor: outputDescriptor)

            guard upscaledTexture != nil else {
                print("[MetalRenderSurfaceView] Failed to create upscaled texture \(outputWidth)x\(outputHeight)")
                spatialScaler = nil
                return
            }

            // Create MetalFX Spatial Scaler.
            let scalerDescriptor = MTLFXSpatialScalerDescriptor()
            scalerDescriptor.inputWidth  = inputWidth
            scalerDescriptor.inputHeight = inputHeight
            scalerDescriptor.outputWidth  = outputWidth
            scalerDescriptor.outputHeight = outputHeight
            scalerDescriptor.colorTextureFormat  = .bgra8Unorm
            scalerDescriptor.outputTextureFormat = .bgra8Unorm
            scalerDescriptor.colorProcessingMode = .perceptual

            spatialScaler = scalerDescriptor.makeSpatialScaler(device: device)

            if spatialScaler == nil {
                print(
                    "[MetalRenderSurfaceView] MetalFX spatial scaler creation failed " +
                    "(\(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)). " +
                    "Falling back to direct rendering."
                )
            } else {
                print(
                    "[MetalRenderSurfaceView] MetalFX spatial scaler ready: " +
                    "\(inputWidth)x\(inputHeight) → \(outputWidth)x\(outputHeight)"
                )
            }
        }

        private func releaseScalerResources() {
            spatialScaler = nil
            intermediateColorTexture = nil
            upscaledTexture = nil
            currentInputWidth = 0
            currentInputHeight = 0
            currentOutputWidth = 0
            currentOutputHeight = 0
        }

        private func shouldUseSpatialUpscale(
            inputWidth: Int,
            inputHeight: Int,
            outputWidth: Int,
            outputHeight: Int
        ) -> Bool {
            guard inputWidth > 0,
                  inputHeight > 0,
                  outputWidth > 0,
                  outputHeight > 0 else {
                return false
            }

            // Use the direct path when the frame already matches the output, when the view is
            // downscaling, or when the aspect ratio differs enough that a straight upscale would
            // stretch the image instead of preserving the sender's geometry.
            guard outputWidth > inputWidth || outputHeight > inputHeight else {
                return false
            }

            let inputAspect = Double(inputWidth) / Double(inputHeight)
            let outputAspect = Double(outputWidth) / Double(outputHeight)
            return abs(inputAspect - outputAspect) < 0.01
        }

        /// Fallback: direct single-pass render to drawable when MetalFX is unavailable.
        private func drawDirectToDrawable(
            view: MTKView,
            commandBuffer: MTLCommandBuffer,
            drawable: CAMetalDrawable,
            ycbcrPipelineState: MTLRenderPipelineState,
            bgraPipelineState: MTLRenderPipelineState,
            vertexBuffer: MTLBuffer,
            samplerState: MTLSamplerState,
            renderInput: RenderInput
        ) {
            guard let renderPassDescriptor = view.currentRenderPassDescriptor else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            var uniforms = RenderUniforms(
                scale: makeAspectFitScale(
                    contentWidth: renderInput.width,
                    contentHeight: renderInput.height,
                    drawableSize: view.drawableSize
                ),
                offset: SIMD2<Float>(0, 0)
            )

            encodeRenderInput(
                renderInput,
                encoder: encoder,
                ycbcrPipelineState: ycbcrPipelineState,
                bgraPipelineState: bgraPipelineState,
                vertexBuffer: vertexBuffer,
                samplerState: samplerState,
                uniforms: &uniforms
            )
            encodeCursorOverlayIfNeeded(
                view: view,
                encoder: encoder,
                bgraPipelineState: bgraPipelineState,
                vertexBuffer: vertexBuffer,
                samplerState: samplerState,
                contentWidth: renderInput.width,
                contentHeight: renderInput.height
            )
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func drawCursorOverlayIfNeeded(
            view: MTKView,
            commandBuffer: MTLCommandBuffer,
            drawable: CAMetalDrawable,
            bgraPipelineState: MTLRenderPipelineState,
            vertexBuffer: MTLBuffer,
            samplerState: MTLSamplerState,
            contentWidth: Int,
            contentHeight: Int
        ) {
            guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            renderPassDescriptor.colorAttachments[0].storeAction = .store
            renderPassDescriptor.colorAttachments[0].texture = drawable.texture

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }

            encodeCursorOverlayIfNeeded(
                view: view,
                encoder: encoder,
                bgraPipelineState: bgraPipelineState,
                vertexBuffer: vertexBuffer,
                samplerState: samplerState,
                contentWidth: contentWidth,
                contentHeight: contentHeight
            )
            encoder.endEncoding()
        }

        private func encodeCursorOverlayIfNeeded(
            view: MTKView,
            encoder: MTLRenderCommandEncoder,
            bgraPipelineState: MTLRenderPipelineState,
            vertexBuffer: MTLBuffer,
            samplerState: MTLSamplerState,
            contentWidth: Int,
            contentHeight: Int
        ) {
            guard let cursorTexture else { return }
            guard let cursorState = ReceiverCursorStore.shared.snapshot(maxAgeNanoseconds: cursorOverlayMaxAgeNanoseconds),
                  cursorState.isVisible else {
                return
            }

            guard var uniforms = makeCursorUniforms(
                cursorState: cursorState,
                cursorTexture: cursorTexture,
                drawableSize: view.drawableSize,
                contentWidth: contentWidth,
                contentHeight: contentHeight
            ) else {
                return
            }

            encoder.setRenderPipelineState(bgraPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.setFragmentTexture(cursorTexture, index: 0)
            encoder.setFragmentTexture(nil, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        private func makeCursorUniforms(
            cursorState: ReceiverCursorState,
            cursorTexture: MTLTexture,
            drawableSize: CGSize,
            contentWidth: Int,
            contentHeight: Int
        ) -> RenderUniforms? {
            guard drawableSize.width > 0,
                  drawableSize.height > 0,
                  contentWidth > 0,
                  contentHeight > 0 else {
                return nil
            }

            let contentScale = makeAspectFitScale(
                contentWidth: contentWidth,
                contentHeight: contentHeight,
                drawableSize: drawableSize
            )

            let contentMinX = -contentScale.x
            let contentMaxY = contentScale.y
            let hotspotClipX = contentMinX + Float(cursorState.normalizedX) * (contentScale.x * 2.0)
            let hotspotClipY = contentMaxY - Float(cursorState.normalizedY) * (contentScale.y * 2.0)

            let drawableWidth = Float(drawableSize.width)
            let drawableHeight = Float(drawableSize.height)
            let cursorWidth = Float(cursorTexture.width)
            let cursorHeight = Float(cursorTexture.height)
            guard cursorWidth > 0, cursorHeight > 0 else { return nil }

            let hotSpotX = Float(max(0, min(CGFloat(cursorTexture.width), cursorHotSpotFromTop.x)))
            let hotSpotYFromTop = Float(max(0, min(CGFloat(cursorTexture.height), cursorHotSpotFromTop.y)))

            let offsetX = ((cursorWidth * 0.5) - hotSpotX) * 2.0 / drawableWidth
            let offsetY = -(((cursorHeight * 0.5) - hotSpotYFromTop) * 2.0 / drawableHeight)

            return RenderUniforms(
                scale: SIMD2<Float>(
                    cursorWidth / drawableWidth,
                    cursorHeight / drawableHeight
                ),
                offset: SIMD2<Float>(
                    hotspotClipX + offsetX,
                    hotspotClipY + offsetY
                )
            )
        }

        private func makeVertexBuffer(device: MTLDevice) -> MTLBuffer? {
            let vertices = [
                RenderVertex(position: SIMD2<Float>(-1.0, 1.0), textureCoordinate: SIMD2<Float>(0.0, 0.0)),
                RenderVertex(position: SIMD2<Float>(-1.0, -1.0), textureCoordinate: SIMD2<Float>(0.0, 1.0)),
                RenderVertex(position: SIMD2<Float>(1.0, 1.0), textureCoordinate: SIMD2<Float>(1.0, 0.0)),
                RenderVertex(position: SIMD2<Float>(1.0, -1.0), textureCoordinate: SIMD2<Float>(1.0, 1.0))
            ]

            let bufferLength = MemoryLayout<RenderVertex>.stride * vertices.count
            return vertices.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return nil }
                return device.makeBuffer(bytes: baseAddress, length: bufferLength, options: .storageModeShared)
            }
        }

        private func makeSamplerState(device: MTLDevice) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }

        private func makeCursorTexture(device: MTLDevice) -> (texture: MTLTexture, hotSpotFromTop: CGPoint)? {
            guard !NetworkProtocol.enableReceiverSideCursorOverlay else {
                return nil
            }

            if NetworkProtocol.useDebugCursorOverlayMarker {
                return makeDebugCursorTexture(device: device)
            }

            let image = NSCursor.arrow.image
            var proposedRect = CGRect(origin: .zero, size: image.size)
            guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                return nil
            }

            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else { return nil }

            let bytesPerRow = width * 4
            var pixelData = Data(count: bytesPerRow * height)
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))

            let didDraw = pixelData.withUnsafeMutableBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return false }
                guard let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                ) else {
                    return false
                }

                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }

            guard didDraw else { return nil }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .managed

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }

            pixelData.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: bytesPerRow
                )
            }

            let pixelScale = image.size.width > 0 ? CGFloat(width) / image.size.width : 1.0
            let hotSpot = NSCursor.arrow.hotSpot
            let hotSpotFromTop = CGPoint(
                x: hotSpot.x * pixelScale,
                y: hotSpot.y * pixelScale
            )

            return (texture, hotSpotFromTop)
        }

        private func makeDebugCursorTexture(device: MTLDevice) -> (texture: MTLTexture, hotSpotFromTop: CGPoint)? {
            let width = 28
            let height = 28
            let bytesPerRow = width * 4
            var pixelData = Data(count: bytesPerRow * height)
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(.init(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))

            let didDraw = pixelData.withUnsafeMutableBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress else { return false }
                guard let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                ) else {
                    return false
                }

                context.clear(CGRect(x: 0, y: 0, width: width, height: height))

                context.setFillColor(NSColor.systemRed.withAlphaComponent(0.90).cgColor)
                context.fillEllipse(in: CGRect(x: 2, y: 2, width: width - 4, height: height - 4))

                context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: CGRect(x: 3, y: 3, width: width - 6, height: height - 6))

                context.move(to: CGPoint(x: width / 2, y: 6))
                context.addLine(to: CGPoint(x: width / 2, y: height - 6))
                context.move(to: CGPoint(x: 6, y: height / 2))
                context.addLine(to: CGPoint(x: width - 6, y: height / 2))
                context.strokePath()
                return true
            }

            guard didDraw else { return nil }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .managed

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }

            pixelData.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: bytesPerRow
                )
            }

            return (texture, CGPoint(x: CGFloat(width) / 2.0, y: CGFloat(height) / 2.0))
        }

        private func makePipelineState(
            device: MTLDevice,
            colorPixelFormat: MTLPixelFormat,
            fragmentFunctionName: String
        ) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "texturedQuadVertex")
                descriptor.fragmentFunction = library.makeFunction(name: fragmentFunctionName)
                descriptor.vertexDescriptor = makeVertexDescriptor()
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("[MetalRenderSurfaceView] Failed to build render pipeline: \(error)")
                return nil
            }
        }

        private func makeVertexDescriptor() -> MTLVertexDescriptor {
            let descriptor = MTLVertexDescriptor()
            descriptor.attributes[0].format = .float2
            descriptor.attributes[0].offset = 0
            descriptor.attributes[0].bufferIndex = 0
            descriptor.attributes[1].format = .float2
            descriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
            descriptor.attributes[1].bufferIndex = 0
            descriptor.layouts[0].stride = MemoryLayout<RenderVertex>.stride
            descriptor.layouts[0].stepFunction = .perVertex
            return descriptor
        }

        /// Extracts the Y (luma) and CbCr (chroma) Metal textures from a bi-planar YUV pixel buffer.
        /// Returns nil if the frame has no pixel buffer (e.g. synthetic/rawBGRA diagnostic frames).
        private func makeYCbCrTextures(from frame: DecodedFrame) -> (y: MTLTexture, cbcr: MTLTexture)? {
            guard let pixelBuffer = frame.pixelBuffer else { return nil }
            guard let textureCache else { return nil }

            let width  = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            // Plane 0: Luma (Y) — r8Unorm, full resolution
            var cvTextureY: CVMetalTexture?
            let statusY = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .r8Unorm,
                width,
                height,
                0,
                &cvTextureY
            )

            // Plane 1: Chroma (CbCr) — rg8Unorm, half resolution
            var cvTextureCbCr: CVMetalTexture?
            let statusCbCr = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .rg8Unorm,
                width / 2,
                height / 2,
                1,
                &cvTextureCbCr
            )

            guard statusY == kCVReturnSuccess, let cvTextureY,
                  let textureY = CVMetalTextureGetTexture(cvTextureY),
                  statusCbCr == kCVReturnSuccess, let cvTextureCbCr,
                  let textureCbCr = CVMetalTextureGetTexture(cvTextureCbCr) else {
                print("[MetalRenderSurfaceView] Failed to create YCbCr textures: Y=\(statusY) CbCr=\(statusCbCr)")
                return nil
            }

            // Retain both CVMetalTexture wrappers for the lifetime of the GPU frame.
            let slot = retainedPixelBufferTextureSlot
            retainedPixelBufferTextureSlot = (slot + 1) % retainedYTextures.count
            retainedYTextures[slot]    = cvTextureY
            retainedCbCrTextures[slot] = cvTextureCbCr

            return (y: textureY, cbcr: textureCbCr)
        }

        private func makeRenderInput(from frame: DecodedFrame, device: MTLDevice) -> RenderInput? {
            if let textures = makeYCbCrTextures(from: frame) {
                return .ycbcr(y: textures.y, cbcr: textures.cbcr)
            }

            return makeBGRATexture(from: frame, device: device).map(RenderInput.bgra)
        }

        private func makeBGRATexture(from frame: DecodedFrame, device: MTLDevice) -> MTLTexture? {
            guard frame.pixelFormat == .bgra8,
                  let pixelData = frame.pixelData,
                  frame.metadata.width > 0,
                  frame.metadata.height > 0,
                  frame.bytesPerRow >= frame.metadata.width * 4 else {
                return nil
            }

            let requiredBytes = frame.bytesPerRow * frame.metadata.height
            guard requiredBytes > 0, pixelData.count >= requiredBytes else {
                return nil
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: frame.metadata.width,
                height: frame.metadata.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .managed

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                print("[MetalRenderSurfaceView] Failed to create BGRA texture")
                return nil
            }

            pixelData.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, frame.metadata.width, frame.metadata.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: frame.bytesPerRow
                )
            }

            let slot = retainedBGRATextureSlot
            retainedBGRATextureSlot = (slot + 1) % retainedBGRATextures.count
            retainedBGRATextures[slot] = texture
            return texture
        }

        private func encodeRenderInput(
            _ renderInput: RenderInput,
            encoder: MTLRenderCommandEncoder,
            ycbcrPipelineState: MTLRenderPipelineState,
            bgraPipelineState: MTLRenderPipelineState,
            vertexBuffer: MTLBuffer,
            samplerState: MTLSamplerState,
            uniforms: inout RenderUniforms
        ) {
            switch renderInput {
            case .ycbcr(let y, let cbcr):
                encoder.setRenderPipelineState(ycbcrPipelineState)
                encoder.setFragmentTexture(y, index: 0)
                encoder.setFragmentTexture(cbcr, index: 1)
            case .bgra(let texture):
                encoder.setRenderPipelineState(bgraPipelineState)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentTexture(nil, index: 1)
            }

            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        private func makeAspectFitScale(contentWidth: Int, contentHeight: Int, drawableSize: CGSize) -> SIMD2<Float> {
            guard contentWidth > 0,
                  contentHeight > 0,
                  drawableSize.width > 0,
                  drawableSize.height > 0 else {
                return SIMD2<Float>(1.0, 1.0)
            }

            let contentAspect = Float(contentWidth) / Float(contentHeight)
            let drawableAspect = Float(drawableSize.width / drawableSize.height)

            if contentAspect > drawableAspect {
                return SIMD2<Float>(1.0, drawableAspect / contentAspect)
            }

            return SIMD2<Float>(contentAspect / drawableAspect, 1.0)
        }
    }
}

private struct RenderVertex {
    let position: SIMD2<Float>
    let textureCoordinate: SIMD2<Float>
}

private struct RenderUniforms {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
}

private enum RenderInput {
    case ycbcr(y: MTLTexture, cbcr: MTLTexture)
    case bgra(MTLTexture)

    var width: Int {
        switch self {
        case .ycbcr(let y, _):
            return y.width
        case .bgra(let texture):
            return texture.width
        }
    }

    var height: Int {
        switch self {
        case .ycbcr(let y, _):
            return y.height
        case .bgra(let texture):
            return texture.height
        }
    }

    var supportsSpatialUpscale: Bool {
        switch self {
        case .ycbcr:
            return true
        case .bgra:
            return false
        }
    }
}
