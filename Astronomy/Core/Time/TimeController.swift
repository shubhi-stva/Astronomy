//
//  TimeController.swift
//  Astronomy
//
//  Drives the "current time" used everywhere in the app.
//
//  Two clocks, deliberately:
//
//   * `currentDate` is observable and republished once a second. It exists for
//     the UI — the time bar shows whole seconds, and invalidating a SwiftUI
//     view 120 times a second to redraw an unchanged string is waste.
//   * `julianDay` is *continuous*, computed from the system clock at the
//     instant it is read, and is what the renderer uses.
//
//  Keeping them separate matters more than it looks. Everything in the sky
//  except satellites moves slowly enough (a star drifts ~0.004 deg/s) that a
//  one-second quantisation of time is invisible. A satellite in low orbit
//  crosses the sky at roughly a degree per second, so driving the render clock
//  from the one-second tick made satellites jump a degree and then sit still —
//  the per-frame `r + v*dt` extrapolation was working perfectly, but `dt`
//  itself only advanced once a second.
//
//  Time is modelled as an offset from the real clock rather than an absolute
//  stored date, so simulated time keeps *flowing* on its own. That is also the
//  seam the future Time Machine needs: scrubbing sets the offset, and a
//  playback rate multiplies it.
//

import Foundation
import Observation

@Observable
@MainActor
final class TimeController {

    /// How far simulated time runs ahead of (or behind) the real clock.
    /// Zero means "now".
    private(set) var offsetFromRealTime: TimeInterval = 0

    /// Observable wall-clock value for the UI, refreshed once a second.
    /// Renderers must use `date`/`julianDay` instead — this one is a staircase.
    private(set) var currentDate: Date = Date()

    /// The simulated instant *right now*, to full precision.
    ///
    /// Deliberately computed rather than stored: it advances continuously
    /// between ticks, so anything sampling it per frame sees smooth motion.
    var date: Date {
        Date(timeIntervalSinceNow: offsetFromRealTime)
    }

    /// Julian Day for the continuous simulated instant.
    var julianDay: Double {
        JulianDate.julianDay(from: date)
    }

    /// Julian Day for the once-a-second display value.
    var displayJulianDay: Double {
        JulianDate.julianDay(from: currentDate)
    }

    /// True when simulated time is tracking the real clock.
    var isFollowingRealTime: Bool {
        abs(offsetFromRealTime) < 0.5
    }

    private nonisolated(unsafe) var tickTask: Task<Void, Never>?

    init() {
        startTicking()
    }

    deinit {
        tickTask?.cancel()
    }

    /// Resets to the live system clock (the "Now" button).
    func resetToNow() {
        offsetFromRealTime = 0
        currentDate = date
    }

    /// Shifts simulated time by an interval, keeping it flowing from there.
    func shift(by interval: TimeInterval) {
        offsetFromRealTime += interval
        currentDate = date
    }

    /// Jumps to a specific instant; time continues to flow from it.
    func jump(to target: Date) {
        offsetFromRealTime = target.timeIntervalSinceNow
        currentDate = date
    }

    /// Republishes the display value once a second. This drives the clock in
    /// the time bar only; nothing in the render path waits on it.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.currentDate = self.date
            }
        }
    }
}
