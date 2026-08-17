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
