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
            out.position = float4(in.position * uniforms.scale, 0.0, 1.0);
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
        """

        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var samplerState: MTLSamplerState?
        private var textureCache: CVMetalTextureCache?

        // Retain both planes per slot to prevent premature CVMetalTexture deallocation.
        private var retainedYTextures: [CVMetalTexture?] = Array(repeating: nil, count: 3)
        private var retainedCbCrTextures: [CVMetalTexture?] = Array(repeating: nil, count: 3)
        private var retainedPixelBufferTextureSlot = 0

        // MetalFX Spatial Scaler state
        private var spatialScaler: MTLFXSpatialScaler?
        private var intermediateColorTexture: MTLTexture?
        private var currentInputWidth: Int = 0
        private var currentInputHeight: Int = 0
        private var currentOutputWidth: Int = 0
        private var currentOutputHeight: Int = 0

        func attach(to view: MTKView) {
            guard let device = view.device else { return }

            commandQueue = device.makeCommandQueue()
            vertexBuffer = makeVertexBuffer(device: device)
            samplerState = makeSamplerState(device: device)
            pipelineState = makePipelineState(device: device, colorPixelFormat: .bgra8Unorm)

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
            guard let device = view.device,
                  let commandQueue,
                  let pipelineState,
                  let vertexBuffer,
                  let samplerState,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let drawable = view.currentDrawable else {
                return
            }

            let frame = RenderFrameStore.shared.snapshot()
            let textures = frame.flatMap { makeYCbCrTextures(from: $0) }

            guard let textures else {
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

            let inputWidth  = textures.y.width
            let inputHeight = textures.y.height
            let outputWidth  = Int(view.drawableSize.width)
            let outputHeight = Int(view.drawableSize.height)

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
                    pipelineState: pipelineState,
                    vertexBuffer: vertexBuffer,
                    samplerState: samplerState,
                    textures: textures
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
            var uniforms = RenderUniforms(scale: SIMD2<Float>(1.0, 1.0))

            offscreenEncoder.setRenderPipelineState(pipelineState)
            offscreenEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            offscreenEncoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            offscreenEncoder.setFragmentTexture(textures.y, index: 0)
            offscreenEncoder.setFragmentTexture(textures.cbcr, index: 1)
            offscreenEncoder.setFragmentSamplerState(samplerState, index: 0)
            offscreenEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            offscreenEncoder.endEncoding()

            // --- Pass 2: MetalFX Spatial Upscale → drawable ---
            if let spatialScaler {
                spatialScaler.colorTexture = intermediateColorTexture
                spatialScaler.outputTexture = drawable.texture
                spatialScaler.encode(commandBuffer: commandBuffer)
            }

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
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: inputWidth,
                height: inputHeight,
                mipmapped: false
            )
            textureDescriptor.usage = [.renderTarget, .shaderRead]
            textureDescriptor.storageMode = .private
            intermediateColorTexture = device.makeTexture(descriptor: textureDescriptor)

            guard intermediateColorTexture != nil else {
                print("[MetalRenderSurfaceView] Failed to create intermediate texture \(inputWidth)x\(inputHeight)")
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

        /// Fallback: direct single-pass render to drawable when MetalFX is unavailable.
        private func drawDirectToDrawable(
            view: MTKView,
            commandBuffer: MTLCommandBuffer,
            drawable: CAMetalDrawable,
            pipelineState: MTLRenderPipelineState,
            vertexBuffer: MTLBuffer,
            samplerState: MTLSamplerState,
            textures: (y: MTLTexture, cbcr: MTLTexture)
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
                    contentWidth: textures.y.width,
                    contentHeight: textures.y.height,
                    drawableSize: view.drawableSize
                )
            )

            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            encoder.setFragmentTexture(textures.y, index: 0)
            encoder.setFragmentTexture(textures.cbcr, index: 1)
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
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

        private func makePipelineState(device: MTLDevice, colorPixelFormat: MTLPixelFormat) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "texturedQuadVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "texturedQuadFragment")
                descriptor.vertexDescriptor = makeVertexDescriptor()
                descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
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
}
