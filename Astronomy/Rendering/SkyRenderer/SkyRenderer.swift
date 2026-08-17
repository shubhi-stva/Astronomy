//
//  SkyRenderer.swift
//  Astronomy
//
//  MetalKit render pass for the sky: stars, Sun/Moon/planets as instanced
//  point sprites (single draw call), plus constellation lines as a line
//  list (single draw call). Projection from RA/Dec -> Alt/Az -> screen NDC
//  happens on the CPU once per frame using CoordinateTransformService; the
//  GPU only rasterizes the already-projected points/lines.
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

    /// Supplies the latest frame data; set by the owning SwiftUI view.
    var frameDataProvider: (() -> SkyFrameData)?

    /// Last frame's projected objects, kept for hit-testing on click.
    private(set) var lastProjectedObjects: [ProjectedObject] = []

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

        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1.0)

        let (pointVertices, projected) = buildPointVertices(frameData: frameData)
        let lineVertices = buildLineVertices(frameData: frameData)
        lastProjectedObjects = projected

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        if !lineVertices.isEmpty {
            encoder.setRenderPipelineState(linePipelineState)
            let length = MemoryLayout<LineVertex>.stride * lineVertices.count
            if let buffer = device.makeBuffer(bytes: lineVertices, length: length, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineVertices.count)
            }
        }

        if !pointVertices.isEmpty {
            encoder.setRenderPipelineState(pointPipelineState)
            let length = MemoryLayout<PointVertex>.stride * pointVertices.count
            if let buffer = device.makeBuffer(bytes: pointVertices, length: length, options: .storageModeShared) {
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointVertices.count)
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Buffer construction

    private func buildPointVertices(frameData: SkyFrameData) -> ([PointVertex], [ProjectedObject]) {
        var vertices: [PointVertex] = []
        vertices.reserveCapacity(frameData.stars.count + frameData.solarSystemObjects.count)
        var projected: [ProjectedObject] = []

        let aspect = Float(frameData.viewportSize.height / max(frameData.viewportSize.width, 1))

        for star in frameData.stars {
            let object = star.asCelestialObject
            guard let ndc = project(object.equatorial, frameData: frameData, aspect: aspect) else { continue }
            let color = StarAppearance.color(colorIndex: star.colorIndex)
            let size = StarAppearance.pointSize(forMagnitude: star.magnitude)
            vertices.append(PointVertex(positionNDC: SIMD2(Float(ndc.x), Float(ndc.y)), color: color, pointSize: size))
            projected.append(ProjectedObject(object: object, ndcPosition: ndc))
        }

        for object in frameData.solarSystemObjects {
            guard let ndc = project(object.equatorial, frameData: frameData, aspect: aspect) else { continue }
            let color: SIMD4<Float>
            let size: Float
            switch object.kind {
            case .sun: color = StarAppearance.sunColor; size = 22
            case .moon: color = StarAppearance.moonColor; size = 18
            case .planet: color = StarAppearance.planetColor; size = 8
            case .star: color = StarAppearance.color(colorIndex: nil); size = 4
            }
            vertices.append(PointVertex(positionNDC: SIMD2(Float(ndc.x), Float(ndc.y)), color: color, pointSize: size))
            projected.append(ProjectedObject(object: object, ndcPosition: ndc))
        }

        return (vertices, projected)
    }

    private func buildLineVertices(frameData: SkyFrameData) -> [LineVertex] {
        guard !frameData.starsByID.isEmpty else { return [] }
        var vertices: [LineVertex] = []
        vertices.reserveCapacity(frameData.constellationLines.count * 2)
        let aspect = Float(frameData.viewportSize.height / max(frameData.viewportSize.width, 1))

        for segment in frameData.constellationLines {
            guard let s1 = frameData.starsByID[segment.starID1],
                  let s2 = frameData.starsByID[segment.starID2] else { continue }
            let eq1 = EquatorialCoordinate(rightAscensionDegrees: s1.ra, declinationDegrees: s1.dec)
            let eq2 = EquatorialCoordinate(rightAscensionDegrees: s2.ra, declinationDegrees: s2.dec)
            guard let ndc1 = project(eq1, frameData: frameData, aspect: aspect),
                  let ndc2 = project(eq2, frameData: frameData, aspect: aspect) else { continue }
            // Skip segments that wrap unreasonably far across the screen (projection seam).
            if simd_distance(ndc1, ndc2) > 1.2 { continue }
            vertices.append(LineVertex(positionNDC: SIMD2(Float(ndc1.x), Float(ndc1.y)), color: StarAppearance.constellationLineColor))
            vertices.append(LineVertex(positionNDC: SIMD2(Float(ndc2.x), Float(ndc2.y)), color: StarAppearance.constellationLineColor))
        }
        return vertices
    }

    private func project(_ equatorial: EquatorialCoordinate, frameData: SkyFrameData, aspect: Float) -> SIMD2<Double>? {
        let horizontal = CoordinateTransformService.horizontal(
            from: equatorial,
            observer: frameData.observerLocation,
            julianDay: frameData.julianDay
        )
        guard horizontal.altitudeDegrees > -5 else { return nil } // small margin below horizon
        guard let ndc = CoordinateTransformService.stereographicProject(
            horizontal: horizontal,
            center: frameData.cameraCenter,
            fieldOfViewDegrees: frameData.cameraFieldOfViewDegrees
        ) else { return nil }
        // Correct X for aspect ratio so circles stay circular on non-square viewports.
        let corrected = SIMD2(ndc.x * Double(aspect), ndc.y)
        return corrected
    }

    // MARK: - Hit testing

    /// Finds the nearest projected object to a normalized-device-coordinate
    /// click point, within a small screen-space tolerance.
    func nearestObject(toNDC point: SIMD2<Double>, toleranceNDC: Double = 0.05) -> CelestialObject? {
        var best: (object: CelestialObject, distance: Double)?
        for projected in lastProjectedObjects {
            let d = simd_distance(projected.ndcPosition, point)
            if d < toleranceNDC, (best == nil || d < best!.distance) {
                best = (projected.object, d)
            }
        }
        return best?.object
    }
}
