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
    case constellation = 0
    case brightStar = 1
    case planet = 2
    case luminary = 3       // Sun / Moon
    case selected = 4

    static func < (lhs: LabelPriority, rhs: LabelPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum LabelStyle {
    case constellation
    case star
    case solarSystem
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
            let point = Self.viewPoint(ndc: candidate.ndc, viewportSize: viewportSize)
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
                    opacity: min(1.0, candidate.strength)
                )
            )
        }

        previouslyPlaced = placedIDs
        return placed
    }

    func reset() {
        previouslyPlaced = []
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
