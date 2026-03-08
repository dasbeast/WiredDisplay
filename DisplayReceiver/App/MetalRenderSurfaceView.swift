import SwiftUI
import MetalKit
import CoreImage

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
        private var commandQueue: MTLCommandQueue?
        private var ciContext: CIContext?
        private let colorSpace = CGColorSpaceCreateDeviceRGB()

        func attach(to view: MTKView) {
            guard let device = view.device else { return }
            commandQueue = device.makeCommandQueue()
            ciContext = CIContext(mtlDevice: device)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            _ = view
            _ = size
        }

        func draw(in view: MTKView) {
            guard let commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let drawable = view.currentDrawable else {
                return
            }

            let targetBounds = CGRect(x: 0, y: 0, width: view.drawableSize.width, height: view.drawableSize.height)

            if let frame = RenderFrameStore.shared.snapshot(),
               frame.pixelFormat == .bgra8,
               frame.metadata.width > 0,
               frame.metadata.height > 0,
               frame.bytesPerRow > 0,
               let ciContext {
                if let pixelBuffer = frame.pixelBuffer {
                    let image = CIImage(cvPixelBuffer: pixelBuffer)
                    renderImage(image, to: drawable.texture, in: targetBounds, ciContext: ciContext, commandBuffer: commandBuffer)
                } else if let pixelData = frame.pixelData {
                    let image = CIImage(
                        bitmapData: pixelData,
                        bytesPerRow: frame.bytesPerRow,
                        size: CGSize(width: frame.metadata.width, height: frame.metadata.height),
                        format: .BGRA8,
                        colorSpace: colorSpace
                    )

                    renderImage(image, to: drawable.texture, in: targetBounds, ciContext: ciContext, commandBuffer: commandBuffer)
                }
            } else if let renderPassDescriptor = view.currentRenderPassDescriptor {
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
                encoder?.endEncoding()
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func renderImage(
            _ image: CIImage,
            to texture: MTLTexture,
            in targetBounds: CGRect,
            ciContext: CIContext,
            commandBuffer: MTLCommandBuffer
        ) {
            guard image.extent.width > 0, image.extent.height > 0, targetBounds.width > 0, targetBounds.height > 0 else {
                return
            }

            let scaleX = targetBounds.width / image.extent.width
            let scaleY = targetBounds.height / image.extent.height
            let scale = min(scaleX, scaleY)

            let scaledWidth = image.extent.width * scale
            let scaledHeight = image.extent.height * scale
            let offsetX = (targetBounds.width - scaledWidth) * 0.5
            let offsetY = (targetBounds.height - scaledHeight) * 0.5

            let transformed = image.transformed(
                by: CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: offsetX / scale, y: offsetY / scale)
            )

            ciContext.render(
                transformed,
                to: texture,
                commandBuffer: commandBuffer,
                bounds: targetBounds,
                colorSpace: colorSpace
            )
        }
    }
}
