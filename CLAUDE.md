# WiredDisplay — Claude Instructions

## Project Overview
Mac-to-Mac screen streaming over Thunderbolt/USB-C using ScreenCaptureKit, VideoToolbox HEVC, Network.framework, private `CGVirtualDisplay`, and Metal rendering on the receiver.

## Recent Changes Since This File Was Last Updated
- Release workflow now resolves `RELEASE_VERSION` from Xcode `MARKETING_VERSION`, requires DisplaySender and DisplayReceiver versions to match, and rejects tag/version mismatches. `workflow_dispatch` no longer accidentally releases under the wrong version.
- Hybrid TCP/UDP startup was hardened:
  - receiver only advertises UDP availability once the datagram listener socket is actually ready
  - sender waits for the negotiated hello/ack before opening the UDP video path
  - startup recovery/keyframe handling for UDP was tightened
- Sender transport queue now distinguishes `control`, `audio`, and `video` traffic. Audio no longer acts like a protected keyframe, and dropped video deltas force the queue to wait for the next keyframe before sending more dependent video.
- Virtual display preset support was expanded substantially:
  - true non-HiDPI 4K is supported
  - standard and advanced preset catalogs exist
  - presets are sorted highest resolution to lowest
  - advanced list includes many Retina and MacBook-style panel sizes
  - Obj-C bridge now honors requested `hiDPI` instead of forcing Retina
  - bridge exposes more candidate modes in “Show all resolutions”
- Receiver raw diagnostics rendering now supports BGRA frames in Metal instead of showing a black screen.
- Receiver frame-index reset logic was fixed so new sessions do not inherit stale “latest frame” state from previous sessions.
- Cursor remoting was added and then heavily iterated:
  - sender can hide the captured cursor and send a dedicated cursor sidecar over the control channel
  - cursor appearance is synced as PNG + hotspot + logical point size
  - I-beam/hand/resize/open-hand/etc. work, not just the arrow
  - sender cursor capture is now primarily event-driven instead of pure polling
  - receiver keeps cursor history and does slight prediction
  - default cursor path now uses a receiver-side AppKit/system cursor mirror instead of the old SwiftUI overlay
  - receiver window hides most local chrome during streaming to reduce local macOS interference
- Receiver-side cursor re-entry and takeover recovery were improved:
  - Y-axis conversion for system cursor warping was fixed
  - hidden/off-screen transitions clear cached warp state
  - local iMac mouse movement no longer permanently “wins” just because the last warped point matched

## Architecture
- **Sender** (`DisplaySender`)
  - `CaptureService` captures the selected display using ScreenCaptureKit
  - `EncoderService` encodes HEVC using VideoToolbox
  - `TransportService` carries control, heartbeats, cursor sidecar, and TCP video/audio
  - `VideoDatagramTransportService` carries UDP video in hybrid mode
  - `SenderSessionCoordinator` owns transport negotiation, virtual display setup, cursor sidecar emission, and telemetry
- **Receiver** (`DisplayReceiver`)
  - `ListenerService` accepts TCP control/video/audio and owns UDP listener readiness
  - `DecoderService` decodes HEVC/H.264 using VideoToolbox
  - `RenderService` publishes decoded frames into `RenderFrameStore`
  - `MetalRenderSurfaceView` renders YUV/BGRA frames and hosts the receiver-side cursor path
  - `ReceiverSessionCoordinator` owns connection state, heartbeat telemetry, cursor state ingestion, and recovery
- **Shared**
  - `Shared/Protocol/` contains message envelopes, binary wire formats, telemetry helpers, bitrate heuristics, and cursor payload types

## Key Files
| File | Role |
|------|------|
| `Shared/Protocol/NetworkProtocol.swift` | Wire constants, envelope/message types, bitrate heuristics, cursor config toggles |
| `Shared/Protocol/FrameMetadata.swift` | Per-frame timing metadata used for end-to-end and stage latency tracking |
| `DisplaySender/App/SenderSessionCoordinator.swift` | Main sender orchestration, display-mode selection, UDP negotiation, cursor tracking |
| `DisplaySender/Services/TransportService.swift` | TCP queueing policy for control/audio/video plus UDP video transport |
| `DisplaySender/Services/CaptureService.swift` | ScreenCaptureKit capture, including sender-cursor on/off behavior |
| `DisplaySender/VirtualDisplay/VirtualDisplayService.swift` | Virtual display preset catalog and mode selection |
| `DisplaySender/VirtualDisplay/VirtualDisplayBridge.m` | Private `CGVirtualDisplay` bridge, mode advertisement, hiDPI handling |
| `DisplayReceiver/App/ReceiverSessionCoordinator.swift` | Receiver state machine, heartbeat replies, cursor payload ingestion |
| `DisplayReceiver/App/MetalRenderSurfaceView.swift` | Metal rendering, BGRA diagnostics, cursor presentation host, system cursor mirror |
| `DisplayReceiver/Services/ListenerService.swift` | TCP listener + UDP readiness/advertisement gating |
| `DisplayReceiver/Services/RenderFrameStore.swift` | Latest frame store plus thread-safe cursor history store |
| `.github/workflows/release.yml` | CI/release workflow with version resolution and release artifact publishing |

## Current Video / Pixel Pipeline
- Capture format: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`420v`)
- Decoder output: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
- `PixelFormat` supports:
  - `yuv420` for the live path
  - `bgra8` for diagnostics / synthetic raw paths
- Metal receiver path:
  - Y plane = `.r8Unorm`
  - CbCr plane = `.rg8Unorm`
  - Rec.709 limited-range conversion in shader
  - drawable remains `.bgra8Unorm`
- Receiver can now also render BGRA diagnostic frames instead of assuming every frame is a `CVPixelBuffer`

## Codec / Timing / Quality
- Default video codec: HEVC (`kCMVideoCodecType_H265`)
- Encoder target: `300 Mbps`
- Min bitrate: `50 Mbps`
- Max bitrate: `2 Gbps`
- Target FPS: `60`
- Capture FPS: `60`
- TCP keyframe interval: `1 second`
- UDP keyframe cadence: `15` frames
- Heartbeats carry:
  - round-trip timing
  - display latency
  - capture -> encode latency
  - encode -> receive latency
  - receive -> render latency

## Transport Behavior
- Control, heartbeats, hello/ack, and cursor sidecar are sent as `NetworkEnvelope`s over TCP.
- Video can run in:
  - `tcp`
  - `udp` hybrid mode with binary datagrams for video and TCP for control/recovery
- TCP sender queue behavior:
  - queue limit is `NetworkProtocol.maxPendingOutboundFrames`
  - queue entries are tagged as `control`, `audio`, or `video`
  - on congestion, old audio is shed before video/control
  - dropping video deltas flips `awaitingKeyFrameAfterDrop` so later deltas are withheld until the next keyframe
- UDP startup behavior:
  - receiver advertises UDP only after listener readiness
  - sender only connects datagram transport after hello/ack negotiation confirms UDP

## Wire Protocol
- `NetworkProtocol.MessageType`
  - `hello`
  - `helloAck`
  - `heartbeat`
  - `videoFrame`
  - `requestKeyFrame`
  - `cursorState`
- Binary video frame layout:
  - `[4 magic][1 reserved][4 headerLen][headerJSON][VPS][SPS][PPS][payload]`
- Cursor sidecar payloads:
  - `CursorStatePayload`
    - sender timestamp
    - normalized X/Y
    - visibility
    - optional appearance blob when the cursor shape changes
  - `CursorAppearancePayload`
    - signature
    - PNG image
    - logical width/height in points
    - hotspot

## Virtual Display / Resolution Model
- `VirtualDisplayPreset` is now pixel-accurate and scale-aware:
  - `nonHiDPI`
  - `retina2x`
- Default fixed preset is now `3840×2160 @ 1x` (`4K non-HiDPI`)
- Standard presets intentionally include both true 4K and Retina-style logical modes.
- Advanced presets include:
  - 8K-class
  - 6K / 5K
  - ultrawides
  - MacBook / Apple display-style panel sizes
  - both `1x` and `2x` variants where meaningful
- Presets are sorted highest resolution to lowest.
- `VirtualDisplayBridge.m` now:
  - respects requested `hiDPI`
  - advertises more candidate modes
  - tries to help macOS expose additional modes in “Show all resolutions”

## Cursor Remoting
- Receiver-side cursor overlay is enabled by default:
  - `NetworkProtocol.enableReceiverSideCursorOverlay = true`
- Current default rendering path:
  - `useReceiverSystemCursorMirror = true`
  - `useSwiftUIReceiverCursorOverlay = false`
- Sender behavior:
  - hides baked-in capture cursor unless testing fallback
  - sends cursor position/visibility continuously
  - sends cursor appearance only when the shape changes
  - uses event monitors for mouse-move/drag plus a lighter refresh timer for appearance refresh
- Receiver behavior:
  - stores latest + previous cursor samples in `ReceiverCursorStore`
  - predicts slightly forward using `cursorPredictionLeadNanoseconds`
  - drives cursor presentation from a `CVDisplayLink`-backed refresh path
  - can mirror the real local system cursor using `NSCursor` + `CGWarpMouseCursorPosition`
- Cursor sizing/alignment:
  - receiver uses sender-provided logical point size so Retina cursor assets are not oversized
  - hotspot alignment is based on sender hotspot data and currently feels correct for the arrow path
- Debug/testing toggles still exist in `NetworkProtocol`:
  - `showSenderCursorFallbackWhileTestingOverlay`
  - `useDebugCursorOverlayMarker`

## Receiver Window / Local macOS Interaction
- `ReceiverStreamWindowManager` now:
  - auto-hides Dock/menu bar while streaming
  - hides traffic-light window buttons
  - disables fullscreen tiling
- This reduces, but does not completely eliminate, local macOS interference when using the mirrored system cursor.
- Important caveat: the system-cursor mirror path is smoother, but because it uses the real local macOS cursor, local OS behaviors can still contend at the top edge or with local/shared-mouse activity.

## Release / CI Notes
- Primary validation script: `./scripts/ci.sh`
- Release workflow now fails early if:
  - sender and receiver `MARKETING_VERSION` differ
  - a pushed tag does not match the app version
- Release artifacts and GitHub releases are keyed off resolved app version, not branch/ref name.

## Current Known Warnings / Caveats
- `CVDisplayLink*` APIs used by the receiver cursor host are deprecated on newer macOS SDKs; current code still builds and works.
- There are still Swift concurrency warnings in sender/receiver coordination code that should be cleaned up before a strict Swift 6 migration.
- `DisplaySender/Info.plist` is still incorrectly present in Copy Bundle Resources and produces the existing Xcode warning.
- Cursor smoothness is much better with the mirrored system cursor, but this path is still more exposed to local macOS behavior than the old purely app-drawn overlay.

## Coding Conventions / Expectations
- Services are `final class`; UI views are SwiftUI or `NSViewRepresentable`
- Avoid CPU color conversion; keep live conversion in Metal
- Favor `guard` + explicit error callbacks over force unwraps in service code
- Keep capture, encode, transport, decode, and render concerns separate; `SessionCoordinator` types own orchestration, not heavy implementation details
- If touching cursor code, inspect both:
  - sender emission path in `SenderSessionCoordinator`
  - receiver presentation path in `MetalRenderSurfaceView`
