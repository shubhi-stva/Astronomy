//
//  SkyRenderer.swift
//  Astronomy
//
//  MetalKit render pass for the sky. Three passes per frame, back to front:
//
//    1. Full-screen background (horizon/atmosphere gradient + Milky Way),
//       driven entirely by uniforms — see SkyBackgroundUniforms.swift.
//    2. Constellation lines, as one line list.
//    3. Point sprites — stars, their glow haloes, Sun/Moon/planets and the
//       selection ring — as one instanced draw call.
//
//  Projection from RA/Dec -> Alt/Az -> screen NDC happens on the CPU once per
//  frame using CoordinateTransformService; the GPU only rasterizes the
//  already-projected geometry. The same pass also emits the bounded set of
//  label candidates the SwiftUI overlay draws.
//

import Foundation
import MetalKit
import simd

@MainActor
final class SkyRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pointPipelineState: MTLRenderPipelineState
    private let linePipelineState: MTLRenderPipelineState
    private let backgroundPipelineState: MTLRenderPipelineState

    /// Supplies the latest frame data; set by the owning SwiftUI view.
    var frameDataProvider: (() -> SkyFrameData)?

    /// Receives the laid-out labels for the SwiftUI overlay, throttled.
    var labelSink: (@MainActor ([SkyLabel]) -> Void)?

    /// Last frame's projected objects, kept for hit-testing on click.
    private(set) var lastProjectedObjects: [ProjectedObject] = []
    private(set) var lastViewportSize: CGSize = .zero

    private let labelEngine = LabelLayoutEngine()
    private var lastLabelPublish: CFTimeInterval = 0
    private var lastPublishedLabels: [SkyLabel] = []

    /// Labels are the only SwiftUI content driven by the sky. Republishing at
    /// the full display rate would invalidate the overlay 60-120 times a
    /// second for no visible benefit, so the layout is pushed at ~30 Hz —
    /// still faster than the eye tracks a fading label, and half the SwiftUI
    /// diffing work.
    private static let labelPublishInterval: CFTimeInterval = 1.0 / 30.0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        guard let library = device.makeDefaultLibrary() else { return nil }

        do {
            let pointDescriptor = MTLRenderPipelineDescriptor()
            pointDescriptor.vertexFunction = library.makeFunction(name: "starVertexShader")
            pointDescriptor.fragmentFunction = library.makeFunction(name: "starFragmentShader")
            pointDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pointDescriptor.colorAttachments[0].isBlendingEnabled = true
            pointDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pointDescriptor.colorAttachments[0].alphaBlendOperation = .add
            // Additive-over-alpha: stars and their haloes accumulate light
            // rather than occluding each other.
            pointDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pointDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pointDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            pointDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
            pointPipelineState = try device.makeRenderPipelineState(descriptor: pointDescriptor)

            let lineDescriptor = MTLRenderPipelineDescriptor()
            lineDescriptor.vertexFunction = library.makeFunction(name: "lineVertexShader")
            lineDescriptor.fragmentFunction = library.makeFunction(name: "lineFragmentShader")
            lineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            lineDescriptor.colorAttachments[0].isBlendingEnabled = true
            lineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            lineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            lineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            lineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            lineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            lineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            linePipelineState = try device.makeRenderPipelineState(descriptor: lineDescriptor)

            let backgroundDescriptor = MTLRenderPipelineDescriptor()
            backgroundDescriptor.vertexFunction = library.makeFunction(name: "backgroundVertexShader")
            backgroundDescriptor.fragmentFunction = library.makeFunction(name: "backgroundFragmentShader")
            backgroundDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            backgroundDescriptor.colorAttachments[0].isBlendingEnabled = false
            backgroundPipelineState = try device.makeRenderPipelineState(descriptor: backgroundDescriptor)
        } catch {
            return nil
        }

        super.init()
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderFrame(in: view)
        }
    }

    private func renderFrame(in view: MTKView) {
        guard let frameData = frameDataProvider?(), frameData.viewportSize.width > 0 else { return }
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lastViewportSize = frameData.viewportSize

        var build = SkyGeometryBuilder(frameData: frameData)
        build.run()
        lastProjectedObjects = build.projectedObjects

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // 1. Background.
        var uniforms = SkyBackgroundUniforms.make(frameData: frameData)
        encoder.setRenderPipelineState(backgroundPipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkyBackgroundUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. Constellation lines.
        if !build.lineVertices.isEmpty {
            encoder.setRenderPipelineState(linePipelineState)
            let length = MemoryLayout<LineVertex>.stride * build.lineVertices.count
            if let buffer = device.makeBuffer(bytes: build.lineVertices, length: length, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: build.lineVertices.count)
            }
        }

        // 3. Point sprites (glow haloes first, then cores — see the builder).
        if !build.pointVertices.isEmpty {
            encoder.setRenderPipelineState(pointPipelineState)
            let length = MemoryLayout<PointVertex>.stride * build.pointVertices.count
            if let buffer = device.makeBuffer(bytes: build.pointVertices, length: length, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: build.pointVertices.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        publishLabelsIfNeeded(candidates: build.labelCandidates, viewportSize: frameData.viewportSize)
    }

    private func publishLabelsIfNeeded(candidates: [SkyLabelCandidate], viewportSize: CGSize) {
        guard let labelSink else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLabelPublish >= Self.labelPublishInterval else { return }
        lastLabelPublish = now

        let labels = labelEngine.layout(candidates: candidates, viewportSize: viewportSize)
        guard labels != lastPublishedLabels else { return }
        lastPublishedLabels = labels
        labelSink(labels)
    }

    // MARK: - Hit testing

    /// Finds the nearest projected object to a viewport normalized-device
    /// coordinate click point, within a small screen-space tolerance.
    ///
    /// Tolerance is expressed in *points* and converted using the viewport
    /// size, so the click target is the same physical size regardless of the
    /// window's aspect ratio.
    func nearestObject(toViewportNDC point: SIMD2<Double>, tolerancePoints: Double = 22) -> CelestialObject? {
        let width = max(Double(lastViewportSize.width), 1)
        let height = max(Double(lastViewportSize.height), 1)

        var best: (object: CelestialObject, distance: Double)?
        for projected in lastProjectedObjects {
            let dxPoints = (projected.ndcPosition.x - point.x) * width / 2
            let dyPoints = (projected.ndcPosition.y - point.y) * height / 2
            let d = (dxPoints * dxPoints + dyPoints * dyPoints).squareRoot()
            if d < tolerancePoints, best == nil || d < best!.distance {
                best = (projected.object, d)
            }
        }
        return best?.object
    }
}
