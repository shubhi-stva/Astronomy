//
//  CommandPaletteModel.swift
//  Astronomy
//
//  State for the ⌘K palette, deliberately kept off the view model.
//
//  This is the single most performance-sensitive structural decision in the
//  feature, and it comes straight out of this project's own history. With
//  `@Observable`, a view body depends on exactly the properties it *reads*.
//  The label overlay once lagged the sky by a visible fraction of a second
//  because `SkyView`'s body read a property that changed every frame, which
//  made the whole screen — including the Metal representable — re-evaluate at
//  display rate (see `SkyLabelsLayer`).
//
//  A palette's `query` changes on every keystroke and its `commands` array is
//  rebuilt each time. If either lived on `SkyViewModel`, every character typed
//  would invalidate anything reading that view model — which is the entire
//  chrome and the sky view with it. Here, the only body that reads these
//  properties is the palette's own, so typing costs one small subtree.
//

import CoreLocation
import Foundation
import Observation

@Observable
@MainActor
final class CommandPaletteModel {

    /// Whether the palette is on screen. The one property outside this file's
    /// views that anything else may read, and it changes twice per use.
    private(set) var isPresented = false

    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            if isLocationMode { scheduleGeocode() }
            selectedIndex = 0
        }
    }

    /// The ranked rows, rebuilt by `refresh(context:)`.
    private(set) var commands: [PaletteCommand] = []
    /// Keyboard cursor. Always in range of `commands`, or zero when empty.
    private(set) var selectedIndex = 0

    /// True once "Set location…" has been chosen: the query is now a place
    /// name being geocoded rather than a command being matched.
    private(set) var isLocationMode = false
    private(set) var placeMatches: [PaletteContext.Place] = []
    private(set) var isGeocoding = false

    private let geocoder = CLGeocoder()
    private nonisolated(unsafe) var geocodeTask: Task<Void, Never>?

    /// How long the palette waits after the last keystroke before asking the
    /// geocoder. CoreLocation's geocoder is rate-limited by Apple and will
    /// start refusing requests if hit on every character; a third of a second
    /// is below the threshold at which typing feels laggy.
    static let geocodeDebounce: Duration = .milliseconds(300)

    /// The shortest place query worth sending. Two characters match most of the
    /// planet and waste a rate-limited request.
    static let minimumPlaceQueryLength = 3

    // MARK: - Presentation

    func present() {
        isPresented = true
        query = ""
        isLocationMode = false
        placeMatches = []
        selectedIndex = 0
    }

    func dismiss() {
        isPresented = false
        query = ""
        commands = []
        isLocationMode = false
        placeMatches = []
        geocodeTask?.cancel()
    }

    /// Esc backs out of location mode before it closes the palette, so a
    /// mis-typed place name costs one keystroke rather than a reopen.
    func escape() {
        if isLocationMode {
            isLocationMode = false
            query = ""
            placeMatches = []
            geocodeTask?.cancel()
            selectedIndex = 0
        } else {
            dismiss()
        }
    }

    func beginLocationEntry() {
        isLocationMode = true
        query = ""
        placeMatches = []
        selectedIndex = 0
    }

    // MARK: - Results

    /// Rebuilds the rows. The caller supplies the context, because everything
    /// expensive in it — the search index, the calendar — belongs to the view
    /// model and must not be duplicated here.
    func refresh(context: PaletteContext) {
        var context = context
        context.isLocationMode = isLocationMode
        context.placeMatches = placeMatches
        commands = CommandProvider.commands(query: query, context: context)
        selectedIndex = min(selectedIndex, max(0, commands.count - 1))
    }

    var selectedCommand: PaletteCommand? {
        commands.indices.contains(selectedIndex) ? commands[selectedIndex] : nil
    }

    /// Moves the keyboard cursor, wrapping at both ends — a list this short is
    /// faster to reach the bottom of by pressing up once.
    func moveSelection(by delta: Int) {
        guard !commands.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + commands.count) % commands.count
    }

    func select(index: Int) {
        guard commands.indices.contains(index) else { return }
        selectedIndex = index
    }

    // MARK: - Geocoding

    /// Forward geocoding for location mode.
    ///
    /// The same `CLGeocoder` the app already uses for reverse geocoding in
    /// `LocationService`, run the other way round. Failures are silent and
    /// leave the list empty, exactly as they do there: a palette that shows an
    /// error because the network is down would be worse than one that shows
    /// nothing.
    private func scheduleGeocode() {
        geocodeTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumPlaceQueryLength else {
            placeMatches = []
            isGeocoding = false
            return
        }
        isGeocoding = true
        geocodeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.geocodeDebounce)
            guard !Task.isCancelled, let self else { return }
            let placemarks = try? await self.geocoder.geocodeAddressString(text)
            guard !Task.isCancelled else { return }
            self.placeMatches = (placemarks ?? []).compactMap(Self.place(from:))
            self.isGeocoding = false
        }
    }

    /// Turns a placemark into a row, reusing `LocationService`'s naming rule so
    /// the palette and the location control describe the same place the same
    /// way.
    static func place(from placemark: CLPlacemark) -> PaletteContext.Place? {
        guard let coordinate = placemark.location?.coordinate else { return nil }
        let name = LocationService.displayName(for: placemark)
            ?? placemark.name
            ?? String(format: "%.2f, %.2f", coordinate.latitude, coordinate.longitude)
        return PaletteContext.Place(
            name: name,
            latitudeDegrees: coordinate.latitude,
            longitudeDegrees: coordinate.longitude
        )
    }
}
