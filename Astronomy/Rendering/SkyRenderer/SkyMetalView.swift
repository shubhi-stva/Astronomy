//
//  SkyMetalView.swift
//  Astronomy
//
//  NSViewRepresentable wrapping an MTKView, plus an interactive subclass that
//  turns macOS input into camera gestures:
//
//   * Trackpad two-finger swipe (primary navigation) — arrives purely through
//     `scrollWheel` with `hasPreciseScrollingDeltas`, no mouse button needed.
//     Release velocity feeds a short momentum glide.
//   * Pinch-magnify (`NSMagnificationGestureRecognizer`) — smooth zoom.
//   * Mouse click-drag (secondary navigation) and mouse-wheel zoom.
//   * Single click selects; double click flies the camera to the object.
//

import SwiftUI
import MetalKit
import simd

struct SkyMetalView: NSViewRepresentable {
    var frameDataProvider: @MainActor () -> SkyFrameData
    var onDrag: @MainActor (CGFloat, CGFloat, CGSize) -> Void
    var onPanEnded: @MainActor (CGFloat, CGFloat, CGSize) -> Void
    var onZoom: @MainActor (Double) -> Void
    var onZoomFactor: @MainActor (Double) -> Void
    var onSelect: @MainActor (CelestialObject?) -> Void
    var onFocus: @MainActor (CelestialObject?) -> Void
    var onLabels: @MainActor ([SkyLabel]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveMTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = InteractiveMTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.008, green: 0.012, blue: 0.03, alpha: 1.0)
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        // Provisional only. The real value is the display's own refresh rate,
        // and the view sets it itself in `viewDidMoveToWindow` — it cannot be
        // known here, because there is no window yet.
        view.preferredFramesPerSecond = 60

        if let device, let renderer = SkyRenderer(device: device) {
            renderer.frameDataProvider = frameDataProvider
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }

        view.installGestureRecognizers()
        configure(view, context: context)
        return view
    }

    func updateNSView(_ nsView: InteractiveMTKView, context: Context) {
        configure(nsView, context: context)
    }

    private func configure(_ view: InteractiveMTKView, context: Context) {
        view.dragHandler = onDrag
        view.panEndedHandler = onPanEnded
        view.zoomHandler = onZoom
        view.zoomFactorHandler = onZoomFactor

        let coordinator = context.coordinator
        coordinator.renderer?.frameDataProvider = frameDataProvider
        coordinator.renderer?.labelSink = onLabels

        view.clickHandler = { [weak coordinator] ndc, clickCount in
            let object = coordinator?.renderer?.nearestObject(toViewportNDC: ndc)
            if clickCount >= 2 {
                onFocus(object)
            } else {
                onSelect(object)
            }
        }
    }

    @MainActor
    final class Coordinator {
        var renderer: SkyRenderer?
    }
}

/// MTKView subclass that converts macOS mouse/trackpad events into camera
/// gestures.
final class InteractiveMTKView: MTKView {

    var dragHandler: (@MainActor (CGFloat, CGFloat, CGSize) -> Void)?
    /// Called on gesture release with a velocity in points/second.
    var panEndedHandler: (@MainActor (CGFloat, CGFloat, CGSize) -> Void)?
    var zoomHandler: (@MainActor (Double) -> Void)?
    var zoomFactorHandler: (@MainActor (Double) -> Void)?
    var clickHandler: (@MainActor (SIMD2<Double>, Int) -> Void)?

    private var lastDragLocation: CGPoint?
    private var mouseDownLocation: CGPoint?

    /// Rolling estimate of trackpad swipe speed, in points/second, used to seed
    /// the momentum glide when the fingers lift.
    private var scrollVelocity: CGVector = .zero
    private var lastScrollTime: CFTimeInterval?

    private var magnificationBase: Double = 1.0

    /// Single place to flip trackpad pan direction if it ever reads inverted on
    /// a given system configuration. +1 means "content follows the fingers".
    static let trackpadPanSignX: CGFloat = 1
    static let trackpadPanSignY: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Refresh rate

    /// Drives the view at whatever the display it is actually on can do, so a
    /// 120 Hz panel gets 120 fps and panning reads as continuous rather than
    /// stepped.
    ///
    /// Set here rather than from `updateNSView` because the refresh rate is a
    /// property of the *window's screen*, which does not exist when the view is
    /// created and is not something SwiftUI re-evaluates on any schedule. It
    /// used to be set in `updateNSView`, which happened to work only because
    /// that ran constantly — the label overlay was invalidating the whole view
    /// tree every frame. Once that was fixed, `updateNSView` stopped running
    /// often enough to reliably catch the window, and the view silently stayed
    /// at its provisional 60 fps.
    private func matchDisplayRefreshRate() {
        guard let maxFPS = window?.screen?.maximumFramesPerSecond, maxFPS > 0 else { return }
        preferredFramesPerSecond = maxFPS
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        matchDisplayRefreshRate()

        // Windows can be dragged between displays with different refresh rates.
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeScreenNotification, object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowChangedScreen),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
    }

    @objc private func windowChangedScreen() {
        matchDisplayRefreshRate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func installGestureRecognizers() {
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(magnify)
    }

    // MARK: - Pinch to zoom

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            magnificationBase = 1.0
        case .changed:
            // `magnification` is cumulative for the gesture; convert to the
            // incremental factor since the previous callback so the camera sees
            // a smooth multiplicative stream.
            let cumulative = 1.0 + Double(recognizer.magnification)
            guard cumulative > 0.01, magnificationBase > 0.01 else { return }
            let incremental = cumulative / magnificationBase
            magnificationBase = cumulative
            // Pinching *out* (positive magnification) should zoom in, i.e.
            // shrink the field of view.
            let fovFactor = 1.0 / incremental
            let handler = zoomFactorHandler
            Task { @MainActor in handler?(fovFactor) }
        case .ended, .cancelled, .failed:
            magnificationBase = 1.0
        default:
            break
        }
    }

    // MARK: - Mouse drag (secondary navigation)

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
        // Flip Y: AppKit's Y grows upward; the drag convention is
        // downward-positive.
        let dy = -(location.y - last.y)
        lastDragLocation = location
        emitDrag(dx: dx, dy: dy)
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
        let clicks = event.clickCount
        Task { @MainActor in
            handler?(SIMD2(ndcX, ndcY), clicks)
        }
    }

    // MARK: - Trackpad swipe / mouse wheel

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            handleTrackpadPan(event)
        } else {
            // Classic mouse wheel: zoom.
            let delta = event.scrollingDeltaY
            let handler = zoomHandler
            Task { @MainActor in handler?(Double(-delta)) }
        }
    }

    private func handleTrackpadPan(_ event: NSEvent) {
        let phase = event.phase
        let momentumPhase = event.momentumPhase

        if phase.contains(.began) {
            scrollVelocity = .zero
            lastScrollTime = nil
            // Cancel any residual glide from the previous swipe.
            let size = bounds.size
            let handler = panEndedHandler
            Task { @MainActor in handler?(0, 0, size) }
        }

        // macOS already synthesizes momentum scroll events for trackpads. We
        // ignore them and run our own (shorter, more damped) glide, so the sky
        // doesn't drift for seconds after a flick.
        guard momentumPhase == [] else {
            if momentumPhase.contains(.began) { emitMomentum() }
            return
        }

        // With macOS "natural scrolling", AppKit's precise scrolling deltas are
        // already expressed so that the *content* follows the fingers: a
        // positive scrollingDeltaY corresponds to content moving down the
        // screen, a positive scrollingDeltaX to content moving right. That is
        // exactly the drag convention `applyDrag` expects (rightward-positive
        // X, downward-positive Y), so the deltas pass straight through.
        //
        // If a user has natural scrolling disabled, AppKit reports
        // `isDirectionInvertedFromDevice`; we honour it so the gesture always
        // feels like dragging the sky itself rather than scrolling a document.
        let inversion: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let dx = event.scrollingDeltaX * inversion * Self.trackpadPanSignX
        let dy = event.scrollingDeltaY * inversion * Self.trackpadPanSignY

        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastScrollTime {
            let dt = max(1.0 / 240.0, min(0.05, now - last))
            let instantaneous = CGVector(dx: dx / dt, dy: dy / dt)
            // Light exponential smoothing so a single jittery event doesn't
            // dominate the release velocity.
            scrollVelocity = CGVector(
                dx: scrollVelocity.dx * 0.6 + instantaneous.dx * 0.4,
                dy: scrollVelocity.dy * 0.6 + instantaneous.dy * 0.4
            )
        }
        lastScrollTime = now

        emitDrag(dx: dx, dy: dy)

        if phase.contains(.ended) || phase.contains(.cancelled) {
            if phase.contains(.cancelled) {
                scrollVelocity = .zero
            }
            emitMomentum()
        }
    }

    private func emitMomentum() {
        let size = bounds.size
        let velocity = scrollVelocity
        scrollVelocity = .zero
        lastScrollTime = nil
        let handler = panEndedHandler
        Task { @MainActor in handler?(velocity.dx, velocity.dy, size) }
    }

    private func emitDrag(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        let size = bounds.size
        let handler = dragHandler
        Task { @MainActor in handler?(dx, dy, size) }
    }
}
