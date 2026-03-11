//
//  SettingsView.swift
//  TwinMind
//
//  • Deepgram API key management (stored in Keychain)
//  • Default audio quality picker
//  • Storage cleanup
//  • App info
//

import SwiftUI

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss)     private var dismiss

    @State private var apiKeyInput     = ""
    @State private var showAPIKey      = false
    @State private var showDeleteAlert = false
    @State private var cleanupDays     = 30
    @State private var isCleaning      = false
    @State private var cleanupMessage: String?
    @State private var showResetAlert  = false

    var body: some View {
        NavigationStack {
            Form {
                // ── API Key ────────────────────────────────────────────────
                Section {
                    if appState.deepgramKeySet {
                        HStack {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.green)
                            Text("API key is stored in Keychain")
                                .foregroundStyle(.secondary)
                        }
                        Button("Remove API Key", role: .destructive) {
                            showDeleteAlert = true
                        }
                    } else {
                        HStack {
                            if showAPIKey {
                                TextField("sk-...", text: $apiKeyInput)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Paste your Deepgramam API key", text: $apiKeyInput)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Button("Save API Key") {
                            appState.saveAPIKey(apiKeyInput)
                            apiKeyInput = ""
                        }
                        .disabled(apiKeyInput.isEmpty)
                    }
                } header: {
                    Text("Deepgram Speech-to-Text API")
                } footer: {
                    Text("Your key is encrypted and stored securely in the iOS Keychain. It is never sent anywhere except Deepgram's /v1/listen endpoint.")
                        .font(.caption)
                }

                // ── Audio Quality ──────────────────────────────────────────
                Section("Default Recording Quality") {
                    @Bindable var state = appState
                    Picker("Quality", selection: $state.selectedQuality) {
                        ForEach(AudioQuality.allCases) { q in
                            Text(q.displayName).tag(q)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Medium (16 kHz) is optimal for speech transcription.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // ── Storage ────────────────────────────────────────────────
                Section {
                    Stepper("Keep recordings for \(cleanupDays) days",
                            value: $cleanupDays,
                            in: 1...365)

                    Button(isCleaning ? "Cleaning…" : "Clean Up Old Audio Files") {
                        Task {
                            isCleaning = true
                            do {
                                try await appState.dataManager.cleanupOldAudioFiles(olderThan: cleanupDays)
                                cleanupMessage = "Cleanup complete."
                            } catch {
                                cleanupMessage = error.localizedDescription
                            }
                            isCleaning = false
                        }
                    }
                    .disabled(isCleaning)

                    if let msg = cleanupMessage {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Storage Management")
                } footer: {
                    Text("Audio files older than the threshold will be deleted. Transcription text is kept.")
                        .font(.caption)
                }

                // ── Reset ──────────────────────────────────────────────────
                Section {
                    Button("Delete All Data", role: .destructive) {
                        showResetAlert = true
                    }
                } footer: {
                    Text("Permanently delete all sessions, recordings, and transcripts. This cannot be undone.")
                        .font(.caption)
                }

                // ── About ──────────────────────────────────────────────────
                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Build",   value: buildNumber)
                    Link("Privacy Policy",
                         destination: URL(string: "https://example.com/privacy")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Remove API Key", isPresented: $showDeleteAlert) {
                Button("Remove", role: .destructive) { appState.deleteAPIKey() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete the key from the Keychain. Transcription will stop working until you add a new key.")
            }
            .alert("Reset App Data", isPresented: $showResetAlert) {
                Button("Delete All", role: .destructive) {
                    Task {
                        try? await appState.dataManager.deleteAllData()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure? This will permanently erase all recordings and transcripts from the device.")
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}
