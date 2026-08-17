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
    Astronomy/            SunPosition, MoonPosition, PlanetPosition, EphemerisService.
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

The star catalog bundled with the app contains ~5,000 stars (down to
magnitude 6), plus several hundred constellation-line segments and a
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
Faint stars are rejected by a magnitude-vs-FOV comparison *before* any
trigonometry, so the trig cost scales with what's actually drawn, not with
catalog size.

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

## Coordinate transform pipeline

```
RA/Dec (equatorial, J2000, from catalog/ephemeris)
        │  CoordinateTransformService.horizontal(from:observer:julianDay:)
        │  — needs: observer lat/lon, current time (-> Local Sidereal Time)
        ▼
Alt/Az (horizontal, observer- and time-dependent)
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
