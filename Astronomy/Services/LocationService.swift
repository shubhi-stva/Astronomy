//
//  LocationService.swift
//  Astronomy
//
//  Resolves the observer's position for the astronomy pipeline.
//
//  On launch the service asks CoreLocation for the Mac's current location
//  (a single fix, not a continuous stream — the observer doesn't move fast
//  enough to matter for a planetarium). Until that resolves, or if the user
//  denies permission, the app falls back to a clearly-labelled default
//  location and manual lat/lon entry remains available at all times.
//

import Foundation
import CoreLocation
import Observation

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {

    /// How the value in `currentLocation` was arrived at. The UI uses this to
    /// avoid presenting the fallback as though it were the user's real place.
    enum Source: Equatable {
        /// No real fix yet — showing the default starting point.
        case fallback
        /// Waiting on CoreLocation (permission prompt or first fix).
        case resolving
        /// A real fix from CoreLocation.
        case system
        /// The user typed coordinates.
        case manual
        /// CoreLocation is unavailable: denied, restricted, or errored.
        case unavailable(reason: String)
    }

    /// The location used for all astronomy calculations. Starts at a neutral
    /// default so the sky can render immediately on launch; replaced as soon
    /// as a real fix arrives.
    private(set) var currentLocation: GeographicLocation = .fallbackObserver

    private(set) var source: Source = .fallback

    /// True once the user has typed coordinates — a late-arriving CoreLocation
    /// fix must not silently overwrite a deliberate manual choice.
    var isManualOverride: Bool { source == .manual }

    /// Human-readable place name, resolved asynchronously by reverse
    /// geocoding. `nil` until (or unless) it resolves — the UI falls back to
    /// formatted coordinates, so geocoding never blocks anything.
    private(set) var placeName: String?

    /// The observer's own time zone, resolved by the same reverse geocode that
    /// produces `placeName`.
    ///
    /// This matters as soon as the app says *when* rather than *where*. A user
    /// in California asking what the sky over Reykjavík looks like should read
    /// "sunset 22:41", Reykjavík's own clock, not 15:41 on theirs — the number
    /// is about that place. Until the geocoder answers (and whenever it
    /// cannot), this is the machine's own zone, which is right for the common
    /// case of looking at the sky where you are standing.
    private(set) var timeZone: TimeZone = .current

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private nonisolated(unsafe) var geocodeTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // Kilometre accuracy is far finer than a planetarium needs (a degree
        // of latitude is ~111 km) and avoids spinning up GPS-grade location.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        startAutomaticLocation()
    }

    deinit {
        geocodeTask?.cancel()
    }

    // MARK: - Automatic location

    /// Begins automatic location resolution. Called once at launch, and again
    /// if the user explicitly asks to return to system location.
    func startAutomaticLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            source = .resolving
            // The delegate callback below issues the fix request once the user
            // answers the prompt.
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            source = .resolving
            manager.requestLocation()
        case .denied:
            source = .unavailable(reason: "Location permission denied")
        case .restricted:
            source = .unavailable(reason: "Location access restricted")
        @unknown default:
            source = .unavailable(reason: "Location unavailable")
        }
    }

    /// Explicit "use my location again" action, clearing any manual override.
    func requestSystemLocation() {
        startAutomaticLocation()
    }

    // MARK: - Manual override

    func setManualLocation(latitudeDegrees: Double, longitudeDegrees: Double) {
        currentLocation = GeographicLocation(latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees)
        source = .manual
        resolvePlaceName()
    }

    // MARK: - Reverse geocoding

    /// Kicks off (or restarts) reverse geocoding for the current location.
    /// Failures are silent: a missing network or a rate-limited geocoder just
    /// leaves `placeName` nil and the UI showing coordinates.
    private func resolvePlaceName() {
        geocodeTask?.cancel()
        placeName = nil
        // Deliberately *not* reset to .current: the previous place's zone is a
        // better guess than the machine's for the second or two the geocode
        // takes, and resetting would make every clock in the UI flicker
        // through the local zone on each location change.
        let location = CLLocation(
            latitude: currentLocation.latitudeDegrees,
            longitude: currentLocation.longitudeDegrees
        )
        geocodeTask = Task { [weak self] in
            guard let self else { return }
            let placemarks = try? await self.geocoder.reverseGeocodeLocation(location)
            guard !Task.isCancelled, let placemark = placemarks?.first else { return }
            self.placeName = Self.displayName(for: placemark)
            self.timeZone = placemark.timeZone ?? .current
        }
    }

    /// Prefers "City, ST" (abbreviated region where CoreLocation supplies one,
    /// as it does for US states), falling back through coarser fields so
    /// remote/ocean coordinates still get something meaningful.
    static func displayName(for placemark: CLPlacemark) -> String? {
        if let locality = placemark.locality {
            if let region = placemark.administrativeArea, region != locality {
                return "\(locality), \(region)"
            }
            return locality
        }
        return placemark.administrativeArea ?? placemark.country ?? placemark.name
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // A manual choice outranks anything CoreLocation has to say.
            guard !self.isManualOverride else { return }
            switch status {
            case .authorized, .authorizedAlways:
                self.source = .resolving
                manager.requestLocation()
            case .denied:
                self.source = .unavailable(reason: "Location permission denied")
            case .restricted:
                self.source = .unavailable(reason: "Location access restricted")
            case .notDetermined:
                break // Still waiting on the user to answer the prompt.
            @unknown default:
                self.source = .unavailable(reason: "Location unavailable")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            guard !self.isManualOverride else { return }
            self.currentLocation = GeographicLocation(
                latitudeDegrees: coordinate.latitude,
                longitudeDegrees: coordinate.longitude
            )
            self.source = .system
            self.resolvePlaceName()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard !self.isManualOverride else { return }
            // Not fatal: keep the current location and let the user enter one
            // manually. Surfaced in the UI rather than swallowed silently.
            self.source = .unavailable(reason: "Couldn't determine location")
        }
    }
}
