//
//  LabelLayoutEngine.swift
//  Astronomy
//
//  Turns the per-frame set of *candidate* sky labels into a small, bounded,
//  non-overlapping set of placed labels that SwiftUI renders as `Text`
//  overlays.
//
//  Design constraints:
//   * The dense star field stays entirely in Metal. Labels are the only
//     SwiftUI content driven by the sky, so the output must stay in the tens,
//     never the thousands.
//   * Placement is a single greedy pass ordered by priority: a candidate is
//     kept only if its approximate screen bounding box does not overlap a
//     already-kept, higher-priority label.
//   * The engine is stateful across frames purely to add hysteresis. A label
//     that was placed last frame is tested against a slightly *shrunken* box
//     and gets a small priority bonus, so labels near a collision boundary
//     don't strobe on and off while panning.
//

import CoreGraphics
import Foundation

/// Ranking used to resolve label collisions. Higher wins.
enum LabelPriority: Int, Comparable {
    /// Compass points on the horizon. Lowest priority of all: they are
    /// orientation furniture, and if a real celestial object wants the same
    /// pixels it should win. They also sit in a band of the screen nothing
    /// else usually occupies, so they rarely lose.
    case cardinal = -1
    case constellation = 0
    /// Galaxies, nebulae and clusters. Deliberately just above constellation
    /// names and below named stars: a deep-sky label is worth more than the
    /// constellation it sits in, and less than the star it might collide with.
    case deepSky = 1
    case brightStar = 2
    /// Satellites. Above named stars because a satellite's label is the only
    /// way to tell one moving dot from another, and below planets because a
    /// transient piece of hardware should never push Jupiter's name off the
    /// screen.
    case satellite = 3
    case planet = 4
    case luminary = 5       // Sun / Moon
    case selected = 6

    static func < (lhs: LabelPriority, rhs: LabelPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum LabelStyle {
    case constellation
    case star
    case solarSystem
    case deepSky
    case satellite
    /// Cardinal/intercardinal compass points ("N", "NE", ...).
    case cardinal
}

/// A label the renderer would *like* to draw this frame, in viewport NDC.
struct SkyLabelCandidate {
    /// Stable identity across frames (object id / constellation name).
    let id: String
    let text: String
    /// Position in viewport normalized device coordinates (-1...1, +Y up).
    let ndc: CGPoint
    let priority: LabelPriority
    let style: LabelStyle
    /// Visibility weight in 0...1 from the FOV fade curves; the engine
    /// multiplies it into the final opacity and drops near-invisible entries.
    let strength: Double
    /// How far *below* the object's screen position the label should sit, in
    /// points. Solar-system bodies grow their own offset with their rendered
    /// disk so a zoomed-in Jupiter never sits on top of its own name; stars
    /// and constellations keep the fixed values they always had.
    var verticalOffsetPoints: Double = 14
}

/// A label that survived layout, positioned in view (point) coordinates with
/// the origin at the top-left, ready for SwiftUI `.position(...)`.
struct SkyLabel: Identifiable, Equatable {
    let id: String
    let text: String
    let position: CGPoint
    let priority: LabelPriority
    let style: LabelStyle
    let opacity: Double

    static func == (lhs: SkyLabel, rhs: SkyLabel) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && abs(lhs.position.x - rhs.position.x) < 0.5
            && abs(lhs.position.y - rhs.position.y) < 0.5
            && abs(lhs.opacity - rhs.opacity) < 0.01
    }
}

@MainActor
final class LabelLayoutEngine {

    /// Hard ceiling on SwiftUI label views, regardless of how much sky is on
    /// screen. Keeps the overlay cheap to diff.
    static let maximumLabels = 44

    /// Below this the label isn't worth a view.
    private static let minimumOpacity = 0.06

    /// Approximate per-character advance and line height, in points, for the
    /// caption-sized fonts the overlay uses. Cheap stand-in for real text
    /// measurement — labels are short, so a linear estimate is close enough
    /// for collision purposes and costs nothing per frame.
    private static let characterWidth: CGFloat = 7.0
    private static let lineHeight: CGFloat = 15.0
    private static let horizontalPadding: CGFloat = 8.0

    private var previouslyPlaced: Set<String> = []

    func layout(candidates: [SkyLabelCandidate], viewportSize: CGSize) -> [SkyLabel] {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            previouslyPlaced = []
            return []
        }

        // Real elapsed time between layouts, so the fade rate is independent of
        // frame rate. Clamped: the first frame has no predecessor, and a
        // backgrounded app would otherwise resume with one enormous step.
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastLayoutTime > 0 ? min(0.1, now - lastLayoutTime) : 0
        lastLayoutTime = now

        let usable = candidates.filter { candidate in
            candidate.strength > Self.minimumOpacity
                && abs(candidate.ndc.x) <= 1.05
                && abs(candidate.ndc.y) <= 1.05
        }

        // Sort by priority, then by the hysteresis bonus, then by strength.
        let ordered = usable.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            let aSticky = previouslyPlaced.contains(a.id)
            let bSticky = previouslyPlaced.contains(b.id)
            if aSticky != bSticky { return aSticky }
            return a.strength > b.strength
        }

        var placed: [SkyLabel] = []
        var occupied: [CGRect] = []
        var placedIDs: Set<String> = []

        for candidate in ordered {
            guard placed.count < Self.maximumLabels else { break }
            var point = Self.viewPoint(ndc: candidate.ndc, viewportSize: viewportSize)
            point.y += candidate.verticalOffsetPoints
            var box = Self.boundingBox(text: candidate.text, at: point)

            // Hysteresis: a label already on screen defends its spot with a
            // slightly smaller footprint, so it takes a clear overlap (not a
            // one-pixel graze) to evict it.
            if previouslyPlaced.contains(candidate.id) {
                box = box.insetBy(dx: box.width * 0.12, dy: box.height * 0.12)
            }

            if occupied.contains(where: { $0.intersects(box) }) { continue }

            occupied.append(box)
            placedIDs.insert(candidate.id)
            placed.append(
                SkyLabel(
                    id: candidate.id,
                    text: candidate.text,
                    position: point,
                    priority: candidate.priority,
                    style: candidate.style,
                    opacity: smoothedOpacity(
                        id: candidate.id,
                        target: min(1.0, candidate.strength),
                        elapsed: elapsed
                    )
                )
            )
        }

        // Labels that were on screen and no longer place at all fade out from
        // wherever they had got to, rather than vanishing.
        for (id, value) in displayedOpacity where !placedIDs.contains(id) {
            let faded = Self.approach(value, target: 0, elapsed: elapsed)
            if faded <= Self.minimumOpacity {
                displayedOpacity[id] = nil
            } else {
                displayedOpacity[id] = faded
            }
        }

        previouslyPlaced = placedIDs
        return placed
    }

    // MARK: - Fading

    /// Per-label opacity as actually drawn, ramped toward the target.
    ///
    /// The fade lives here, in the data, rather than in a SwiftUI
    /// `.animation(_:value:)` on the overlay — and that placement is the whole
    /// point. A label's target opacity now varies continuously as it moves
    /// (terrain dimming depends on where it is), so an implicit animation keyed
    /// on opacity was permanently in flight, and an in-flight animation drags
    /// the label's *position* along with it. The result was labels trailing the
    /// sky by roughly the animation's duration while panning.
    ///
    /// Ramping the number here instead means the view is purely a function of
    /// its inputs: SwiftUI animates nothing, position is always exactly where
    /// this frame says it is, and fades stay smooth because the value itself
    /// moves smoothly.
    private var displayedOpacity: [String: Double] = [:]
    private var lastLayoutTime: CFTimeInterval = 0

    /// Seconds for a label to travel the full 0...1 opacity range.
    private static let fadeDurationSeconds: Double = 0.28

    private func smoothedOpacity(id: String, target: Double, elapsed: Double) -> Double {
        let current = displayedOpacity[id] ?? 0
        let next = Self.approach(current, target: target, elapsed: elapsed)
        displayedOpacity[id] = next
        return next
    }

    /// Moves `value` toward `target` at a constant rate. Linear rather than
    /// eased: an ease needs a notion of when the transition *started*, and
    /// these transitions are continually retargeted as the sky moves.
    private static func approach(_ value: Double, target: Double, elapsed: Double) -> Double {
        guard elapsed > 0 else { return value }
        let step = elapsed / fadeDurationSeconds
        if target > value { return min(target, value + step) }
        return max(target, value - step)
    }

    func reset() {
        previouslyPlaced = []
        displayedOpacity = [:]
        lastLayoutTime = 0
    }

    /// Converts viewport NDC (+Y up) to SwiftUI view points (+Y down).
    static func viewPoint(ndc: CGPoint, viewportSize: CGSize) -> CGPoint {
        CGPoint(
            x: (ndc.x + 1) * 0.5 * viewportSize.width,
            y: (1 - ndc.y) * 0.5 * viewportSize.height
        )
    }

    /// Approximate screen bounding box for a label centred just below `point`.
    static func boundingBox(text: String, at point: CGPoint) -> CGRect {
        let width = CGFloat(text.count) * characterWidth + horizontalPadding * 2
        return CGRect(
            x: point.x - width / 2,
            y: point.y - lineHeight / 2,
            width: width,
            height: lineHeight
        )
    }
}
