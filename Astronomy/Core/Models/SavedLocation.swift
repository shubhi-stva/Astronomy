//
//  SavedLocation.swift
//  Astronomy
//
//  SwiftData persistence stub for future phases (multiple saved observing
//  locations, user preferences). Wired into the app's ModelContainer now so
//  later phases can build on it without a migration, but not yet surfaced
//  in the Phase 1 MVP UI beyond the single "current" manual-override value.
//

import Foundation
import SwiftData

@Model
final class SavedLocation {
    var name: String
    var latitudeDegrees: Double
    var longitudeDegrees: Double
    var isDefault: Bool
    var createdAt: Date

    init(
        name: String,
        latitudeDegrees: Double,
        longitudeDegrees: Double,
        isDefault: Bool = false,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.latitudeDegrees = latitudeDegrees
        self.longitudeDegrees = longitudeDegrees
        self.isDefault = isDefault
        self.createdAt = createdAt
    }
}

/// Lightweight user preference store (future: units, display toggles, etc.).
@Model
final class UserPreference {
    var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
