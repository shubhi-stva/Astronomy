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
import os
import simd

@MainActor
final class SkyRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pointPipelineState: MTLRenderPipelineState
    private let linePipelineState: MTLRenderPipelineState
    private let backgroundPipelineState: MTLRenderPipelineState

    /// All-sky Milky Way panorama, sampled in galactic coordinates by the
    /// background shader. Nil if the resource is missing or fails to decode,
    /// in which case the shader keeps the analytic band it always had.
    /// See DATA_SOURCES.md for source and licence (ESO/S. Brunier, CC BY 4.0).
    private var milkyWayTexture: MTLTexture?
    /// A 1x1 black stand-in, bound when the panorama is unavailable: a Metal
    /// fragment function's texture argument must always be bound.
    private let fallbackTexture: MTLTexture?
    /// The same idea for the point pass, whose fragment function declares a
    /// `texture2d_array` and so cannot be handed the 2D fallback above.
    private let fallbackArrayTexture: MTLTexture?
    private let milkyWaySampler: MTLSamplerState?

    /// Bundled planetary surface maps, as one array texture. Nil until the
    /// background load finishes, and nil forever if it fails — the procedural
    /// disks are a complete fallback. See `PlanetSurfaceMaps`.
    private var surfaceMapTexture: MTLTexture?
    /// Bound in the point pass. Same wrap rules as the panorama: longitude is
    /// periodic, latitude is not.
    private let surfaceMapSampler: MTLSamplerState?

    /// Supplies the latest frame data; set by the owning SwiftUI view.
    var frameDataProvider: (() -> SkyFrameData)?

    /// Receives the laid-out labels for the SwiftUI overlay, throttled.
    var labelSink: (@MainActor ([SkyLabel]) -> Void)?

    /// Last frame's projected objects, kept for hit-testing on click.
    private(set) var lastProjectedObjects: [ProjectedObject] = []
    private(set) var lastViewportSize: CGSize = .zero

    /// Reusable vertex storage. `device.makeBuffer(bytes:)` allocates a fresh
    /// Metal buffer *every frame*, which is a per-frame trip through the
    /// allocator and the VM system on the thread with the tightest deadline in
    /// the app. These grow to the high-water mark and are then reused.
    ///
    /// Three of each, cycled per frame: a buffer handed to the GPU is not
    /// necessarily finished with when the next frame starts encoding, and
    /// overwriting it would tear the geometry. Three is the depth MetalKit's
    /// own triple buffering already implies.
    private var lineBuffers = RingVertexBuffer(slotCount: 3)
    private var pointBuffers = RingVertexBuffer(slotCount: 3)

    /// Per-stage frame timings. Always collected (the cost is a pair of clock
    /// reads per stage) and always emitted as signposts for Instruments; the
    /// periodic log is opt-in via the ASTRONOMY_FRAME_STATS environment
    /// variable.
    let profiler = RenderProfiler()
    private static let logger = Logger(subsystem: "Astronomy", category: "render")
    private static let logsFrameStatistics =
        ProcessInfo.processInfo.environment["ASTRONOMY_FRAME_STATS"] == "1"
    private var framesSinceLastStatisticsLog = 0

    private let labelEngine = LabelLayoutEngine()
    private var lastLabelPublish: CFTimeInterval = 0
    private var lastPublishedLabels: [SkyLabel] = []

    /// Labels are published every frame, in lockstep with the geometry they
    /// annotate.
    ///
    /// This used to be throttled to ~30 Hz to halve the SwiftUI diffing work.
    /// That was a mistake: a label is *attached* to its object, so a frame
    /// where the sky moved and the label did not is a frame where the label is
    /// visibly in the wrong place. At 120 Hz the throttle held labels up to
    /// three frames behind a pan, which reads as them dragging along behind
    /// the stars. The layout is cheap (a few dozen candidates) and the
    /// `labels != lastPublishedLabels` check below still suppresses the
    /// genuinely redundant updates, so nothing is gained by waiting.
    private static let labelPublishInterval: CFTimeInterval = 0

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

        // Wrapping in x (galactic longitude is periodic) and clamped in y
        // (the poles are the edges of the image).
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .clampToEdge
        milkyWaySampler = device.makeSamplerState(descriptor: samplerDescriptor)
        surfaceMapSampler = device.makeSamplerState(descriptor: samplerDescriptor)

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        fallbackTexture = device.makeTexture(descriptor: fallbackDescriptor)
        var black: [UInt8] = [0, 0, 0, 255]
        fallbackTexture?.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &black, bytesPerRow: 4
        )

        let fallbackArrayDescriptor = MTLTextureDescriptor()
        fallbackArrayDescriptor.textureType = .type2DArray
        fallbackArrayDescriptor.pixelFormat = .rgba8Unorm
        fallbackArrayDescriptor.width = 1
        fallbackArrayDescriptor.height = 1
        fallbackArrayDescriptor.arrayLength = PlanetSurfaceMaps.entries.count
        fallbackArrayDescriptor.usage = [.shaderRead]
        fallbackArrayTexture = device.makeTexture(descriptor: fallbackArrayDescriptor)
        for slice in 0..<PlanetSurfaceMaps.entries.count {
            var grey: [UInt8] = [128, 128, 128, 255]
            fallbackArrayTexture?.replace(
                region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: slice,
                withBytes: &grey, bytesPerRow: 4, bytesPerImage: 4
            )
        }

        super.init()

        loadMilkyWayTexture()
        loadSurfaceMaps()
    }

    /// Decodes and uploads the bundled planet maps off the first frame's
    /// critical path, exactly like the panorama above: until it lands, the
    /// planets and the Moon draw their procedural surfaces, which is what they
    /// did before these existed.
    private func loadSurfaceMaps() {
        let device = self.device
        let queue = self.commandQueue
        Task.detached(priority: .utility) {
            guard let texture = PlanetSurfaceMaps.makeTextureArray(
                device: device, commandQueue: queue
            ) else { return }
            await MainActor.run { self.surfaceMapTexture = texture }
        }
    }

    /// Loads the bundled panorama off the critical path of the first frame:
    /// the shader falls back to the analytic band until it arrives, so a
    /// slow decode costs nothing but a moment of the old look.
    private func loadMilkyWayTexture() {
        let device = self.device
        Task.detached(priority: .utility) {
            guard let url = Bundle.main.url(forResource: "milkyway_panorama", withExtension: "jpg") else { return }
            let loader = MTKTextureLoader(device: device)
            let texture = try? await loader.newTexture(
                URL: url,
                options: [
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                    .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
                    .generateMipmaps: NSNumber(value: true),
                    .SRGB: NSNumber(value: false)
                ]
            )
            guard let texture else { return }
            await MainActor.run { self.milkyWayTexture = texture }
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            renderFrame(in: view)
        }
    }

    private func renderFrame(in view: MTKView) {
        let frameStart = DispatchTime.now().uptimeNanoseconds

        let frameDataStart = frameStart
        guard let frameData = frameDataProvider?(), frameData.viewportSize.width > 0 else { return }
        profiler.record(
            .frameData,
            seconds: Double(DispatchTime.now().uptimeNanoseconds - frameDataStart) * 1e-9
        )

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        lastViewportSize = frameData.viewportSize

        var build = SkyGeometryBuilder(frameData: frameData)
        build.profiler = profiler
        build.run()
        lastProjectedObjects = build.projectedObjects

        // Vertex storage is acquired before the encoder so the upload cost is
        // measured on its own rather than hidden inside encoding.
        let uploadStart = DispatchTime.now().uptimeNanoseconds
        let lineBuffer = lineBuffers.buffer(for: build.lineVertices, device: device)
        let pointBuffer = pointBuffers.buffer(for: build.pointVertices, device: device)
        profiler.record(
            .bufferUpload,
            seconds: Double(DispatchTime.now().uptimeNanoseconds - uploadStart) * 1e-9
        )

        let encodeStart = DispatchTime.now().uptimeNanoseconds
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // 1. Background.
        var uniforms = SkyBackgroundUniforms.make(frameData: frameData)
        uniforms.milkyWayTextureStrength = milkyWayTexture == nil ? 0 : 1
        encoder.setRenderPipelineState(backgroundPipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkyBackgroundUniforms>.stride, index: 0)
        encoder.setFragmentTexture(milkyWayTexture ?? fallbackTexture, index: 0)
        encoder.setFragmentSamplerState(milkyWaySampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // The one uniform the other two passes need. Bound per pass rather than
        // once, because a pipeline state change does not carry fragment
        // arguments across.
        var chrome = ChromeUniforms(
            nightVisionStrength: Float(frameData.nightVisionStrength)
        )

        // 2. Constellation lines.
        if let lineBuffer, !build.lineVertices.isEmpty {
            encoder.setRenderPipelineState(linePipelineState)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.setFragmentBytes(&chrome, length: MemoryLayout<ChromeUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: build.lineVertices.count)
        }

        // 3. Point sprites (glow haloes first, then cores — see the builder).
        if let pointBuffer, !build.pointVertices.isEmpty {
            encoder.setRenderPipelineState(pointPipelineState)
            encoder.setVertexBuffer(pointBuffer, offset: 0, index: 0)
            // The fragment function's texture argument must always be bound,
            // even when there are no maps yet; `param7` is -1 on every sprite
            // in that case, so nothing samples it.
            encoder.setFragmentTexture(surfaceMapTexture ?? fallbackArrayTexture, index: 0)
            encoder.setFragmentSamplerState(surfaceMapSampler, index: 0)
            encoder.setFragmentBytes(&chrome, length: MemoryLayout<ChromeUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: build.pointVertices.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        profiler.record(
            .encode,
            seconds: Double(DispatchTime.now().uptimeNanoseconds - encodeStart) * 1e-9
        )

        publishLabelsIfNeeded(candidates: build.labelCandidates, viewportSize: frameData.viewportSize)

        profiler.record(
            .frameTotal,
            seconds: Double(DispatchTime.now().uptimeNanoseconds - frameStart) * 1e-9
        )
        logFrameStatisticsIfRequested()
    }

    /// Dumps the rolling per-stage table roughly every ten seconds when
    /// ASTRONOMY_FRAME_STATS=1 is set. Off by default: the signposts are the
    /// primary channel, and an app that logs every frame is an app that is
    /// slower for having been measured.
    private func logFrameStatisticsIfRequested() {
        guard Self.logsFrameStatistics else { return }
        framesSinceLastStatisticsLog += 1
        guard framesSinceLastStatisticsLog >= 600 else { return }
        framesSinceLastStatisticsLog = 0
        Self.logger.info("\(self.profiler.formattedReport(title: "frame stages"), privacy: .public)")
    }

    private func publishLabelsIfNeeded(candidates: [SkyLabelCandidate], viewportSize: CGSize) {
        guard let labelSink else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLabelPublish >= Self.labelPublishInterval else { return }
        lastLabelPublish = now

        let labels = profiler.measure(.labelLayout) {
            labelEngine.layout(candidates: candidates, viewportSize: viewportSize)
        }
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
