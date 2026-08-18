# Data Sources

## Star catalog — `Astronomy/Data/Catalogs/stars.json`

- **Source**: [HYG Database](https://github.com/astronexus/HYG-Database) v4.0
  (`hyg/CURRENT/hygdata_v40.csv.gz`), maintained by David Nash / AstroNexus.
  HYG merges the Hipparcos, Yale Bright Star Catalog (5th ed.), and Gliese
  catalogs into one table with consistent J2000 astrometry.
- **License**: CC BY-SA 4.0 (see `hyg/CURRENT/LICENSE` in the upstream
  repository). Attribution: HYG Database, astronexus/HYG-Database,
  CC BY-SA 4.0.
- **Filtering applied**: rows with the Sun's own entry (`id == 0`) removed;
  kept only stars with apparent magnitude ≤ 6.0 (naked-eye visibility
  threshold), yielding **5,070 stars** — well above the "several thousand"
  MVP bar while keeping the bundle small and the per-frame point count
  render-friendly.
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
  what's bundled). To refresh: re-download `hygdata_v40.csv[.gz]`, re-apply
  the same magnitude filter, re-export to the same JSON shape.

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
  star didn't survive the magnitude ≤ 6.0 filter above were dropped
  (5 of 695 raw segments, leaving **690 segments** across all 88
  constellations).
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
