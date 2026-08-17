//
//  SkyMetalView.swift
//  Astronomy
//
//  NSViewRepresentable wrapping an MTKView, plus a small interactive
//  subclass that turns mouse drag / scroll / click into camera pan, zoom,
//  and object-selection callbacks.
//

import SwiftUI
import MetalKit
import simd

struct SkyMetalView: NSViewRepresentable {
    var frameDataProvider: @MainActor () -> SkyFrameData
    var onDrag: @MainActor (CGFloat, CGFloat, CGSize) -> Void
    var onZoom: @MainActor (Double) -> Void
    var onSelect: @MainActor (CelestialObject?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = InteractiveMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1.0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30
        view.dragHandler = onDrag
        view.zoomHandler = onZoom

        if let device, let renderer = SkyRenderer(device: device) {
            renderer.frameDataProvider = frameDataProvider
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }

        let coordinator = context.coordinator
        view.clickHandler = { [weak coordinator] ndc in
            let object = coordinator?.renderer?.nearestObject(toNDC: ndc)
            onSelect(object)
        }
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        nsView.dragHandler = onDrag
        nsView.zoomHandler = onZoom
        let coordinator = context.coordinator
        nsView.clickHandler = { [weak coordinator] ndc in
            let object = coordinator?.renderer?.nearestObject(toNDC: ndc)
            onSelect(object)
        }
        context.coordinator.renderer?.frameDataProvider = frameDataProvider
    }

    @MainActor
    final class Coordinator {
        var renderer: SkyRenderer?
    }
}

/// MTKView subclass that converts macOS mouse events into camera gestures.
final class InteractiveMTKView: MTKView {

    var dragHandler: (@MainActor (CGFloat, CGFloat, CGSize) -> Void)?
    var zoomHandler: (@MainActor (Double) -> Void)?
    var clickHandler: (@MainActor (SIMD2<Double>) -> Void)?

    private var lastDragLocation: CGPoint?
    private var mouseDownLocation: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        lastDragLocation = location
        mouseDownLocation = location
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let last = lastDragLocation else {
            lastDragLocation = location
            return
        }
        let dx = location.x - last.x
        // Flip Y: AppKit's Y grows upward, screen-space drag feel expects downward-positive.
        let dy = -(location.y - last.y)
        lastDragLocation = location
        let size = bounds.size
        let handler = dragHandler
        Task { @MainActor in
            handler?(dx, dy, size)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            lastDragLocation = nil
            mouseDownLocation = nil
        }
        guard let down = mouseDownLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        let movement = hypot(location.x - down.x, location.y - down.y)
        // Treat as a click (selection) only if the mouse barely moved.
        guard movement < 4 else { return }

        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let ndcX = Double((location.x / size.width) * 2 - 1)
        let ndcY = Double((location.y / size.height) * 2 - 1)
        let handler = clickHandler
        Task { @MainActor in
            handler?(SIMD2(ndcX, ndcY))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        let handler = zoomHandler
        Task { @MainActor in
            handler?(Double(-delta))
        }
    }
}
