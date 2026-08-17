//
//  AstronomyApp.swift
//  Astronomy
//
//  Created by Shubhi Srivastava on 8/17/26.
//

import SwiftUI
import SwiftData

@main
struct AstronomyApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SavedLocation.self,
            UserPreference.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            SkyView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)
    }
}
