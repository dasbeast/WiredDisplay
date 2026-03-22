# WiredDisplay — Claude Instructions

## Project Overview
Mac-to-Mac screen streaming pipeline over Thunderbolt/USB-C using ScreenCaptureKit, VideoToolbox HEVC, and Metal rendering.

## Architecture
- **Sender** (DisplaySender): `CaptureService` → `EncoderService` → `TransportService`
- **Receiver** (DisplayReceiver): `ListenerService` → `DecoderService` → `RenderService` → `MetalRenderSurfaceView`
- `Shared/` — protocol types shared between both targets

## Key Files
| File | Role |
|------|------|
| `Shared/Protocol/NetworkProtocol.swift` | Wire constants, `BinaryFrameWire` serialize/deserialize |
| `Shared/Protocol/VideoFrameTypes.swift` | `PixelFormat`, `VideoCodec`, `CapturedFrame`, `EncodedFrame`, `DecodedFrame` |
| `DisplaySender/Services/CaptureService.swift` | SCStream capture; outputs YUV 420v pixel buffers |
| `DisplaySender/Services/EncoderService.swift` | VideoToolbox HEVC encoder |
| `DisplayReceiver/Services/DecoderService.swift` | VideoToolbox HEVC + H.264 decoder; outputs YUV 420v pixel buffers |
| `DisplayReceiver/App/MetalRenderSurfaceView.swift` | Metal MTKView; YUV bi-planar → RGB via Rec.709 shader |
| `DisplayReceiver/Services/ListenerService.swift` | TCP listener, `onBinaryVideoFrame` callback |
| `DisplaySender/VirtualDisplay/VirtualDisplayService.swift` | Private CGVirtualDisplay API |

## Pixel Format Pipeline (as of YUV upgrade)
- **Capture format**: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` (`420v`)
- **Decoder output**: `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`
- **PixelFormat enum**: `bgra8` (legacy/synthetic) | `yuv420` (live capture & decode)
- **Metal rendering**: two textures — plane 0 Y (`.r8Unorm`), plane 1 CbCr (`.rg8Unorm`); Rec.709 limited-range matrix in fragment shader
- **MTKView drawable**: `.bgra8Unorm` — the screen output is still BGRA; only shader inputs are YUV planes

## Codec & Quality
- Codec: HEVC (H.265) — `kCMVideoCodecType_H265`, profile `HEVC_Main_AutoLevel`
- Quality: 0.97 (near-lossless)
- Bitrate: 300 Mbps target, 2 Gbps max (Thunderbolt 3 = 40 Gbps headroom)
- Pixel cap: 22.1 MP (supports 5120×2880 HiDPI)
- Key frame interval: 4 seconds

## Wire Protocol
- Binary frame layout: `[4 magic][1 reserved][4 headerLen][headerJSON][VPS][SPS][PPS][payload]`
- VPS is HEVC-only; `vpsLength: Int?` in `BinaryFrameHeader` (nil → 0 for H.264 backward compat)
- `onBinaryVideoFrame` callback: `(BinaryFrameHeader, Data?, Data?, Data?, Data)` → (vps, sps, pps, payload)
- `EncodedFrame.h264SPS/h264PPS` reused for HEVC SPS/PPS; `hevcVPS` is a new optional field

## Default Resolution
- 2560×1440 logical → 5120×2880 physical pixels at HiDPI 2× scale

## Coding Conventions
- Services are `final class`; views are `struct : NSViewRepresentable`
- Capture and decode callbacks run on dedicated `DispatchQueue`s (`.userInteractive`)
- Metal retained-texture ring buffers use 3 slots to avoid GPU-CPU sync stalls
- Do not introduce color conversion on the CPU — keep it in the GPU shader
- Avoid force-unwraps in service code; use `guard` + error callbacks
