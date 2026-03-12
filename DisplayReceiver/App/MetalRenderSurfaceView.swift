import SwiftUI
import MetalKit
import CoreVideo

/// Metal-backed surface that renders the most recent decoded BGRA frame.
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
        view.framebufferOnly = true
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
            texture2d<float> sourceTexture [[texture(0)]],
            sampler sourceSampler [[sampler(0)]]
        ) {
            return sourceTexture.sample(sourceSampler, in.textureCoordinate);
        }
        """

        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var vertexBuffer: MTLBuffer?
        private var samplerState: MTLSamplerState?
        private var textureCache: CVMetalTextureCache?
        private var retainedPixelBufferTextures: [CVMetalTexture?] = Array(repeating: nil, count: 3)
        private var retainedPixelBufferTextureSlot = 0
        private var retainedRawTextures: [MTLTexture?] = Array(repeating: nil, count: 3)
        private var retainedRawTextureSlot = 0

        func attach(to view: MTKView) {
            guard let device = view.device else { return }

            commandQueue = device.makeCommandQueue()
            vertexBuffer = makeVertexBuffer(device: device)
            samplerState = makeSamplerState(device: device)
            pipelineState = makePipelineState(device: device, colorPixelFormat: view.colorPixelFormat)

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
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else {
                return
            }

            let frame = RenderFrameStore.shared.snapshot()
            let sourceTexture = frame.flatMap { makeTexture(from: $0, device: device) }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }

            if let sourceTexture {
                var uniforms = RenderUniforms(
                    scale: makeAspectFitScale(
                        contentWidth: sourceTexture.width,
                        contentHeight: sourceTexture.height,
                        drawableSize: view.drawableSize
                    )
                )

                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)
                encoder.setFragmentTexture(sourceTexture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

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

        private func makeTexture(from frame: DecodedFrame, device: MTLDevice) -> MTLTexture? {
            if let pixelBuffer = frame.pixelBuffer {
                return makeTexture(from: pixelBuffer)
            }

            guard let pixelData = frame.pixelData,
                  frame.pixelFormat == .bgra8,
                  frame.metadata.width > 0,
                  frame.metadata.height > 0,
                  frame.bytesPerRow > 0 else {
                return nil
            }

            let requiredByteCount = frame.bytesPerRow * frame.metadata.height
            guard pixelData.count >= requiredByteCount else { return nil }

            return makeTexture(
                from: pixelData,
                width: frame.metadata.width,
                height: frame.metadata.height,
                bytesPerRow: frame.bytesPerRow,
                device: device
            )
        }

        private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
            guard let textureCache else { return nil }

            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )

            guard status == kCVReturnSuccess,
                  let cvTexture,
                  let texture = CVMetalTextureGetTexture(cvTexture) else {
                return nil
            }

            retainedPixelBufferTextures[retainedPixelBufferTextureSlot] = cvTexture
            retainedPixelBufferTextureSlot = (retainedPixelBufferTextureSlot + 1) % retainedPixelBufferTextures.count
            return texture
        }

        private func makeTexture(
            from pixelData: Data,
            width: Int,
            height: Int,
            bytesPerRow: Int,
            device: MTLDevice
        ) -> MTLTexture? {
            let slot = retainedRawTextureSlot
            retainedRawTextureSlot = (retainedRawTextureSlot + 1) % retainedRawTextures.count

            let texture: MTLTexture
            if let existingTexture = retainedRawTextures[slot],
               existingTexture.width == width,
               existingTexture.height == height {
                texture = existingTexture
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead]
                descriptor.storageMode = .shared

                guard let newTexture = device.makeTexture(descriptor: descriptor) else { return nil }
                retainedRawTextures[slot] = newTexture
                texture = newTexture
            }

            pixelData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: bytesPerRow
                )
            }

            return texture
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
