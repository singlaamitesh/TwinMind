//
//  TwinMindApp.swift
//  TwinMind
//
//  Created by Amitesh Gupta on 11/03/26.
//

import SwiftUI
import SwiftData
import AppIntents

@main
struct TwinMindApp: App {

    // AppState is the single source of truth for all actors and UI state.
    @State private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Inject AppState into the SwiftUI environment.
                .environment(appState)
                // Inject the ModelContainer so @Query macros can resolve.
                .modelContainer(AppState.makeContainer())
                // Register App Shortcuts with Siri / Shortcuts.
                .onAppear {
                    TwinMindShortcuts.updateAppShortcutParameters()
                }
        }
    }
}
