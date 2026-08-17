# Roadmap

## Phase 0 — Architecture & Docs (done)
- Module layout established (`Core/`, `Rendering/`, `Features/`, `Data/`, `Services/`, `DesignSystem/`).
- `ARCHITECTURE.md`, `ROADMAP.md`, `DATA_SOURCES.md` written.

## Phase 1 — Sky View MVP (done)
- Fullscreen immersive Metal-rendered sky view, no template boilerplate.
- `TimeController`: live system time, Julian Date conversion.
- `CoordinateTransformService`: RA/Dec <-> Alt/Az, stereographic screen projection.
- `EphemerisService`: real low-precision Sun, Moon, and Mercury-Neptune positions.
- Bundled star catalog (~5,000 stars, HYG database subset) + IAU-88
  constellation lines, loaded asynchronously via `CatalogService`.
- Instanced Metal point-sprite rendering for stars/Sun/Moon/planets; line
  rendering for constellations.
- `Camera`: click-drag pan, scroll-wheel zoom.
- Click-to-select with a minimal floating info panel (name, magnitude, RA/Dec).
- Minimal search (substring match) recentering the camera.
- Bottom time bar with live clock + "Now" reset button.
- Manual lat/lon location entry, defaulting to New York; optional CoreLocation.
- SwiftData model stubs (`SavedLocation`, `UserPreference`) wired into the app.
- Unit tests for Julian Date, RA/Dec -> Alt/Az, and Sun position.

## Phase 2 — Observation Planner (future)
Plan observing sessions: rise/set/transit times, "best time to view" for a
target given the current location and date, a simple night-of checklist.

## Phase 3 — Orbit Lab (future)
Interactive 3D visualization of the solar system's orbital mechanics —
distinct from the sky-dome view — letting users see why objects appear
where they do (retrograde motion, elongation, etc.), likely a second Metal
scene with a heliocentric camera.

## Phase 4 — Journal & Compare Skies (future)
A personal observation journal (notes, sketches, conditions) backed by
SwiftData, plus a "Compare Skies" mode to diff the sky as seen from two
different times/locations side by side.

## Phase 5 — Astrophotography Tools (future)
Framing/field-of-view overlays for common telescope + camera/eyepiece
combinations, exposure planning aids, moon-phase-aware "best night" scoring.

## Phase 6 — Satellites, Weather, Command Palette, Night Mode, Favorites (future)
- Satellite pass predictions (ISS, Starlink, etc.) via bundled/updatable TLE data.
- Local weather/cloud-cover overlay to help decide when to observe.
- A command palette (⌘K-style) for fast navigation across all features.
- A true red-shifted "night mode" theme to preserve dark adaptation.
- Favoriting objects/locations for quick access across sessions.

Phases 2-6 are intentionally out of scope for this milestone and are noted
here only to show where the architecture is headed; none of their code
exists yet.
