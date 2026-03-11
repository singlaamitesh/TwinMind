//
//  ContentView.swift
//  TwinMind
//
//  Root view hosting the tab-bar navigation.
//  • Record tab  — RecordingView
//  • History tab — SessionListView
//

import SwiftUI

struct ContentView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            RecordingView()
                .tabItem {
                    Label("Record", systemImage: "mic.fill")
                }
                .badge(appState.isRecording ? "●" : nil)

            SessionListView()
                .tabItem {
                    Label("History", systemImage: "list.bullet")
                }
        }
        // Surface any global error at root level
        .overlay(alignment: .bottom) {
            if let error = appState.errorMessage {
                ErrorBanner(message: error) {
                    appState.errorMessage = nil
                }
                .padding(.bottom, 90)   // above tab bar
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.4), value: appState.errorMessage)
            }
        }
    }
}
