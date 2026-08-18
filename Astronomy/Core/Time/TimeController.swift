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
//  seam the Time Machine builds on: scrubbing sets the offset, and a playback
//  rate multiplies how fast the offset itself grows.
//
//  THE RATE MODEL
//
//  Simulated time advances at `effectiveRate` simulated seconds per real
//  second. The offset is therefore not a stored number that something has to
//  keep nudging — a timer-driven offset would step, and stepping is the exact
//  defect the continuous clock above exists to avoid. Instead the offset is
//  *computed*:
//
//      offset(now) = baseOffset + (rate - 1) * (now - anchor)
//
//  so simulated time is `now + offset(now)` = `anchor + baseOffset + rate *
//  (now - anchor)`, i.e. exactly linear in real time at slope `rate`. Nothing
//  ticks, nothing accumulates error, and the renderer sampling it at 120 Hz
//  sees perfectly smooth motion at any speed. Every operation that changes the
//  rate or the offset re-anchors first, which keeps simulated time continuous
//  across the change.
//
//  Pausing is rate 0: simulated time freezes while the real clock runs on.
//

import Foundation
import Observation

@Observable
@MainActor
final class TimeController {

    /// Playback speeds offered by the time bar, as simulated seconds per real
    /// second. Chosen so each step is a recognisable unit rather than a round
    /// number: watching a satellite pass, a night, a day, and a year.
    enum PlaybackRate: Double, CaseIterable, Identifiable {
        case realTime = 1
        case fast = 60                  // a minute a second
        case hourPerSecond = 3600
        case dayPerSecond = 86_400

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .realTime: return "1×"
            case .fast: return "60×"
            case .hourPerSecond: return "1 h/s"
            case .dayPerSecond: return "1 d/s"
            }
        }

        var longLabel: String {
            switch self {
            case .realTime: return "Real time"
            case .fast: return "60× real time"
            case .hourPerSecond: return "1 hour per second"
            case .dayPerSecond: return "1 day per second"
            }
        }
    }

    // MARK: - Rate state

    /// Offset at the moment of the last re-anchor.
    private var baseOffset: TimeInterval = 0
    /// Real-clock instant of the last re-anchor.
    private var anchorRealDate: Date = Date()

    /// Selected playback speed. Applies only while playing.
    private(set) var playbackRate: PlaybackRate = .realTime
    /// False freezes simulated time (effective rate 0).
    private(set) var isPlaying: Bool = true

    /// Simulated seconds per real second, right now.
    var effectiveRate: Double { isPlaying ? playbackRate.rawValue : 0 }

    /// How far simulated time runs ahead of (or behind) the real clock.
    /// Zero means "now". Computed, never stored — see the rate model above.
    var offsetFromRealTime: TimeInterval {
        baseOffset + (effectiveRate - 1.0) * Date().timeIntervalSince(anchorRealDate)
    }

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

    /// True when simulated time is tracking the real clock: at the real
    /// instant, playing, and at 1×. Anything else means the user is looking at
    /// a sky that is not the sky outside, and the UI says so.
    var isFollowingRealTime: Bool {
        abs(offsetFromRealTime) < 0.5 && isPlaying && playbackRate == .realTime
    }

    /// The calendar used for month/year stepping and for the picker. The user's
    /// own, so "one month from now" means what the calendar on the wall means
    /// and daylight-saving transitions land correctly.
    var calendar: Calendar { Calendar.current }

    private nonisolated(unsafe) var tickTask: Task<Void, Never>?

    init() {
        startTicking()
    }

    deinit {
        tickTask?.cancel()
    }

    // MARK: - Mutation

    /// Freezes the current simulated instant as the new base, so the linear
    /// ramp restarts from here. Every mutating operation calls this first;
    /// without it, changing the rate would retroactively rewrite the past and
    /// simulated time would jump.
    private func reanchor() {
        baseOffset = offsetFromRealTime
        anchorRealDate = Date()
    }

    /// Resets to the live system clock (the "Now" button). Also restores
    /// ordinary 1× playback: "Now" means *now*, not "now, but running at a day
    /// a second", which would immediately stop being now.
    func resetToNow() {
        baseOffset = 0
        anchorRealDate = Date()
        playbackRate = .realTime
        isPlaying = true
        currentDate = date
    }

    /// Shifts simulated time by an interval, keeping it flowing from there.
    func shift(by interval: TimeInterval) {
        reanchor()
        baseOffset += interval
        currentDate = date
    }

    /// Jumps to a specific instant; time continues to flow from it.
    func jump(to target: Date) {
        reanchor()
        baseOffset = target.timeIntervalSinceNow
        currentDate = date
    }

    /// Steps by a calendar component — the hour/day/month/year buttons.
    ///
    /// Calendar arithmetic rather than a fixed number of seconds, because a
    /// month is not 30 days and a year is not 365. "One month from now" has to
    /// land on the same clock time on the same day of the next month, which is
    /// exactly what `Calendar` guarantees and what fixed-interval arithmetic
    /// cannot.
    func step(_ component: Calendar.Component, by value: Int) {
        guard let target = calendar.date(byAdding: component, value: value, to: date) else { return }
        jump(to: target)
    }

    /// Sets the playback speed, re-anchoring so the change is continuous.
    func setPlaybackRate(_ rate: PlaybackRate) {
        reanchor()
        playbackRate = rate
        currentDate = date
    }

    /// Play/pause. Pausing freezes simulated time exactly where it is.
    func setPlaying(_ playing: Bool) {
        reanchor()
        isPlaying = playing
        currentDate = date
    }

    func togglePlaying() {
        setPlaying(!isPlaying)
    }

    /// Republishes the display value once a second. This drives the clock in
    /// the time bar only; nothing in the render path waits on it.
    ///
    /// The tick interval stays one second regardless of playback rate. At 1 d/s
    /// the displayed date changes by a day each tick, which is exactly the
    /// intended reading; interpolating it faster would just churn the view.
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
