# Data Sources

## Star catalog — `Astronomy/Data/Catalogs/stars.json`

- **Source**: [HYG Database](https://github.com/astronexus/HYG-Database) v4.1
  (`hyg/CURRENT/hygdata_v41.csv.gz`), maintained by David Nash / AstroNexus.
  HYG merges the Hipparcos, Yale Bright Star Catalog (5th ed.), and Gliese
  catalogs into one table with consistent J2000 astrometry.
- **License**: CC BY-SA 4.0 (see `hyg/CURRENT/LICENSE` in the upstream
  repository). Attribution: HYG Database, astronexus/HYG-Database,
  CC BY-SA 4.0.
- **Filtering applied**: rows with the Sun's own entry (`id == 0`) removed;
  kept only stars with apparent magnitude ≤ 9.0, yielding **83,479 stars**
  (431 of them with proper names), sorted ascending by magnitude, 8.8 MB of
  JSON.
- **Why magnitude 9.0**: HYG is essentially complete to about magnitude 9 and
  falls off sharply beyond it — at 10 and 11 the coverage is visibly patchy,
  and rendering a patchy catalogue produces a sky with holes in it, which
  looks worse than a shallower one. 9.0 is therefore the deepest limit at
  which a zoomed-in field still looks like a real star field. Two pieces of
  the renderer are pinned to this number on purpose:
  `StarAppearance.limitingMagnitude` at its narrow-field end, and
  `SkyBrightness.darkSkyDisplayCeiling` at astronomical night — so "fully
  zoomed in under a dark sky" and "the bottom of the data" are the same
  place. Raising the catalogue's depth means raising both.
- **Rendering cost**: 83k stars is far too many to run projection
  trigonometry over every frame, so `Data/Catalogs/StarIndex.swift` builds a
  5-degree equatorial grid with per-cell bounding cones once at load time
  (off the main thread, alongside the decode) and the renderer culls whole
  cells against the viewport cone before touching any star.
- **Backwards compatibility**: every `id` present in the previous
  magnitude-6.0 export is still present, so `constellations.json` joins
  unchanged — all 690 segments still resolve.
- **Space saving**: `spectralType` is emitted as `null` for unnamed stars
  fainter than magnitude 6.5, where it is never surfaced in the UI.
- **Fields retained** (see `Star.swift`):
  - `id` — HYG catalog row id (also used as the join key for constellation
    line segments, see below).
  - `name` — common/proper name where the HYG database provides one
    (`proper` column), otherwise `nil` (UI falls back to `"HR <id>"`).
  - `ra`, `dec` — J2000 equatorial coordinates, converted from HYG's
    RA-in-hours to decimal degrees.
  - `magnitude` — apparent visual magnitude.
  - `colorIndex` — B-V color index (HYG `ci` column), used to derive a
    physically-motivated star color for rendering (`StarAppearance.swift`).
  - `spectralType` — HYG `spect` column, spectral classification string.
- **Provenance/build process**: downloaded directly from the upstream
  GitHub repository, filtered and re-serialized to JSON with a one-off
  Python script (not checked into the repo — the *output* `stars.json` is
  what's bundled). To refresh: re-download `hygdata_v41.csv[.gz]`, re-apply
  the same magnitude filter, re-export to the same JSON shape.
- **Decode timing**: about 0.30 s for `Data(contentsOf:)` plus
  `JSONDecoder` on an Apple silicon Mac (release build), plus roughly the
  same again to build the spatial index. Both happen on the `CatalogService`
  actor's executor while the UI shows its loading state; nothing blocks the
  main actor. If this ever becomes a felt delay, the fix is a binary
  (property-list or packed-struct) format rather than JSON.

## Constellation lines — `Astronomy/Data/Catalogs/constellations.json`

- **Source**: [Stellarium](https://github.com/Stellarium/stellarium)'s
  `skycultures/modern/index.json`, the "modern" (IAU) sky culture bundled
  with the Stellarium planetarium application. Its `constellations[].lines`
  arrays define the standard 88 IAU constellation stick-figure line
  segments using Hipparcos (HIP) catalog numbers for each star endpoint.
- **License**: Stellarium's sky culture data is released under
  CC BY-SA 4.0 (consistent with the rest of the Stellarium project's
  data assets). Attribution: Stellarium project, modern IAU sky culture,
  CC BY-SA 4.0.
- **Transformation applied**: each HIP-numbered line segment was
  cross-referenced against the HYG database's `hip` column to translate
  HIP numbers into this app's star catalog `id`s; segments whose endpoint
  star was not in the HYG database were dropped (5 of 695 raw segments,
  leaving **690 segments** across all 88 constellations). All 690 still
  resolve against the deeper magnitude ≤ 9.0 catalogue.
- **Fields**: `starID1`, `starID2` — both are `Star.id` values joinable
  against `stars.json`.

## Ephemeris (Sun / Moon / planets)

All positions are computed at runtime in Swift — nothing is bundled as
precomputed ephemeris data.

- **Sun** (`Core/Astronomy/SunPosition.swift`): Jean Meeus, *Astronomical
  Algorithms*, 2nd ed., Chapter 25, "reduced precision" method (accurate to
  about 0.01° in longitude for dates near the present era).
- **Moon** (`Core/Astronomy/MoonPosition.swift`): Meeus, Chapter 47,
  truncated to the ~17 largest-amplitude periodic terms of the full
  ELP2000-based series (the full series has dozens of terms per
  coordinate). Accuracy with this truncation is roughly 0.2-0.3° —
  sufficient for sky-chart visualization, not for precise
  occultation/eclipse prediction.
- **Planets, Mercury-Neptune** (`Core/Astronomy/PlanetPosition.swift`):
  mean Keplerian orbital elements at J2000.0 plus linear secular rates,
  from the JPL Solar System Dynamics Group's "Keplerian Elements for
  Approximate Positions of the Major Planets" (E.M. Standish), the same
  low-precision element set Meeus summarizes in Chapter 31. Positions are
  computed via two-body Kepler-equation solutions (Newton-Raphson) with
  **no planetary perturbations**, valid for roughly 1800-2050 with
  accuracy on the order of a few arcminutes for the inner planets and
  somewhat worse (tens of arcminutes) for the outer planets.

### Accuracy caveats

- All of the above are *low-precision* methods by design (per the task's
  explicit "arcminute precision is fine" requirement) — they will not match
  JPL Horizons or VSOP87 full-series results to the arcsecond.
- The Moon and outer planets carry the largest error budgets; treat marker
  positions as visually indicative, not observation-grade.
- No atmospheric refraction correction is applied to Alt/Az output.

### Update process

If higher accuracy is ever needed, the natural upgrade path is swapping the
truncated Meeus series for full VSOP87/ELP2000 term tables, or bundling
precomputed short-arc ephemeris data — the `EphemerisService` facade is the
single seam to change; nothing downstream (`SkyRenderer`, `SkyViewModel`)
depends on how positions are computed.

## Constellation names/centres — `Astronomy/Data/Catalogs/constellation_names.json`

- **Source**: hand-compiled table of the 88 IAU constellations with an
  approximate figure centroid (RA/Dec) for each, used only to place the
  constellation name label (`Constellation.swift`). These are eyeballed
  centres of the stick-figure line art already bundled in
  `constellations.json`, not the official IAU boundary centroids — good to
  a few degrees, which does not matter at label scale.
- **License**: original data compiled for this project; no upstream license
  applies.

## Milky Way band — procedural, not imagery

- **What it is**: the background pass (`Shaders.metal`,
  `backgroundFragmentShader`) paints a soft additive band that is brightest
  along the galactic equator and fades with galactic latitude and toward
  the galactic anticentre. **This is an analytic approximation, not a
  photographic or survey-derived image of the Milky Way.** No star-density
  map, extinction map, or astrophotography imagery is used or embedded.
- **How it's computed**: `Core/Coordinates/GalacticCoordinates.swift`
  builds the equatorial -> galactic rotation matrix directly from the
  IAU 1958 galactic coordinate system's defining directions, expressed in
  J2000 equatorial coordinates (values as quoted in the Hipparcos/Tycho
  catalogue introduction, ESA SP-1200 Vol. 1 Sect. 1.5.3):
  - North galactic pole: RA 192.85948°, Dec +27.12825°
  - Galactic centre: RA 266.40510°, Dec -28.93617°
  The CPU precomputes one 3x3 camera-to-galactic rotation per frame
  (`SkyBackgroundUniforms.swift`); the fragment shader applies it per pixel
  to get galactic latitude `b` and longitude `l`, then shapes the band with
  a Gaussian-like falloff in `sin(b)` (narrow near the equator, symmetric
  above/below) multiplied by a broad brightening toward `l = 0`
  (`towardCenter` in `Shaders.metal`) so the band reads brightest near
  Sagittarius/the galactic centre direction and dims toward the anticentre.
- **Limitations**: no fine structure (dust lanes, the Great Rift, individual
  star clouds), no seasonal/hemisphere brightness asymmetry beyond the
  smooth galactic-latitude falloff, and no attempt to match real integrated
  surface brightness. It is a deliberately subtle, additively-blended,
  scientifically-*oriented* placeholder — real astronomical imagery (e.g. a
  Milky Way panorama) would be a legitimate future upgrade, and should keep
  this same coordinate-transform seam if added.

## Sky lighting model — analytic approximation, not radiative transfer

Implemented in `Shaders.metal` (`backgroundFragmentShader`); see the extended
comment block there for the full derivation.

- **Angular term**: the Rayleigh phase function `(3/4)(1 + cos²γ)` for
  molecular scattering, plus a forward-scattering Henyey–Greenstein lobe
  (Henyey & Greenstein 1941) with `g = 0.76` standing in for aerosol/Mie
  scattering. `γ` is the **true angular distance from the Sun**, taken from
  `dot(skyDirection, sunDirection)`.
- **Optical path term**: relative air mass from Kasten & Young (1989),
  "Revised optical air mass tables and approximation formula", *Applied
  Optics* 28(22), 4735 —
  `X(h) = 1 / (sin h + 0.50572 (h_deg + 6.07995)^-1.6364)`.
- **Shape borrowed from**: Preetham et al. (1999) and Hosek & Wilkie (2012)
  analytic skylight models — the *structure* (angular term × optical-path
  term), not their coefficient tables.
- **Deliberately omitted**: aerosol turbidity parameter, ozone absorption,
  multiple scattering, per-wavelength spectral integration / Rayleigh λ⁻⁴
  weighting, illuminance calibration, tone mapping, clouds, terrain
  shadowing, refraction of the solar disk. Colour is carried by an
  interpolated RGB ramp keyed on Sun altitude; the phase functions modulate
  brightness and saturation, not hue. **This is not physically based
  rendering** and should not be cited as such.

## Sky background brightness / star visibility — `Core/Astronomy/SkyBrightness.swift`

- **What it is**: an empirical curve mapping Sun altitude to zenith sky
  surface brightness in mag/arcsec², interpolated smoothly (smoothstep)
  between hand-placed anchors straddling the standard twilight boundaries,
  then converted to a naked-eye limiting magnitude by the linear fit
  `m_lim = 0.55 μ − 5.55`.
- **Calibration points**: a pristine 21.9 mag/arcsec² sky yields the textbook
  naked-eye limit of 6.5; a midday 3.0 mag/arcsec² sky yields −3.9, so Venus
  (−4.2) survives daylight and essentially nothing else does.
- **Display override (important)**: the renderer does **not** apply the
  physical limit literally. `SkyBrightness.displayLimitingMagnitude` is a
  **product choice, not photometry**: it re-maps the same sky-brightness
  variable μ onto a smoothstep running from `daylightDisplayFloor` = 5.6 to
  `darkSkyDisplayCeiling` = 9.0 as μ goes from 3.0 to 21.4. It departs from
  physics in both directions, deliberately:
  - *Too generous by day.* Applied literally, the physical limit empties the
    daytime sky (only the Sun, Moon and Venus survive), which is useless for
    a planetarium whose job is answering "what is up there right now". The
    5.6 floor is the standard see-through planetarium convention. A bright
    sky instead costs *contrast* (`starContrast`, easing from 1.0 in full
    dark to 0.72 under a high Sun).
  - *Too generous by night.* 9.0 rather than the physical 6.5, because a
    monitor compresses six orders of magnitude of brightness into about two
    and the faint field is the first thing lost. Drawing to the catalogue's
    depth restores the *impression* of a dark sky at the cost of being
    literally wrong about how many stars an unaided eye could resolve.
  The honest function, `SkyBrightness.limitingMagnitude` (`0.55 μ − 5.55`),
  is untouched, separately unit-tested, and is what should be cited.
  Representative drawn limits: 5.60 at Sun +45°, 5.84 at 0°, 7.38 at −6°,
  8.70 at −12°, 9.00 at −18° and below.
- **Field-of-view limit**: independently, `StarAppearance.limitingMagnitude`
  caps the drawn depth by zoom level — 5.4 at a 150° field rising to 9.0 at
  3°, interpolated on log(FOV). The effective cutoff is the *more
  restrictive* of the two, so a wide field stays legible even at midnight.
  The background shader also dims the sky by up to 18% at narrow fields; that
  is a legibility/aesthetic choice and is documented as such in
  `Shaders.metal` — a telescope does not actually darken the sky.
- **Solar-system exemption**: the Sun, Moon and planets bypass the magnitude
  cutoff entirely at every hour, so Uranus (~5.7) and Neptune (~7.8) never
  disappear. They are still modulated in contrast by sky brightness, but
  never to zero.
- **This affects only which stars are drawn and how strongly, never where
  they are**: positions always come from real catalogue J2000 RA/Dec run
  through the real observer/time transform, so a star drawn at noon sits at
  the exact altitude and azimuth it genuinely occupies behind the daylight.
- **Limitations**: the anchors are chosen to look right, not measured; there
  is no airmass/extinction term for objects low in the sky, no Moon
  contribution to sky brightness, no light-pollution (Bortle) parameter, and
  no per-observer dark adaptation. The slope of 0.55 is a fit, not a
  derivation. For a properly derived treatment see B. E. Schaefer,
  "Telescopic Limiting Magnitudes", *PASP* 102, 212 (1990).

## Planetary radii — `StarAppearance.angularDiameterDegrees`

- **Source**: NASA/GSFC Planetary Fact Sheets (mean equatorial radii, in km).
- **Use**: apparent angular diameter is computed as `2·atan(r / d)` where `d`
  is the geocentric distance from the ephemeris, so disks grow and shrink
  correctly as a planet approaches or recedes. A documented
  minimum-visualization size keeps bodies clickable at wide field.
- **Limitations**: Saturn's ring tilt is a fixed tasteful approximation, not
  computed from true ring-plane geometry; oblateness is ignored (equatorial
  radius used as a sphere); no limb darkening; procedural banding on Jupiter
  is decorative, not a map of real belts and zones.
