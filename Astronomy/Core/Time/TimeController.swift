//
//  TimeController.swift
//  Astronomy
//
//  Drives the "current time" used everywhere in the app. Defaults to live
//  system time, ticking once per second on the main actor via Swift
//  Concurrency (no Combine timers). Future phases (time scrubbing / playback
//  speed) will extend this type without changing its public surface much.
//

import Foundation
import Observation

@Observable
@MainActor
final class TimeController {

    /// The time currently used for all astronomy calculations.
    private(set) var currentDate: Date = Date()

    /// Julian Day for `currentDate`, recomputed whenever it changes.
    var julianDay: Double {
        JulianDate.julianDay(from: currentDate)
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
        currentDate = Date()
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.currentDate = Date()
            }
        }
    }
}
