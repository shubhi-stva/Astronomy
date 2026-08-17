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

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func setManualLocation(latitudeDegrees: Double, longitudeDegrees: Double) {
        currentLocation = GeographicLocation(latitudeDegrees: latitudeDegrees, longitudeDegrees: longitudeDegrees)
        isManualOverride = true
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
