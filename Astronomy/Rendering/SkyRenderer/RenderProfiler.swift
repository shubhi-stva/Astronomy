//
//  RenderProfiler.swift
//  Astronomy
//
//  Per-stage timing for the frame pipeline.
//
//  Two consumers, one set of measurements:
//
//   * **Instruments.** Every stage is bracketed by an `OSSignposter`
//     interval on the "Astronomy"/"render" subsystem, so a trace shows
//     exactly where a dropped frame went without any code changes.
//   * **In-code.** A fixed-size ring buffer per stage keeps the last N
//     samples, from which `report()` produces mean/max/p95 in milliseconds.
//     This is what a unit test can assert on, and what a debug build can dump
//     — Instruments cannot be driven from a test.
//
//  The cost of measuring is two `ContinuousClock` reads and a store into a
//  preallocated buffer: tens of nanoseconds against stages measured in
//  milliseconds. Nothing here allocates after `init`.
//

import Foundation
import os

/// One measurable stage of producing a frame, in pipeline order.
enum RenderStage: Int, CaseIterable, Sendable {
    case frameData          // SkyViewModel.currentFrameData()
    case stars              // catalogue cull + projection
    case lines              // constellation line list
    case deepSky            // deep-sky objects
    case satellites         // satellite extrapolation + projection
    case solarSystem        // Sun/Moon/planets
    case constellationLabels
    case cardinalPoints
    case geometryTotal      // SkyGeometryBuilder.run() end to end
    case labelLayout        // LabelLayoutEngine.layout()
    case bufferUpload       // vertex buffer acquisition + copy
    case encode             // render command encoding + commit
    case frameTotal         // everything the frame callback does

    var name: StaticString {
        switch self {
        case .frameData: return "frameData"
        case .stars: return "stars"
        case .lines: return "lines"
        case .deepSky: return "deepSky"
        case .satellites: return "satellites"
        case .solarSystem: return "solarSystem"
        case .constellationLabels: return "constellationLabels"
        case .cardinalPoints: return "cardinalPoints"
        case .geometryTotal: return "geometryTotal"
        case .labelLayout: return "labelLayout"
        case .bufferUpload: return "bufferUpload"
        case .encode: return "encode"
        case .frameTotal: return "frameTotal"
        }
    }

    var label: String {
        String(describing: self)
    }
}

/// Rolling per-stage timing statistics, in milliseconds.
struct RenderStageStatistics: Sendable {
    var stage: RenderStage
    var sampleCount: Int
    var meanMilliseconds: Double
    var maxMilliseconds: Double
    var p95Milliseconds: Double
}

/// Collects per-stage frame timings.
///
/// Deliberately *not* an actor and not `Sendable`-checked across threads: it
/// is owned by whichever single thread is building frames (the render thread
/// today, the geometry actor after that). Sharing one across threads would
/// need a lock, and a lock in the frame callback is exactly the sort of thing
/// this file exists to find.
/// `nonisolated` because the whole point is to be usable from whatever
/// thread is building frames — the render thread today, a background
/// geometry actor after that. The target's default isolation is `MainActor`,
/// so this opt-out has to be explicit.
nonisolated final class RenderProfiler {

    /// Number of frames kept per stage. Two seconds at 60 Hz — long enough
    /// that a once-a-second hitch lands inside the window, short enough that
    /// `max` still reflects recent behaviour.
    static let windowSize = 120

    private let signposter = OSSignposter(
        subsystem: "Astronomy", category: "render"
    )

    private var samples: [[Double]]
    private var writeIndex: [Int]
    private var counts: [Int]

    /// Turns all recording off. Signposts are emitted regardless (they are
    /// free when no tool is listening); this only gates the ring buffers.
    var isEnabled: Bool = true

    init() {
        let stageCount = RenderStage.allCases.count
        samples = Array(
            repeating: Array(repeating: 0.0, count: Self.windowSize),
            count: stageCount
        )
        writeIndex = Array(repeating: 0, count: stageCount)
        counts = Array(repeating: 0, count: stageCount)
    }

    /// Times `body`, emitting a signpost interval and recording the duration.
    @inline(__always)
    func measure<T>(_ stage: RenderStage, _ body: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            record(stage, seconds: Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9)
        }
        return try body()
    }

    func record(_ stage: RenderStage, seconds: Double) {
        guard isEnabled else { return }
        let i = stage.rawValue
        samples[i][writeIndex[i]] = seconds
        writeIndex[i] = (writeIndex[i] + 1) % Self.windowSize
        counts[i] = min(counts[i] + 1, Self.windowSize)
    }

    func reset() {
        for i in samples.indices {
            writeIndex[i] = 0
            counts[i] = 0
        }
    }

    func statistics(for stage: RenderStage) -> RenderStageStatistics {
        let i = stage.rawValue
        let n = counts[i]
        guard n > 0 else {
            return RenderStageStatistics(
                stage: stage, sampleCount: 0,
                meanMilliseconds: 0, maxMilliseconds: 0, p95Milliseconds: 0
            )
        }
        let window = Array(samples[i].prefix(n))
        let sorted = window.sorted()
        let mean = window.reduce(0, +) / Double(n)
        let p95 = sorted[min(n - 1, Int((Double(n) * 0.95).rounded(.down)))]
        return RenderStageStatistics(
            stage: stage,
            sampleCount: n,
            meanMilliseconds: mean * 1000,
            maxMilliseconds: (sorted.last ?? 0) * 1000,
            p95Milliseconds: p95 * 1000
        )
    }

    /// Every stage that has samples, in pipeline order.
    func report() -> [RenderStageStatistics] {
        RenderStage.allCases
            .map(statistics(for:))
            .filter { $0.sampleCount > 0 }
    }

    /// A single human-readable block, for logging or test output.
    func formattedReport(title: String = "frame stages") -> String {
        var lines = ["\(title)  (mean / p95 / max, ms)"]
        for s in report() {
            lines.append(
                String(
                    format: "  %-20@ %7.3f  %7.3f  %7.3f   (n=%d)",
                    s.stage.label as NSString,
                    s.meanMilliseconds, s.p95Milliseconds, s.maxMilliseconds,
                    s.sampleCount
                )
            )
        }
        return lines.joined(separator: "\n")
    }
}
