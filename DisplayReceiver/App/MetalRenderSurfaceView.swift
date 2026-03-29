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

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.delegate = context.coordinator

        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        _ = nsView
        _ = context
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
            guard !NetworkProtocol.useSwiftUIReceiverCursorOverlay else {
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
