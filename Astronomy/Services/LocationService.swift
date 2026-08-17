//
//  LocationService.swift
//  Astronomy
//
//  Wraps CoreLocation for an optional "use my location" flow, but the app
//  always supports (and defaults to, on first launch) a manual lat/lon
//  override — CoreLocation authorization is not required to use the app.
//

import Foundation
import CoreLocation
import Observation

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {

    /// The location currently used for astronomy calculations. Defaults to
    /// New York City until the user sets something else (manually or via
    /// CoreLocation).
    private(set) var currentLocation: GeographicLocation = .newYork

    /// True while a manual override is active — CoreLocation updates, if
    /// any arrive later, will not silently overwrite a manual choice.
    private(set) var isManualOverride = false

    /// Human-readable place name for `currentLocation`, resolved
    /// asynchronously by reverse geocoding. `nil` until (or unless) it
    /// resolves — the UI falls back to formatted coordinates, so geocoding
    /// never blocks anything.
    private(set) var placeName: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var geocodeTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        resolvePlaceName()
    }

    deinit {
        geocodeTask?.cancel()
    }

    func setManualLocation(latitudeDegrees: Double, longitudeDegrees: Double) {
        currentLocation = GeographicLocation(latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees)
        isManualOverride = true
        resolvePlaceName()
    }

    /// Kicks off (or restarts) reverse geocoding for the current location.
    /// Failures are silent: a missing network or a rate-limited geocoder just
    /// leaves `placeName` nil and the UI showing coordinates.
    private func resolvePlaceName() {
        geocodeTask?.cancel()
        placeName = nil
        let location = CLLocation(
            latitude: currentLocation.latitudeDegrees,
            longitude: currentLocation.longitudeDegrees
        )
        geocodeTask = Task { [weak self] in
            let placemarks = try? await location.reverseGeocoded(using: CLGeocoder())
            guard !Task.isCancelled, let self else { return }
            guard let placemark = placemarks?.first else { return }
            let name = [placemark.locality, placemark.administrativeArea ?? placemark.country]
                .compactMap { $0 }
                .first.map { locality -> String in
                    if let region = placemark.administrativeArea, region != locality {
                        return "\(locality), \(region)"
                    }
                    return locality
                }
            self.placeName = name ?? placemark.name
        }
    }

    func requestSystemLocation() {
        isManualOverride = false
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            guard !self.isManualOverride else { return }
            self.currentLocation = GeographicLocation(
                latitudeDegrees: coordinate.latitude,
                longitudeDegrees: coordinate.longitude
            )
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silently keep the current (manual or default) location — CoreLocation
        // failing is not fatal since manual entry is always available.
    }
}
