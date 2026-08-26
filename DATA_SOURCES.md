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
    (`proper` column), otherwise `nil`. The UI then falls back through the
    designations below — Bayer/Flamsteed, HR, HD, HIP, Gliese — and only as a
    last resort prints `"HYG <id>"`, labelled as the internal row id it is.
  - `ra`, `dec` — J2000 equatorial coordinates, converted from HYG's
    RA-in-hours to decimal degrees.
  - `magnitude` — apparent visual magnitude.
  - `colorIndex` — B-V color index (HYG `ci` column), used to derive a
    physically-motivated star color for rendering (`StarAppearance.swift`).
  - `spectralType` — HYG `spect` column, spectral classification string.
  - `hip`, `hd`, `hr` — Hipparcos, Henry Draper and Harvard Revised (Bright
    Star Catalogue) numbers, from the HYG columns of the same names. Integers,
    **omitted entirely** when the HYG row has no value rather than emitted as
    `null` or `""`.
  - `gl` — Gliese designation as printed ("Gl 244A"), HYG `gl` column.
  - `bf` — HYG's compact Bayer/Flamsteed string ("9Alp CMa"): Flamsteed
    number, Bayer code (sometimes split as "Alp-1"), IAU constellation
    abbreviation. Unpacked at runtime by `StarDesignations`.
- **Why the designations are there at all**: only **431** of the 83,479 entries
  have a proper name. The other 83,048 previously carried **no identifier in
  our schema whatsoever** — the columns were dropped at export — so they were
  literally unsearchable, and `Star.displayName` fell back to printing the HYG
  *row id* as if it were an HR number (Sirius is row 32263 and HR 2491; those
  are different catalogues). Adding the identifier columns back is what makes
  "HD 48915", "HIP 32349", "HR 2491" and "Alpha Canis Majoris" all resolve to
  Sirius. See `Data/Catalogs/StarSearchIndex.swift`.
- **Size cost, which is real**: `stars.json` grew from **9,268,296 to
  11,360,648 bytes (+2.09 MB, +22.6%)**. The keys are deliberately short and
  absent-rather-than-empty for exactly this reason. Decode time (Debug build,
  Apple silicon, best of three) went from about 0.30 s to about 0.43 s, and the
  new designation index costs a further ~0.10-0.15 s to build. All of it
  happens on the `CatalogService` actor's executor while the UI shows its
  loading state — nothing is added to the main actor — but it is 0.2 s of extra
  launch work and worth knowing. If it ever matters, the fix is the same one
  the decode note below already names: a binary format instead of JSON.
- **Regeneration is field-additive and verified as such**: the export was
  produced by re-reading the same HYG v4.1 CSV and merging the identifier
  columns into the *existing* JSON rows, then asserting that stripping the five
  new keys reproduces the previous file byte for byte. The star set, the
  ordering and every `id` are unchanged, so all 690 constellation segments
  still resolve (`AstronomyTests/StarDesignationSearchTests.swift` checks all
  three properties against the bundled files).
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
- **Pluto** (same file, same table): the JPL table has a **ninth row** for
  Pluto, valid over the same 1800-2050 span, and that is where Pluto's
  elements come from — deliberately the same source as everything else here,
  so the provenance stays consistent rather than mixing a second ephemeris in.
  Two caveats belong with it:
  - It is the **least accurate row in the table**. A steeply inclined (17°),
    eccentric (e = 0.249) orbit modelled by a pure two-body Keplerian solution
    with no perturbations is the hardest case in the set.
  - The **1800-2050 validity window matters far more for Pluto** than for the
    inner planets. Pluto's period is 248 years, so the window covers barely
    one revolution; the linear element rates have almost no baseline to be
    right over, and the residual grows toward the ends of the window rather
    than staying flat the way Mercury's does. The app clamps the time machine
    to that window anyway (below), which is what keeps this honest.

  Measured residual against **JPL Horizons** (target `999`, centre `500@399`,
  `QUANTITIES=2`, i.e. apparent airless RA/Dec of date) for 2026-Jan-01
  00:00 UTC: **0.0050°, about 18 arcseconds** — see
  `AstronomyTests/PlutoTests.swift`, which pins this.

  Pluto is classified `CelestialObjectKind.dwarfPlanet`, not `.planet`, and
  that distinction is load-bearing at render time. The major planets are
  **exempt** from the limiting-magnitude cutoff (a planetarium has to be able
  to answer "where is Neptune"); Pluto, at magnitude ~14.4, is **not** — it
  goes through the same `StarAppearance.visibility` cutoff a star of that
  magnitude would, so it is correctly absent from the naked-eye sky at every
  field of view and every sky brightness. It is still fully searchable and
  selectable, and **selection reveals it**: a selected dwarf planet is drawn
  at full strength with the selection ring around it, so searching "Pluto"
  ends on a marked point at Pluto's true place rather than an empty patch of
  sky.

### Other dwarf planets — deliberately **not** included

Ceres, Eris, Makemake, Haumea and the rest are **not in the JPL major-planet
Keplerian table**, and no elements for them are bundled or invented. Adding
them properly means a second, separately-documented source — JPL Small-Body
Database or MPC osculating elements — which also means osculating elements
with a stated epoch rather than the mean-elements-plus-secular-rates form this
file is built around, and (for Ceres in the main belt) perturbation handling
this two-body solver does not have. Rather than fabricate an element row, they
are left out. Pluto is included because, and only because, it is in the source
this app already uses.

### Accuracy caveats

- All of the above are *low-precision* methods by design (per the task's
  explicit "arcminute precision is fine" requirement) — they will not match
  JPL Horizons or VSOP87 full-series results to the arcsecond.
- The Moon and outer planets carry the largest error budgets; treat marker
  positions as visually indicative, not observation-grade.
- No atmospheric refraction correction is applied to Alt/Az output.

### Reference frame — everything is now "of date"

All three sources produce positions referred to the **mean equinox and equator
of the displayed date**, which is the frame the observer's sidereal time is in.
Getting this consistent matters: mixing frames puts objects out of register with
each other, which is exactly how a conjunction renders wrong.

- The **Sun** (Meeus Ch. 25) and **Moon** (Ch. 47) series are of-date natively.
- The **planets** are not. Standish's Keplerian elements are referred to the
  **J2000.0 ecliptic**, so `PlanetPosition` now rotates by the J2000 obliquity
  and then applies `Precession` from J2000 to the date. Previously it rotated by
  the *of-date* obliquity and stopped there, which was a partial and
  inconsistent version of the same correction and left the planets about 0.36°
  out of register with the Sun and Moon in 2026.

### Validity window — 1800-2050, and what the app does about it

Standish publishes two element tables: one fitted for **1800 AD - 2050 AD** and a
lower-accuracy one for 3000 BC - 3000 AD. This app carries the first, so
1800-2050 is where the few-arcminute claim above actually holds. The truncated
lunar series is likewise quoted for the modern era.

**The decision (`EphemerisService.validYearRange`): the time machine is clamped
to that window.** The date/time picker will not select outside it and the
hour/day/month/year step buttons stop at its edges. Outside the window the code
would still produce numbers, and they would still look exactly like a sky —
degrees wrong, with nothing on screen to say so. Refusing to leave the window is
the only behaviour that cannot mislead, and 1800-2050 is far wider than any
"what does my sky look like in two months" question needs.

## Precession of the equinoxes — `Core/Astronomy/Precession.swift`

- **Formulation**: IAU 1976 precession (Lieske, Lederle, Fricke & Morando,
  *Astronomy & Astrophysics* **58**, 1 (1977)), in the rigorous three-angle
  form given by Meeus, *Astronomical Algorithms*, 2nd ed., **Chapter 21**,
  equations 21.2 (the zeta / z / theta polynomials) and 21.4 (the rotation),
  reduced to the fixed starting epoch J2000.0. Applied as a 3x3 rotation matrix
  built once per frame and shared by every catalogue object, so per-star cost is
  a matrix-vector product rather than its own trigonometry.
- **Why it is needed**: the star and deep-sky catalogues are J2000.0 mean
  places; the observer's celestial equator is not. The equinox has regressed
  about 0.36° by 2026 (Sirius itself moves 0.28°) — already larger than the
  Moon's radius, and a time machine spanning decades makes it far worse.
- **Verification**: `PrecessionTests` checks two independent published
  quantities. Meeus's worked **Example 21.b** (theta Persei to 2028 Nov 13.19)
  reproduces to better than 0.005 arcseconds in declination; and precessing the
  vernal equinox forward one Julian year reproduces the published IAU annual
  constants m = 3.07496 s and n = 20.0431 arcsec to six significant figures.
  The matrix is also asserted orthonormal with determinant +1.
- **Not modelled — proper motion.** The bundled catalogue carries no per-star
  velocity, so stars are treated as fixed on the celestial sphere. This is the
  largest remaining error over long spans: Barnard's Star moves 10.3 arcsec/yr
  and Arcturus 2.3, so a century-scale jump misplaces the fastest movers by
  arcminutes. Every naked-eye star stays well within a pixel over a few decades
  at any field this app draws.
- **Also not modelled**: nutation (up to 17 arcsec in longitude) and annual
  aberration (up to 20 arcsec). Both are an order of magnitude below one pixel
  at any field of view offered. The IAU 2006/P03 refinement differs from IAU
  1976 by well under an arcsecond across 1800-2050.

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

## Constellation abbreviations and genitives — `Core/Models/ConstellationDesignations.swift`

- **Source**: the IAU's list of the 88 constellations
  (https://www.iau.org/public/themes/constellations/), which is normative for
  the Latin nominative, the Latin genitive and the three-letter abbreviation.
- **Use**: two things depend on it.
  - **Constellation search.** `constellation_names.json` carries only the
    nominative, so "Ori" and "UMa" — the abbreviations the HYG catalogue uses
    and that appear inside every Bayer designation — would otherwise find
    nothing. Matches are ranked (whole name or exact abbreviation first, then
    prefix, then interior substring) because "UMa" is also a substring of
    "TriangUlum AUstrale", and an unranked filter offers that one first.
  - **Bayer designations spelled out.** A star's designation is stored as
    "9Alp CMa" but is *read* as "Alpha Canis Majoris", which needs the
    genitive. Search accepts the raw form, the abbreviation form, the Greek
    character ("α CMa") and the spelled-out genitive form.
- **Note**: Boötes is spelled with the diaeresis to match
  `constellation_names.json`; search folds diacritics, so "Bootes" finds it.

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

### The sky below the horizon (the see-through-Earth view)

The app draws the whole celestial sphere, including the half the ground is in
the way of. Applying the observer's own daylight sky brightness to those
directions is wrong in a specific, correctable way, and
`SkyBrightness.effectiveSunAltitudeDegrees` corrects it.

**Daylight is an atmospheric foreground.** The blue glow that drowns out stars
is sunlight scattered by air *along the line of sight*. A sightline aimed below
the horizon never traverses that illuminated air — it goes down through the
ground and emerges somewhere else on Earth, quite possibly on the night side.

The geometry is exact and elementary. An observer on a sphere of radius R
looking at depression |a| sends a chord into the sphere; the chord meets the
inward radius at 90° - |a|, the triangle observer-centre-exit is isoceles, so
the central angle is **2|a|**. The sightline therefore leaves the Earth a
great-circle distance 2|a| away, reaching the exact antipode at a = -90°.
Displacing an observer by great-circle distance d changes the Sun's altitude h
by sin h' = sin h cos d + cos h sin d cos(psi); the app has no reason to prefer
a bearing psi and the azimuth-average of the second term is zero, so the model
keeps the first term:

    sin h' = sin h cos(2|a|)

continuous at the horizon (d = 0 gives h' = h) and exact at the antipode
(d = 180° gives h' = -h). The displayed value is then `min(h, h')` — the
*darker* of the two hemispheres — because the mechanism only ever removes a
foreground: a sightline through the Earth can never be dimmed by daylight it
does not pass through. Consequences:

- **By day**, sub-horizon directions get the night-side limit, so the dark
  hemisphere shows the depth that is physically there behind the rock.
- **At night**, the far end is the *day* hemisphere, so the minimum keeps the
  observer's own dark sky and nothing regresses.
- **Above the horizon**, it is the observer's own value, unchanged.

No arbitrary magnitude bonus is added anywhere; the aesthetic field-of-view
limit (`StarAppearance.limitingMagnitude`) still caps everything, which is why
the effect is modest at a whole-sky field and large when zoomed in. Measured
against the bundled catalogue at latitude 37.5°N, camera 45° below the horizon:
at a 90° field 522 -> 569 drawn stars, at a 25° field 33 -> 81. Above the
horizon and at night the counts are byte-identical to before.

The same view drives the satellite layer: everything orbiting the dark
hemisphere is drawn by default rather than behind "Show all", still dimmed by
terrain coverage. To keep that affordable, `SkyGeometryBuilder.buildSatellites`
first applies an exact cheap necessary condition — angular separation is at
least the difference of altitudes, so anything further than the viewport radius
in altitude alone cannot project into the frame — using the altitude already
carried in each sample, before any trigonometry.

## Planetary radii — `StarAppearance.angularDiameterDegrees`

- **Source**: NASA/GSFC Planetary Fact Sheets (mean equatorial radii, in km).
  Pluto's 1188.3 km is the IAU value from the New Horizons flyby. It is
  carried for completeness only: at 30+ AU Pluto's disk is about 0.1", far
  below any field of view the app offers, so the marker floor always wins.
- **Use**: apparent angular diameter is computed as `2·atan(r / d)` where `d`
  is the geocentric distance from the ephemeris, so disks grow and shrink
  correctly as a planet approaches or recedes. A documented
  minimum-visualization size keeps bodies clickable at wide field.
- **Limitations**: Saturn's ring tilt is a fixed tasteful approximation, not
  computed from true ring-plane geometry; oblateness is ignored (equatorial
  radius used as a sphere); no limb darkening; procedural banding on Jupiter
  is decorative, not a map of real belts and zones.

## Deep-sky catalogue — `Data/Catalogs/deepsky.json`

- **Source**: [OpenNGC](https://github.com/mattiaverga/OpenNGC), a machine-
  readable revision of the New General Catalogue and Index Catalogue.
- **Author / attribution**: Mattia Verga.
- **Licence**: Creative Commons Attribution-ShareAlike 4.0 International
  (CC BY-SA 4.0) — the same licence family as the bundled star and
  constellation data.
- **Contents**: 909 objects — 342 galaxies, 344 open clusters, 115 globular
  clusters, 55 planetary nebulae, 48 diffuse nebulae, 5 supernova remnants.
  All 111 Messier objects are included.
- **Selection rule**: every Messier object, plus any other OpenNGC object
  brighter than magnitude 11 that has a recorded angular size. Objects with no
  size could not be drawn at their true extent, which is the entire point of
  the layer.
- **Conversion**: `ra` and `dec` are J2000 in **degrees**, converted from
  OpenNGC's sexagesimal columns. `positionAngleDegrees` is the orientation of
  the **major axis, measured east of north** (the standard astronomical
  position-angle convention); the renderer converts it into the current screen
  frame by projecting a second point offset along that angle. Entries are
  sorted magnitude-ascending. Any of `majorAxisArcmin`, `minorAxisArcmin` and
  `positionAngleDegrees` may be `null`, in which case the object is drawn as a
  circle at the minimum visualisation size.
- **Dark nebulae** are dropped at load time. They are absorption features with
  no light of their own; drawing them as bright blobs would be actively wrong.
  (The selection rule above produced none in practice.)
- **One deliberate reclassification**: OpenNGC types clusters with nebulosity
  as `Cl+N`, which the conversion collapsed to `openCluster`. Three of those —
  M42, IC 2944, IC 5146 — are dominated visually by their nebulosity, so
  `DeepSkyObject.renderType` promotes any `openCluster` whose common name
  contains "Nebula" back to `nebula`. Keyed off the catalogue's own name field,
  no hand-written coordinates.

### How deep-sky objects are drawn

- **Size**: `majorAxisArcmin / 60 × pointsPerDegree`, with the same
  `pointsPerDegree = viewportWidth / fieldOfViewDegrees` the planets use,
  smooth-blended (`smoothMax`) against a 9 pt minimum so a small distant galaxy
  stays visible and clickable at a wide field. M31's 2.96° spans ~5% of the
  screen width at a 60° field.
- **Shape**: an ellipse inscribed in the square point sprite, squashed by
  `minorAxisArcmin / majorAxisArcmin` (floored at 0.12) and rotated to the
  screen-space direction of the position angle. Falls back to a circle when
  either the axes or the position angle are missing.
- **Appearance**: entirely procedural — no imagery, no textures. Galaxies are a
  soft elongated haze with a brighter core; globulars a concentrated core with
  a granular outskirt; open clusters a very faint circular haze only (their
  real member stars already come from the star catalogue, so anything stronger
  would double-draw them); nebulae a lumpy diffuse glow; planetaries a small
  fuzzy dot that grows a ring with zoom. Tints are close to white by design —
  deep-sky objects are colourless to the eye — with only a restrained cool cast
  on planetaries and a warm one on emission nebulae.
- **Visibility — APPROXIMATION**: deep-sky objects go through exactly the same
  `StarAppearance.visibility` path as the stars (no planet-style exemption),
  but with two documented modifications.
  1. *Surface-brightness bias*. Naked-eye detectability of an extended object
     is set by surface brightness, not integrated magnitude. The true mean
     surface brightness `m + 2.5·log10(area)` is not on the same scale as
     stellar magnitudes, so instead a bounded fraction of it is added:
     `penalty = clamp(0.5 × 2.5 × log10(area / 50 arcmin²), 0, 1.2)`. Objects
     under ~50 arcmin² are unpenalised; the 1.2-magnitude cap is an aesthetic
     choice, not physics, and exists so that M31 (3.44 → 4.64) and M45
     (1.2 → 2.4) survive a wide field on a dark night while a magnitude 9
     galaxy still needs zoom.
  2. *Twilight suppression*. The star path floors its daylight contrast at 0.72
     so the constellations stay legible under a bright sky. That convention is
     right for point sources and wrong for low-surface-brightness smears, so
     deep-sky objects are additionally multiplied by a factor that is 0 while
     the Sun is above −2° and reaches 1 by −12°.
- **Consequence worth knowing**: the drawn magnitude limit tops out at 9.0 (the
  star catalogue's completeness limit), so catalogue entries fainter than that
  never appear at any zoom. They are still searchable and selectable.

## Milky Way panorama — `Rendering/Resources/milkyway_panorama.jpg`

- **Source URL**: https://www.eso.org/public/images/eso0932a/ (image page),
  file downloaded from https://cdn.eso.org/images/publicationjpg/eso0932a.jpg
- **Title**: "The Milky Way panorama", from ESO's GigaGalaxy Zoom project.
- **Credit / attribution (must be preserved)**: **ESO/S. Brunier**.
- **Licence**: Creative Commons Attribution 4.0 International (CC BY 4.0).
  ESO's terms (https://www.eso.org/public/copyright/) place all images on the
  public ESO website under CC BY 4.0 "unless specifically noted"; the eso0932a
  page carries no such note, and third-party credits such as S. Brunier are
  cleared for reuse provided the credit line is reproduced unaltered. Only the
  800-megapixel *original* is withheld for copyright reasons; the published
  web-resolution versions used here are not.
- **Format**: 4000 x 2000 equirectangular (2:1), 4.9 MB JPEG, used as
  downloaded — no re-encoding, no crop.
- **Projection and orientation**: equirectangular in **galactic** coordinates,
  centred on the galactic centre (l = 0 at the horizontal centre, b = +90 at
  the top edge). Galactic longitude increases to the **left**. That sign was
  not assumed: it was verified by sampling the image at the catalogued
  positions of the Large (l = 280.5, b = -32.9) and Small (l = 302.8,
  b = -44.3) Magellanic Clouds, which land on the two obvious bright patches
  in the lower right under this convention and on empty sky under the other.
- **How it is used**: sampled per pixel in the background fragment shader
  through the *existing* equatorial→galactic rotation
  (`GalacticCoordinates.equatorialToGalactic`), added to the sky rather than
  replacing it, and passed through the same envelope the analytic band always
  used — it only appears once the Sun is below about -8 deg, fades out as you
  zoom in past a ~40 deg field, and fades out near the horizon. It is scaled to
  0.30, gamma-shaped (1.35, which deepens the dust lanes) and pulled 45% toward
  neutral, because the panorama is a 120-hour long exposure and shows far more
  light and colour than a dark-adapted eye ever does.
- **Fallback**: if the resource is missing or fails to decode, the shader keeps
  the original analytic Milky Way band. Both paths are still in `Shaders.metal`.
- **Limitations**: the panorama is a photographic mosaic, so it carries its own
  star field, which is added faintly on top of the catalogue-drawn stars (they
  are in the same places, so this reads as bloom rather than as doubling). The
  image is loaded without sRGB decoding, which is a deliberate simplification —
  the layer is a subtle additive wash, not a colour-managed reproduction.

## Planetary surface maps — `Rendering/Resources/*_map.jpg`

Three bodies carry a real photographic/cartographic surface map, sampled in the
point-sprite fragment shader and faded in with zoom. **Every bundled image is a
US Government work and is not subject to copyright in the United States.** The
licence of each was checked on its own hosting page rather than assumed —
"NASA" is not by itself a licence, since NASA hosts some third-party
copyrighted imagery.

### Mars — `mars_map.jpg`

- **Source page**: <https://astrogeology.usgs.gov/search/map/mars_viking_colorized_global_mosaic_232m>
  ("Mars Viking Colorized Global Mosaic 232m", MDIM 2.1), USGS Astrogeology
  Science Center, Astropedia. Downloaded from that page's 1024-pixel sample.
- **Credit**: U.S. Geological Survey / Department of the Interior; originator
  NASA Ames Research Center; derived from Viking Orbiter imagery.
- **Terms**: the Astropedia product page carries no per-product licence text.
  The governing statement is the USGS copyright policy at
  <https://www.usgs.gov/information-policies-and-instructions/copyrights-and-credits>:
  *"USGS-authored or produced data and information are considered to be in the
  U.S. Public Domain."* The same page notes that not all content on USGS sites
  is public domain and asks for the credit line
  *"Credit: U.S. Geological Survey / Department of the Interior/USGS."* The
  originator here is a NASA centre, so both halves are US Government work.
- **Projection**: Simple Cylindrical (equirectangular), planetocentric
  latitude, **+East longitude, -180 to +180**.

### Jupiter — `jupiter_map.jpg`

- **Source page**: <https://science.nasa.gov/photojournal/cassinis-best-maps-of-jupiter-cylindrical-map/>
  (PIA07782), NASA Photojournal.
- **Credit**: NASA / JPL / Space Science Institute. Assembled from Cassini
  narrow-angle camera images taken during the 2000 Jupiter flyby.
- **Terms**: the individual page states no licence. The governing NASA media
  policy at <https://www.nasa.gov/nasa-brand-center/images-and-media/> says
  NASA content — explicitly including *"texture maps and polygon data in any
  format"* — *"generally are not subject to copyright in the United States"*,
  and that third-party material *"will be marked identified as copyright
  protected with the name of the copyright holder."* PIA07782 carries no such
  mark. This is a site-wide policy plus an absence of a copyright mark rather
  than an explicit per-image grant, which is worth stating plainly.

### Moon — `moon_map.jpg`

- **Source page**: <https://svs.gsfc.nasa.gov/4720/> ("CGI Moon Kit"), NASA's
  Scientific Visualization Studio. File `lroc_color_2k.jpg`.
- **Credit**: NASA's Scientific Visualization Studio (visualiser Ernie Wright,
  USRA; scientist Noah Petro, NASA/GSFC), from the LROC Wide Angle Camera
  Hapke-normalised colour mosaic.
- **Terms**: this is the most explicit of the three. The SVS usage page
  <https://svs.gsfc.nasa.gov/help/> states: *"All of our content is in the
  public domain (unless otherwise noted), meaning that it is free to download,
  use, and redistribute for whatever purposes you see fit."* The page's only
  carve-out concerns licensed **music** in some visualisations; item 4720
  carries no such note.

### Sizes, and why these three and no others

- Every map is resampled (Lanczos) to **1024 x 512** and saved as JPEG at
  quality 88. Total added to the bundle: **338 KB** — Mars 123 KB, Moon 120 KB,
  Jupiter 95 KB.
- 1024 x 512 is sized against the *renderer*, not the source. A planet's
  rendered disk is capped at 260 points (`StarAppearance.maximumPointSize`), it
  shows one hemisphere, and a hemisphere is half the map's width — so 512
  texels across roughly 520 backing pixels on a Retina display is close to one
  texel per pixel at maximum zoom. The full USGS Mars product is 92,160 pixels
  wide and 12 GB; none of that detail is reachable here.
- **Venus and the ice giants are deliberately untextured.** They are featureless
  in visible light. The only public-domain Venus mosaic is Magellan's *radar*
  topography, synthetically colourised — painting that on the disk would show
  the user a surface no telescope can see, which is worse than showing nothing.
- **Mercury is deliberately untextured.** Its only public-domain global mosaic
  (MESSENGER MDIS) is *enhanced* colour, which is intentionally false colour
  and would render Mercury blue and tan.
- **Saturn is deliberately untextured.** No public-domain global colour map of
  Saturn could be verified. It keeps its procedural golden disk and rings.
- Creative-Commons-licensed texture packs (notably Solar System Scope, CC BY
  4.0) would have covered all of these. They were not used: they carry an
  attribution obligation this app has no acknowledgements pane to discharge,
  and their own page notes that gaps in the source data are *"filled with
  fictional terrain"* — which is precisely the thing that must not be presented
  as a planet's real appearance.

### How the map is applied — and what is and is not accurate

- The disk sprite is treated as the orthographic projection of the visible
  hemisphere. The shader lifts each sprite pixel back onto the sphere, reads
  latitude and longitude in the body's own frame, and samples the
  equirectangular map (`surfaceModulation` in `Shaders.metal`).
- The map is applied as a **modulation of the flat tint**, not as a replacement
  for it: the sample is divided by the map's measured mean colour, so it
  contributes structure and local colour departure while the app's palette
  keeps control of the body's overall hue. Two consequences worth stating: Mars
  cannot be dragged toward a garish red by the texture, and at zero detail the
  modulation mixes out to *exactly* the previous flat-disk appearance, so the
  fade-in is continuous by construction.
- It is faded in by the existing `StarAppearance.detailLevel` ramp (zero below
  16 points across, full at 52), so a wide field is a clean tinted dot and no
  detail ever pops into existence.
- **Orientation is computed, not assumed.** `Core/Astronomy/PlanetaryOrientation.swift`
  derives the sub-Earth longitude and latitude and the pole direction from
  published rotation elements, so the hemisphere facing you is the real one and
  Mars's polar cap tips toward and away from Earth with its seasons. Source:

  > Archinal, B. A., Acton, C. H., A'Hearn, M. F., Conrad, A., Consolmagno,
  > G. J., Duxbury, T., Hestroffer, D., Hilton, J. L., Kirk, R. L., Klioner,
  > S. A., McCarthy, D., Meech, K., Oberst, J., Ping, J., Seidelmann, P. K.,
  > Tholen, D. J., Thomas, P. C., and Williams, I. P. (2018), "Report of the
  > IAU Working Group on Cartographic Coordinates and Rotational Elements:
  > 2015", *Celestial Mechanics and Dynamical Astronomy* **130**, 22.
  > DOI [10.1007/s10569-017-9805-5](https://doi.org/10.1007/s10569-017-9805-5).

  Values cross-checked against NAIF's `pck00011.tpc`, which encodes that
  report. Note these are the **2015** elements; older code and older kernels
  carry a superseded 2009 set (Mars pole at 317.68143, 52.88650).
- **Approximations, stated plainly:**
  - Only the **linear** terms of each IAU expression are used — the pole's
    secular drift and the uniform rotation of the prime meridian. The
    trigonometric nutation terms are dropped; they are at the 0.001-degree
    level for Mars and Jupiter, far below one pixel.
  - For the **Moon** the dropped terms are the *physical* libration. The
    **optical** libration — the +/- 8 degrees that actually reveals the limb
    regions — is reproduced, because the sub-Earth point is computed from the
    Moon's true geocentric direction rather than a mean one. Residual error is
    a few hundredths of a degree. A test asserts the Moon keeps the same face
    turned toward Earth over two months, which is the strongest available check
    on the whole construction.
  - **Jupiter's longitude origin is the weakest link.** The prime meridian used
    is IAU **System III** (the magnetic field's rotation), which is the standard
    reference — but Jupiter has no solid surface and its visible cloud features
    drift relative to any fixed system by degrees per month. The Cassini map's
    own longitude registration is also taken on trust. The **belts and zones are
    at the right latitudes**; the longitude of the Great Red Spot should not be
    treated as truthful.
  - The IAU pole is J2000 and the ephemeris is of-date, so the pole is precessed
    forward with the app's existing `Precession` before use rather than the two
    frames being silently mixed.
  - Light-time and aberration are not applied to the rotation phase. For Mars
    that is at most about 20 minutes of light time, i.e. ~5 degrees of
    longitude at closest approach — visible if you were measuring, not if you
    are looking.
  - **Not visually verified.** The shader's mapping was derived and reasoned
    through but could not be seen running in this environment, so the
    east/west handedness of the rendered disk in particular is unconfirmed by
    eye.

## Planet and star colours — `Rendering/SkyRenderer/StarAppearance.swift`

- **Star colours** are derived from the HYG catalogue's B-V colour index
  through a piecewise-linear ramp, deliberately pulled toward white because
  colour vision is barely engaged at naked-eye star brightnesses. The ramp was
  reviewed rather than rewritten; a test now pins the properties that make it
  physical (red never falls and blue never rises as B-V increases, and neither
  extreme reaches a saturated hue).
- **Planet tints** are the bodies' real appearance rather than marker colours:
  Mercury grey, Venus pale cream-white, **Mars a muted ochre (0.86, 0.59,
  0.44)**, Jupiter warm tan, Saturn pale gold, Uranus pale cyan, Neptune a
  deeper blue. Mars is the one worth calling out: its integrated colour is
  closer to butterscotch or dried terracotta than to red, and
  `StarAppearance.marsSaturationRange` pins the allowed saturation band so a
  later edit cannot quietly turn it into a stoplight.

## Glow / aura model — `StarAppearance.aura`

Not a data source, but a modelling choice worth recording. The halo behind a
solar-system body is derived from *measured* quantities — the body's apparent
magnitude and the diameter it is actually being drawn at — rather than
hard-coded per body, so Mars near opposition genuinely blooms more than Mars
near conjunction, Venus always outshines everything, and Uranus and Neptune get
no halo at all (a halo on a telescopic object would be a false claim about how
it looks). The alpha is linear in magnitude, i.e. logarithmic in flux, with no
constant term so it starts at exactly zero at the threshold; the size is a
multiple of the disk smooth-minned against a bounded offset from it, so it stops
growing rather than swallowing the frame; and every aura dissolves as the disk
resolves — hardest for the Moon, whose terminator it must not wash out. The
halo colour is the body's tint pulled part-way to white, since a halo covers far
more pixels than the disk and drawing it at full saturation is what would turn a
subtle ochre Mars into a red smear.

## Satellite element sets — `Astronomy/Data/Catalogs/satellites.txt`

- **Source**: [CelesTrak](https://celestrak.org) GP element sets, the `active`
  group in TLE format
  (`https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle`).
  CelesTrak is maintained by Dr T.S. Kelso and has redistributed this data
  since 1985.
- **Underlying data**: the orbital elements themselves originate with the
  US Space Force's 18th/19th Space Defense Squadron and are published through
  Space-Track. As a work of the US Government they are not subject to
  copyright in the United States.
- **License — stated honestly**: **no explicit license statement could be
  found on CelesTrak's pages.** The underlying element sets being public-domain
  US Government work is the basis on which they are bundled here; the CelesTrak
  attribution is a courtesy, not a licence obligation being discharged. If
  CelesTrak later publishes terms that conflict with this use, this file and the
  bundled snapshot should be revisited. The attribution is shown in the app's
  footer line alongside the ESO and catalogue credits.
- **Politeness measures**, because CelesTrak explicitly dislikes abusive
  clients and rate-limits them:
  - the app polls **at most once per day**, enforced in
    `SatelliteCatalogService.minimumRefreshInterval` by comparing the cache
    file's modification date before any request is made;
  - every request carries a descriptive `User-Agent`
    (`Astronomy-macOS-Planetarium/1.0 (satellite tracking; TLE refresh once per day)`);
  - a response that does not parse as element sets is discarded rather than
    written over a working cache, so a rate-limit page cannot poison it.
- **Fallback sources**, added after CelesTrak proved to be unreachable for
  days at a time (DNS resolved, TCP to port 443 timed out) and the app quietly
  ran off its bundled snapshot until every satellite aged out of the accuracy
  window and vanished. One source is not a supply chain. Both of these were
  fetched and checked before being added — they parse as TLEs and carry current
  epochs, including the ISS:
  - **[SatNOGS DB](https://db.satnogs.org)** (`/api/tle/?format=json`), the
    open SatNOGS ground-station network's element-set API: about 1,700 objects,
    mostly Space-Track-derived, served as JSON and converted to TLE text.
    SatNOGS is a Libre Space Foundation project and its DB data is openly
    published.
  - **[AMSAT](https://www.amsat.org/tle/current/nasabare.txt)**, the ~100
    amateur-radio objects, in plain NASA two-line format.
  - **Space-Track is deliberately not used.** It is the authoritative source,
    but it requires an account, and shipping credentials inside an app is not
    something this app will do.
  Both fallbacks are *partial*, so they never replace the catalogue: they are
  written to `satellites-supplement.txt` and overlaid onto it by catalogue
  number, and only where their epoch is genuinely newer. Falling back therefore
  costs the user nothing.
- **Targeted fallback source — a third-party mirror**:
  **[TLE API](https://tle.ivanstanojevic.me/), by Ivan Stanojevic**
  (`https://tle.ivanstanojevic.me/api/tle/`). Added on 2026-08-26, when
  CelesTrak had been unreachable from this machine for days (DNS resolved, TCP
  to port 443 timed out, retried repeatedly with and without the app's
  User-Agent) and the two existing fallbacks between them covered only about
  1,400 of 16,000 objects.
  - **What it is**: a *mirror*, not an authority. It republishes the same
    Space-Track element sets as everything else here. The underlying orbital
    data is a work of the US Government and is not subject to copyright in the
    United States, which is the basis on which it is used. **The mirror itself
    publishes no licence statement**, so — exactly as with CelesTrak above —
    no licence is being claimed on its behalf. The credit to Ivan Stanojevic
    is a courtesy.
  - **How it is used at runtime**: only for **targeted, single-object lookup**
    (`/api/tle/25544`), and only after every bulk source has failed. It *can*
    serve the whole catalogue, but at 100 objects per request that is 257
    requests, which is far too rude for something on a timer. Instead the app
    spends at most 40 requests — the curated notable list — spaced 0.4 seconds
    apart, so the objects a user is actually likely to look at stay current
    through a long CelesTrak outage. `maximumTargetedRequests` exists
    specifically so this can never drift into being a bulk download, and a test
    asserts it. Results go into the same `satellites-supplement.txt` overlay,
    under the same newer-epoch-wins rule.
  - **How it was used once, offline**: the same API supplied the regenerated
    bundled snapshot below. That was a deliberate one-off — 257 requests with a
    descriptive User-Agent, a delay between each, retry on transient failure,
    and an immediate stop on any rate-limit response.
- **Snapshot bundled**: **16,348 element sets, 2.5 MB**, regenerated on
  2026-08-26.
  - **Provenance**: the full catalogue was pulled from the TLE API mirror above
    (25,675 records covering 17,336 distinct objects — the API serves each
    object's element-set *history*, so only the newest per catalogue number was
    kept) and **merged into**, not substituted for, the existing snapshot,
    newest-epoch-wins by catalogue number.
  - **What the merge did**: 10,032 objects refreshed, 123 new objects added,
    1,023 mirror records rejected as *older* than what was already bundled, and
    **5,170 objects the mirror does not carry kept at their existing elements**
    rather than dropped. Every record was validated before being written:
    parses as a TLE, both line checksums correct, catalogue numbers agree
    between the two lines, mean motion and eccentricity physically plausible,
    and catalogue numbers unique across the file.
  - **What was deliberately left out**: the mirror carries a long tail of
    decayed and inactive objects whose element sets are years old (its worst is
    over eighteen years). CelesTrak's `active` group excludes those on purpose,
    and importing 6,158 of them would have filled the sky with satellites that
    are not up there any more. Objects unknown to the existing snapshot were
    therefore imported only if their elements were under 30 days old.
  - **Epoch age, before and after** (measured against the build date):

    | | objects | median | mean | p90 | max |
    |---|---|---|---|---|---|
    | before | 16,225 | 8.22 d | 7.71 d | 8.83 d | 31.1 d |
    | after | 16,348 | **1.61 d** | 3.46 d | 8.48 d | 31.1 d |

    The remaining tail is almost entirely the 5,170 objects only CelesTrak
    publishes. The ISS is at 0.34 days.
  - Bundling any of this at all is what lets the app work with no network,
    the same promise the star catalogue makes.
- **Refresh and caching**: a fresh full copy is written to
  `~/Library/Application Support/Astronomy/satellites.txt` and preferred over
  the bundle on subsequent launches. The refresh is attempted **repeatedly
  within a session**, not once per launch: a failure retries after a minute,
  doubling to a ceiling of half an hour, so a transient outage heals without a
  restart, while a *success* resets to the polite one-a-day floor. A failure
  leaves the previous elements in place, and — unlike before — says so in the
  satellite control, because a failure only a log ever sees is a failure nobody
  ever fixes. A network failure can never break the sky.
- **Regime breakdown** of the bundled snapshot, as classified by
  `OrbitalRegime.classify`: **15,409 LEO, 183 MEO, 590 GEO, 43 highly
  elliptical**. Of these, **808 have orbital periods of 225 minutes or more**
  and are propagated through the deep-space (SDP4) branch of the model.

### Accuracy, and its real limits

Satellite positions come from **SGP4/SDP4**, the analytical model that TLEs are
*defined* against. The implementation in `Core/Astronomy/SGP4/` is a faithful
port of David Vallado's public-domain reference `SGP4.cpp` (version 2020-07-13,
companion code to Vallado, Crawford, Hujsak & Kelso, "Revisiting Spacetrack
Report #3", AIAA 2006-6753, itself descended from Hoots & Roehrich, Spacetrack
Report No. 3, 1980). It is verified against the standard `SGP4-VER.TLE` set to
sub-millimetre agreement with the reference; see `AstronomyTests`.

What remains approximate, in decreasing order of how much it matters:

- **Element-set age dominates everything else.** A TLE is a snapshot, and SGP4's
  drag model is a coarse one. A LEO element set accumulates on the order of
  kilometres of along-track error per day, so a week-old set can place the ISS
  a noticeable distance along its own track — visible as the pass happening a
  few seconds early or late. This is a property of the data, not of the
  implementation, and no amount of care in the propagator removes it. The app
  surfaces the age directly, and grades it (`ElementSetStaleness`):
  - **up to 2 days — fresh.** A few kilometres at worst, which at ~7.7 km/s is
    well under a second of pass timing and a few tenths of a degree on the sky.
    Shown with no warning, because there is nothing worth warning about.
  - **2 to 10 days — aging.** Of order 10–30 km along-track: seconds of timing
    error, and up to a few degrees at a close overhead pass. Drawn, and labelled
    "aging" with that consequence spelled out.
  - **beyond 10 days — unreliable.** Tens to hundreds of kilometres, growing
    non-linearly; a pass may be minutes early or late. The orbital *plane* is
    still about right, so the track still means something, but the position
    along it does not. Drawn, and plainly flagged.

  Select a satellite and the info panel shows "Element set: 7.7 days old —
  aging" with the caveat underneath; the satellite control says the same thing
  about the catalogue as a whole. Treat that number as the accuracy caveat it
  is.

  **This is also a hard limit on the time machine, and the app enforces it.**
  Beyond about a week the along-track error stops being a caveat and becomes the
  whole answer: at one month it is hundreds to thousands of kilometres, meaning
  the object is *somewhere in its orbital plane* and the propagator has no idea
  where. That is not imprecise, it is meaningless — a drawn position would be
  indistinguishable from a random point on the ground track. So
  `SatelliteAccuracy.maximumElementSetAgeDays` = **5 days**, symmetric about the
  epoch, and outside it the satellite is **not drawn at all** — not dimmed, not
  flagged, absent. The satellite layer is suppressed in the renderer and in
  search alike, and the time bar states the reason in place of leaving the user
  to wonder where the satellites went. Silently propagating months out and
  presenting the result as real would be the single most dishonest thing this
  app could do.

  **That refusal is about the time machine, not about aging data.** The two
  cases are different and are now treated differently. Within
  `SatelliteAccuracy.realTimeWindowDays` = **5 days** of *real* time the user is
  looking at a sky they can check against the one outside, so satellites are
  always drawn whatever the age of the elements — with the staleness stated,
  never passed off as precision. It is only when the displayed instant is far
  from **both** real time and the element epoch that nothing is drawn.
  `SatelliteAccuracy.isDrawable` is that single gate, and both halves of it are
  pinned by tests.
- **Atmospheric drag** is modelled by SGP4's `B*` term, a single fitted
  coefficient. It does not know about solar activity, the satellite's attitude,
  or a manoeuvre. Objects that manoeuvre (the ISS reboosts; Starlink raises
  orbit continuously) invalidate their elements sooner than the drag model
  alone would suggest.
- **TEME frame handling.** SGP4 emits positions in TEME (True Equator, Mean
  Equinox of date). `TopocentricTransform` rotates the observer into that frame
  using Greenwich *Mean* Sidereal Time, which is the standard practice for TEME.
  Strictly, TEME's origin of right ascension differs from the true equinox by
  the equation of the equinoxes, up to about 1.1 seconds of time (~16
  arcseconds). That is four orders of magnitude below the element-set error
  above, and it is noted in the code rather than silently ignored.
- **Observer height** is assumed to be sea level on the WGS-84 ellipsoid; the
  app does not know the user's elevation. A few hundred metres of elevation is
  negligible against a target hundreds of kilometres away. The ellipsoid itself
  is *not* an approximation that could be skipped: a spherical Earth would be
  wrong by up to 21 km, which for a 400 km target is degrees of mispointing.
- **No apparent magnitude.** The element-set catalogue carries no photometry,
  and a satellite's brightness depends on its attitude and phase angle in ways
  two lines of orbital elements cannot express. The app therefore reports no
  magnitude for a satellite rather than inventing one. What it *does* report is
  whether the object is in sunlight, computed from a conical umbra/penumbra
  test against the Sun direction — which is the thing that actually determines
  whether you could see it.
