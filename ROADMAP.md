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

## Phase 2 — Observation Planner (done)
Rise/set/transit for every object, a "Tonight" dashboard rating targets by a
limiting-factor visibility model, a sky calendar of upcoming events, and
satellite pass prediction. See `TonightReport`, `EventCalendar`,
`SatellitePasses`.

## Phase 2b — Apparent places (done)
The ephemeris rebuilt on VSOP87D and the full lunar series, with ΔT, nutation,
annual aberration, light-time, topocentric parallax and atmospheric refraction.
Everything the app draws is now an *apparent* place, agreeing with JPL Horizons
to under an arcsecond for the Sun and planets and under four for the Moon; the
residuals are pinned in `AstronomyTests/AccuracyTests.swift`.

## Phase 2c — Sky guide features (done)
Constellation boundaries (IAU/Delporte, B1875), equatorial and horizon grids,
the ecliptic and the meridian, the Galilean moons, meteor-shower radiants,
eyepiece field circles, an angular-measurement tool, Bortle light-pollution
setting, and a per-object facts panel (altitude/azimuth, containing
constellation, rise/transit/set, distance, apparent size, phase, elongation).

## Phase 3 — Observation Planner (superseded)
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

## Phase 6 — Satellites, Weather, Command Palette, Night Mode, Favorites
- Satellite pass predictions (ISS, Starlink, etc.) via bundled/updatable TLE
  data. **Done** — see `SatellitePasses` and the Passes panel.
- A command palette (⌘K-style) for fast navigation across all features.
  **Done** — see `Features/Palette`.
- A true red-shifted "night mode" theme to preserve dark adaptation.
  **Done** — see `DesignSystem/NightVision.swift`.
- Local weather/cloud-cover overlay to help decide when to observe. *Future.*
- Favoriting objects/locations for quick access across sessions. *Future.*

Phases 2-6 are intentionally out of scope for this milestone and are noted
here only to show where the architecture is headed; none of their code
exists yet.
