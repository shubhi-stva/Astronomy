# Architecture

AstronomyDesktop (Xcode target: `Astronomy`) is a native macOS app built with
SwiftUI for presentation, Metal/MetalKit for sky rendering, SIMD for
coordinate math, Swift Concurrency for background work, SwiftData for
persistence, and CoreLocation (with manual override) for observer location.

## Module structure

```
Astronomy/
  App/                  App entry point (AstronomyApp.swift), ModelContainer setup.
  Core/
    Time/               JulianDate, TimeController — no SwiftUI/Metal imports.
    Coordinates/         CoordinateTransformService, spherical coordinate types.
    Time/                JulianDate, TimeController, DeltaT (TT - UT).
    Astronomy/            SunPosition, MoonPosition, PlanetPosition, VSOP87,
                          Nutation, Refraction, PlanetMagnitude, JupiterMoons,
                          EphemerisService, RiseSetCalculator, VisibilityRating,
                          TonightReport, SkyPath, SatellitePasses, ObjectFacts.
    Models/              CelestialObject, Star, SavedLocation (SwiftData).
  Data/
    Catalogs/            Bundled stars.json / constellations.json + CatalogService.
  Rendering/
    Camera/              Camera (Alt/Az state, pan/zoom, momentum, focus flights).
    SkyRenderer/          MTKView delegate, geometry building, background uniforms, hit testing.
    Labels/               LabelLayoutEngine (collision/priority) + SkyLabelsOverlay (SwiftUI).
    Shaders/              Shaders.metal (background, line, point-sprite passes).
  Features/
    Sky/                  SwiftUI feature: SkyView + subviews + SkyViewModel.
  Services/               LocationService (CoreLocation + manual override).
  DesignSystem/           Colors, GlassPanel.
```

`Core/*` files intentionally avoid importing SwiftUI, MetalKit, or
Combine — they are plain Swift/Foundation/simd, which is what makes them
independently unit-testable (see `AstronomyTests/`) and reusable if the
rendering layer changes later.

## Why Metal for star rendering (not thousands of SwiftUI views)

The star catalog bundled with the app contains ~83,000 stars (complete to
magnitude 9), plus several hundred constellation-line segments and a
handful of solar-system markers, all of which must reposition every frame
as the camera pans/zooms and as time advances. Representing each star as a
SwiftUI view would mean thousands of view identities, layout passes, and
diffs per frame — SwiftUI's view diffing is not designed for that
cardinality at 30-60fps. Metal instead lets the app:

- Project all objects on the CPU once per frame (cheap: a few thousand
  trig-based transforms) into a single small vertex buffer.
- Issue **one** draw call for all point-sprites (stars + Sun/Moon/planets)
  using `MTLPrimitiveType.point`, and **one** draw call for all
  constellation lines using `MTLPrimitiveType.line`.
- Do all glow/color shading in a tiny fragment shader, off the CPU.

This keeps the render loop's CPU cost bounded and predictable regardless of
catalog size, and keeps SwiftUI doing what it's good at: the floating
chrome (search, info panel, time bar, location control) layered on top via
`ZStack`.

## Render passes (per frame, back to front)

1. **Background pass** — one full-screen triangle, no geometry. The fragment
   shader *inverts* the stereographic projection per pixel to recover the sky
   direction, then paints the horizon/atmosphere gradient and the procedural
   Milky Way band. Choosing per-pixel projection inversion over a cheaper
   screen-space "distance from a horizon line" gradient keeps the sky exactly
   consistent with the star projection at any camera orientation — including
   looking straight up, where a screen-space horizon line degenerates. All the
   per-frame work is two 3x3 rotation matrices built on the CPU
   (`SkyBackgroundUniforms.swift`): camera->horizontal (gives altitude, hence
   the twilight tinting driven by the Sun's altitude through the civil /
   nautical / astronomical bands) and camera->galactic (gives the Milky Way's
   `b`/`l`; see DATA_SOURCES.md for the approximation's provenance and limits).
2. **Line pass** — constellation lines as one line list, muted blue-grey with
   an FOV-dependent alpha.
3. **Point-sprite pass** — stars, their glow haloes, the Sun/Moon/planets and
   the selection ring, all in one `MTLPrimitiveType.point` draw call with a
   per-vertex `shape` selector (`PointSpriteShape`) that the fragment shader
   branches on: soft radial glow, crisp star core, solid disk, Moon with a
   terminator, or a ring.

`SkyGeometryBuilder` is the CPU half: it consumes one `SkyFrameData` snapshot
and emits the vertex buffers, the hit-test table, and the label candidates.
Two rejections run *before* any trigonometry, so the trig cost scales with
what is actually drawn rather than with catalog size:

- **Spatial** — `Data/Catalogs/StarIndex.swift` dices the sky into 5-degree
  equatorial cells, each with a precomputed bounding cone, built once off the
  main thread when the catalogue loads. The viewport is also a cone (its
  angular radius follows exactly from the stereographic projection), so a cell
  survives only if the angle between the two axes is within the sum of the two
  radii — one dot product per cell, 2,592 of them. Working in 3D unit vectors
  rather than RA/Dec intervals is what makes the RA = 0/360 wrap and the
  converging cells near the poles non-issues.
- **Magnitude** — each cell stores its stars magnitude-ascending, so a
  surviving cell's scan stops at the first star past the current limit.

The two cover each other: a wide field has a shallow limit, a narrow field has
a deep limit but almost no surviving cells. At a 3-degree field the builder
considers a few hundred stars out of 83,479.

## Label engine

Labels are the only SwiftUI content driven by the sky, so their count is
bounded (tens, never thousands). `SkyGeometryBuilder` emits *candidates* with
a priority (selected > Sun/Moon > planets > bright named stars > constellation
names) and an FOV-derived strength; `LabelLayoutEngine` does a single greedy
pass, keeping a candidate only if its approximate screen bounding box doesn't
overlap an already-placed higher-priority one, capped at 44 labels. The engine
is stateful across frames purely for hysteresis: a label placed last frame
defends its spot with a slightly shrunken box and a tie-break bonus, so labels
near a collision boundary don't strobe while panning. The layout is published
to SwiftUI through `SkyRenderer.labelSink` at ~30 Hz (half the render rate) and
only when it actually changed, and `SkyLabelsOverlay` animates opacity so
labels fade rather than pop.

## Navigation and momentum

`InteractiveMTKView` turns macOS input into camera gestures: trackpad
two-finger swipe (primary; arrives through `scrollWheel` with
`hasPreciseScrollingDeltas`, no button held, honouring
`isDirectionInvertedFromDevice` so the content always follows the fingers),
`NSMagnificationGestureRecognizer` for pinch-zoom, mouse click-drag as
secondary navigation, mouse wheel for zoom, single click to select and double
click to fly to an object.

Continuous behaviour lives in `Camera`, not in SwiftUI animations: release
velocity seeds an exponentially-damped momentum glide (~0.55 s to a stop) and
double-click starts a smootherstep-eased flight interpolating Alt/Az and field
of view over ~0.75 s. Both are integrated by `Camera.tick()`, called once per
frame from `SkyViewModel.currentFrameData()` using wall-clock deltas, so the
camera stays the single source of truth for where we're looking and behaves
identically at 60 or 120 Hz. `preferredFramesPerSecond` tracks the display's
native refresh rate rather than a fixed 30, which is what makes panning read as
continuous.

## Why SwiftData for persistence

Phase 1 only needs a lightweight, forward-compatible persistence layer
(see `Core/Models/SavedLocation.swift`): a `SavedLocation` model stub and a
generic `UserPreference` key/value model, wired into the app's
`ModelContainer` at launch. SwiftData was chosen over a hand-rolled
Codable/JSON store or Core Data because:

- It's the native, first-party persistence framework tightly integrated
  with SwiftUI (`@Query`, `@Environment(\.modelContext)`), reducing
  boilerplate to add UI for saved locations/preferences in later phases
  (Observation Planner, Journal, Compare Skies all need durable storage).
- Schema evolution (adding fields/models later) is handled by SwiftData's
  lightweight migration story without hand-writing a migration layer now.
- The catalog data (stars, constellations) is *not* stored in SwiftData —
  it's static reference data bundled as JSON and loaded once per launch by
  `CatalogService`, which is the right separation: SwiftData is for
  *user* data, not bundled reference data.

## Apparent places

Everything the app draws is an **apparent** place: where the object actually
appears to an observer on the moving, spinning, atmosphere-wrapped Earth at
that instant, not its catalogue position. The reduction lives in two files and
happens in exactly one place each, which is what keeps every body in a frame in
the same frame.

`Core/Coordinates/ApparentFrame.swift` holds both halves:

- **`EarthState`** — where the Earth is and how fast it is moving, plus the
  nutation angles, for one instant. Every solar-system ephemeris starts from
  it: the Sun is the Earth's heliocentric position negated, a planet is its own
  minus the Earth's with the light-time iteration, the Moon's geocentric series
  needs only the nutation. Building it once and handing it to all of them is
  cheaper and, more importantly, makes it impossible for two bodies to disagree
  about the frame they are drawn in.
- **`ApparentFrame`** — the same information packaged for the *catalogue*: one
  rotation (precession then nutation, J2000 -> true equator and equinox of
  date), one vector (annual aberration) and one angle (apparent sidereal time).
  `SkyProjector` folds the rotation into its per-frame matrix and applies the
  vector per star, so tens of thousands of stars are reduced for the price of a
  matrix product and a vector add each.

What the reduction includes, and what each is worth in 2026:

| Effect | Size | Where |
|---|---|---|
| Precession | 0.36°, growing | `Precession` |
| ΔT (TT − UT) | 69 s — 35″ on the Moon | `DeltaT` |
| Nutation | up to 17″ | `Nutation` |
| Annual aberration | up to 20.5″ | `ApparentFrame` |
| Light-time | up to 1.4° for Jupiter's own motion | `PlanetPosition` |
| Topocentric parallax | up to 1° for the Moon | `EphemerisService` |
| Atmospheric refraction | 34′ at the horizon | `Refraction` |

The ordering rule that runs through all of it: **positions of bodies use TT,
where the observer is looking uses UT.** Sidereal time is the Earth's rotation
angle, so it must keep being fed UT; the planetary and lunar theories are
expressed in TT. Mixing them is a 69-second error, which on the Moon is half an
arcminute.

One deliberate exception: satellites stay on **mean** sidereal time, because
SGP4 emits TEME, whose origin of right ascension is the mean equinox. That is
why `CoordinateTransformService` exposes both `localSiderealTimeDegrees`
(apparent, the default for everything else) and `localMeanSiderealTimeDegrees`
(the satellite frame).

Accuracy is pinned against JPL Horizons in `AstronomyTests/AccuracyTests.swift`
over 1850-2045: under 0.5″ for the Sun and the inner planets, 2″ for Neptune,
3.8″ for the Moon, and under 5″ for the full topocentric alt/az chain.

## Coordinate transform pipeline

```
RA/Dec (equatorial, J2000, from catalog/ephemeris)
        │  ApparentFrame: precession -> nutation -> aberration
        ▼
RA/Dec (apparent, true equator and equinox of date)
        │  CoordinateTransformService.horizontal(from:observer:julianDay:)
        │  — needs: observer lat/lon, current time (-> apparent sidereal time)
        ▼
Alt/Az (horizontal, observer- and time-dependent)
        │  Refraction.Table — the atmosphere lifts everything near the horizon
        ▼
Alt/Az (apparent)
        │  CoordinateTransformService.stereographicProject(horizontal:center:fieldOfViewDegrees:)
        │  — needs: camera center Alt/Az, field of view
        ▼
Normalized device coordinates (-1...1), aspect-corrected
        │  SkyRenderer packs into PointVertex/LineVertex buffers
        ▼
GPU rasterization (Shaders.metal) -> pixels
```

Every object (star, Sun, Moon, planet) goes through the *same* two-stage
transform every frame: equatorial -> horizontal (Meeus Ch. 12-13: Local
Sidereal Time + spherical trigonometry) -> screen (stereographic
projection, conformal — angles/shapes near the projection center are
preserved, which matters for constellation shapes to look right). Click
hit-testing reuses the exact same per-frame projected positions the
renderer just drew (`SkyRenderer.lastProjectedObjects`), so selection is
always pixel-consistent with what's on screen.

## Rise, set and transit

`Core/Astronomy/RiseSetCalculator.swift` solves `h(t) = h0` for the instant a
body's altitude crosses a standard altitude, and locates its culmination.
Standard altitudes are Meeus, *Astronomical Algorithms* 2nd ed., Ch. 15 (15.1):
`-0.5667°` for a point source (horizon refraction), `-0.8333°` for the Sun (the
same refraction plus the solar semidiameter, since sunrise is the upper limb),
`-6 / -12 / -18°` for civil, nautical and astronomical twilight (definitions,
so no refraction term), and `0.7275·π − 34'` for the Moon, whose ~57' of
horizontal parallax makes its `h0` *positive*.

**The method is not Meeus's own three-value interpolation, deliberately.**
15.2 interpolates apparent positions from three printed almanac entries because
that is all a 1990s reader had. Here the ephemeris is a function that can be
evaluated at any instant in microseconds, so the interpolation is pure
downside — it is the part carrying the error, and it degrades exactly where the
body moves fastest (the Moon) and where the crossing is most oblique (high
latitudes). Instead:

1. `h(t)` is sampled on a 10-minute grid across the window, **re-evaluating the
   body's position at every sample**, so the object's own motion over the night
   is exact rather than assumed linear.
2. Each grid interval straddling `h0` brackets a crossing, refined by
   **bisection** to 1e-6 d (0.09 s). Bisection over Newton because it cannot
   diverge, and the cases that make Newton diverge — a grazing circumpolar
   object, a polar-circle Sun — are precisely the ones this has to get right.
3. Transit is the maximum of `h(t)`, found by ternary search on the bracket
   around the best grid sample (altitude is unimodal over one diurnal cycle).

The awkward cases are *reported*, never invented. `Circumstance` distinguishes
`risesAndSets`, `alwaysUp` (circumpolar, or polar day) and `neverUp`, and every
time in `NightWindow` is optional: a Tromsø June has no sunset, and a Reykjavík
June has a sunset but never reaches −18°, so there is no astronomical night at
all and the panel says so rather than showing a dash.

Verified against published values in `AstronomyTests/TonightTests.swift`: Meeus
Example 15.a (Venus from Boston, 1988-03-20) to under a minute on all three of
rise, transit and set, and the USNO sunrise/sunset for New York on the 2024 June
solstice to under 36 seconds. Circumpolar, never-rising and high-latitude cases
are asserted structurally rather than numerically, because the right answer
there is "there is no such time".

## The visibility model — why it is not a score

The founding brief says: *avoid arbitrary scores; define the reasoning behind
the visibility calculation.* `Core/Astronomy/VisibilityRating.swift` therefore
contains **no weighted sum and no 0–100 number.** It evaluates four independent
physical constraints and takes the **worst** of them — a limiting-factor model —
and reports which constraint that was (`limitingFactor`). One fatal problem
cannot be averaged away by three good numbers, and every band boundary is a
statement about the sky rather than a tuning knob.

| Constraint | Quantity | Excellent | Good | Difficult | Not visible |
|---|---|---|---|---|---|
| Altitude / airmass | peak altitude during darkness; airmass by Kasten & Young (1989) | ≥ 40° (X ≤ 1.56) | ≥ 25° (X ≤ 2.37) | ≥ 10° (X ≤ 5.6) | < 10° |
| Time in darkness | hours above 25° while the Sun is below −18° | ≥ 2 h | ≥ 1 h | > 0 h | 0 h |
| Moonlight | `impact = k^1.5 · sepFactor · upFraction` | < 0.25 | < 0.55 | ≥ 0.55 | — |
| Contrast (extended) | `C = skySB − targetSB − k·X` | ≥ 1.5 | ≥ 0.5 | ≥ −1.0 | < −1.0 |
| Brightness (point) | `m_lim − (m + k·X)` | ≥ 2.0 | ≥ 1.0 | ≥ 0 | < 0 |

The supporting quantities, and where each number comes from:

- **Airmass** `X = 1 / (sin h + 0.50572 (h + 6.07995)^-1.6364)` — Kasten & Young
  (1989), better than 1% to the horizon where `sec z` diverges. Extinction is
  `k·X` with `k = 0.28 mag/airmass`, a standard clear-site V-band value.
- **Sky brightness** is a real surface brightness, not a penalty coefficient, so
  it can be compared to the target's own. Two published anchors fix the scale: a
  dark moonless V sky at **21.8 mag/arcsec²**, a high full Moon driving it to
  about **18.5** near the target. The model interpolates:
  `skySB = 21.8 − 3.5 · impact`, with
  `impact = k^1.5 · (0.35 + 0.65·(1 − min(ρ,120)/120)) · upFraction`.
  `k` is the illuminated fraction (the 1.5 power is why a quarter Moon costs so
  much less than a full one); `ρ` is the Moon–target separation, with a 0.35
  floor because moonlight scatters across the whole sky; `upFraction` is how much
  of the dark window the Moon is actually above the horizon — a Moon that has set
  costs nothing.
- **Surface brightness** `SB = m + 2.5 log10(π a b)` (a, b semi-axes in arcsec).
  Extended objects are limited by this, not by integrated magnitude, which is why
  M33 at mag 5.7 is harder than many mag-9 galaxies.
- **Limiting magnitude** for point sources assumes a stated instrument:
  `m_lim = skySB − 15.3 + 5 log10(D/7mm)` with `D = 80 mm`, calibrated so a
  21.8 sky gives the conventional 6.5 naked-eye limit at a 7 mm pupil. Under a
  dark sky the 80 mm figure is 11.8.

`TonightPlanner` assembles this into the dashboard: the night window anchored on
solar noon (found by Newton iteration on the Sun's hour angle, so a 24-hour
window containing two transits is never ambiguous), the Moon, the planets, and
the deep-sky catalogue filtered to magnitude ≤ 12 and ranked best-band-first.
The panel's second line per target is the derivation — peak altitude, airmass,
hours in darkness, limiting factor — not decoration.

## Object sky paths

`Core/Astronomy/SkyPath.swift` samples the track a selected object traces across
the observer's sky, in the **horizontal** frame. That choice is the feature: a
path in RA/Dec is a dot for a star, whereas the horizontal-frame path is the
composition of the object's motion with the Earth's rotation, which is what a
person standing outside actually sees. A star therefore still has a useful path —
its diurnal arc — rather than being a degenerate case.

Cadence is per object class, chosen so consecutive samples are of order a degree
apart: 1 s for satellites (a LEO pass moves at ~4°/s), 60 s for the Moon, 300 s
for the Sun/planets and for fixed catalogue positions. The cadence then relaxes
until the span fits `maximumSamples = 2000`, so no request can produce an
unbounded track.

Three properties are load-bearing:

- **Drawn through the existing line pass.** `buildObjectPath` appends to the same
  `lineVertices` the constellation figures use, so a path costs no extra pass,
  pipeline state or draw call.
- **Occluded like everything else.** Each vertex's alpha is multiplied by
  `TerrainProfile.dimming` at its own alt/az, exactly as constellation segments
  are, so a track dipping below the skyline fades into the dunes instead of
  vanishing at the horizon or drawing over them.
- **Gated by satellite accuracy.** A satellite path is clamped to one hour
  (`satelliteMaximumSpanSeconds`, a little over one LEO revolution) and every
  sample must pass the same `SatelliteAccuracy.isDrawable` gate the markers obey.
  The first sample that fails **ends** the track — stopping rather than skipping
  and resuming, which would read as two separate passes — and the info panel says
  the track was cut short.

Paths are recomputed only when the selection, the range or the location changes.
`SkyViewModel` keys the held path on those plus a *quantised* anchor instant (one
minute for "next hour", one hour for "24 hours", one day for "tonight"), so the
per-frame cost is a string comparison and never a rebuild. Satellite tracks are
one batched hop onto `SatelliteTracker`'s actor rather than one hop per sample.

## Separation of calculation vs. rendering vs. presentation

- **Calculation** (`Core/Time`, `Core/Coordinates`, `Core/Astronomy`): pure
  functions/structs over `Foundation`/`simd` types. No knowledge of Metal
  buffer layouts or SwiftUI views. This is the layer covered by
  `AstronomyTests/`.
- **Rendering** (`Rendering/*`): knows about Metal buffer layouts,
  `MTKView`, pipeline states, and GPU-side color/size mapping
  (`StarAppearance`). Consumes calculation-layer output via the
  `SkyFrameData` snapshot struct; has no knowledge of SwiftUI.
- **Presentation** (`Features/Sky`, `DesignSystem`): SwiftUI views and the
  `SkyViewModel` that ties calculation + rendering + services together for
  the UI. Renders the `SkyMetalView` (an `NSViewRepresentable`) as a layer
  and floats translucent panels on top.

## Swift Concurrency usage

- `CatalogService` is an `actor`; `loadStars()`/`loadConstellationLines()`
  decode the bundled JSON off the main thread and cache the result, so
  parsing ~5,000 star records never blocks the UI.
- `TimeController` and `SkyViewModel` use structured `Task { … }` loops
  (`Task.sleep(for:)`) instead of `Timer`/Combine to tick the live clock
  and periodically refresh Sun/Moon/planet positions, cooperatively
  cancelled in `deinit`.
- Both are `@MainActor`-isolated `@Observable` classes, so SwiftUI updates
  stay on the main actor without manual dispatching, while the actual
  catalog *decoding* work happens off it.
