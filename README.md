# WiredDisplay

WiredDisplay is a two-app macOS project for using one Mac as a low-latency display receiver for another Mac over a wired network path such as Thunderbolt Bridge.

The real app is split into:

- `DisplaySender`: creates a virtual display, captures it, encodes it, and streams it
- `DisplayReceiver`: listens for connections, decodes frames, plays audio, and presents the stream full screen

The top-level `WiredDisplay` target is currently just a placeholder shell. The active work happens in the `DisplaySender` and `DisplayReceiver` targets.

## Current Behavior

- Receiver is a menu bar app.
- Receiver advertises itself on the local network with Bonjour.
- Sender discovers receivers automatically and lets you choose one from the UI.
- Sender streams video over `TCP`.
- Control messages stay on `TCP`.
- Cursor motion may use a dedicated `UDP` side channel when receiver-side cursor overlay is enabled.
- Audio is captured on the sender and played by the receiver app over `TCP`.
- Receiver automatically opens the stream window and enters full screen when a session starts.
- Receiver prevents idle sleep and screen saver activation while running.

## How It Works

1. `DisplayReceiver` starts listening on port `50999` and advertises itself with Bonjour.
2. `DisplaySender` discovers the receiver and connects.
3. During handshake, the receiver sends its current display metrics.
4. Sender creates a virtual display using those metrics as the starting point.
5. Sender captures that virtual display with `ScreenCaptureKit`.
6. Sender encodes frames with `VideoToolbox` HEVC.
7. Frames are sent to the receiver over the selected transport.
8. Receiver decodes frames with `VideoToolbox` and renders them with Metal.
9. Sender system audio is captured and replayed through the receiver Mac's current output device.

## Transport Modes

- `TCP`
  - Carries control traffic, video, and audio.
  - Reference and only supported video path.

- `UDP Cursor Sidecar`
  - Used only for low-latency cursor motion when receiver-side cursor overlay is enabled.
  - Cursor appearance and control still remain on the main control path as needed.

## Repository Layout

- `DisplaySender/App`
  - sender UI and session coordinator
- `DisplaySender/Services`
  - capture, encoding, transport, discovery
- `DisplaySender/VirtualDisplay`
  - private `CGVirtualDisplay` bridge and mode management
- `DisplayReceiver/App`
  - menu bar app, session coordination, Metal presentation
- `DisplayReceiver/Services`
  - listener, decoder, audio playback, advertisement, power management
- `Shared/Protocol`
  - shared network protocol, frame formats, diagnostics

## Build

Open `WiredDisplay.xcodeproj` in Xcode and run the two app targets separately:

- `DisplayReceiver` on the Mac that should act as the monitor
- `DisplaySender` on the Mac that should stream to it

You can also build from Terminal:

```sh
xcodebuild -project WiredDisplay.xcodeproj -scheme DisplaySender build
xcodebuild -project WiredDisplay.xcodeproj -scheme DisplayReceiver build
```

## Tests And CI

The shared protocol layer now has a lightweight SwiftPM package and unit test suite. Run the full local validation pass with:

```sh
./scripts/ci.sh
```

That script runs:

- `swift test --parallel`
- `xcodebuild` for `DisplaySender`
- `xcodebuild` for `DisplayReceiver`

GitHub Actions mirrors the same checks in [`.github/workflows/ci.yml`](.github/workflows/ci.yml).

For tagged release automation and the required GitHub secrets, see [`docs/ci-cd.md`](docs/ci-cd.md).

## Typical Run Flow

1. Launch `DisplayReceiver`.
2. Confirm it appears in the menu bar and shows as discoverable.
3. Launch `DisplaySender`.
4. Pick the receiver from the discovered list.
5. Choose `Connect & Stream`.
6. Choose the preset and pipeline that fit the sender Mac and network path.
7. After the session starts, watch the sender stats for FPS and latency.

## Known Constraints

- The project uses private `CGVirtualDisplay` APIs.
- Effective latency and sharpness still vary by sender Mac, selected preset, and chosen network path.
- Video transport is `TCP` only. The remaining `UDP` path is reserved for cursor motion telemetry/overlay.
- Audio playback is app-level audio forwarding. It does not create a new macOS system output device in Sound settings.

## Useful Files

- `DisplaySender/App/SenderSessionCoordinator.swift`
- `DisplaySender/App/SenderRootView.swift`
- `DisplaySender/Services/CaptureService.swift`
- `DisplaySender/Services/EncoderService.swift`
- `DisplaySender/Services/TransportService.swift`
- `DisplaySender/VirtualDisplay/VirtualDisplayBridge.m`
- `DisplaySender/VirtualDisplay/VirtualDisplayService.swift`
- `DisplayReceiver/App/ReceiverAppController.swift`
- `DisplayReceiver/App/ReceiverSessionCoordinator.swift`
- `DisplayReceiver/App/ReceiverMenuBarView.swift`
- `DisplayReceiver/Services/ListenerService.swift`
- `DisplayReceiver/Services/DecoderService.swift`
- `DisplayReceiver/Services/AudioPlaybackService.swift`
- `Shared/Protocol/NetworkProtocol.swift`
