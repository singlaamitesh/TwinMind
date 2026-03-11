//
//  RecordingIntents.swift
//  TwinMind
//
//  App Intents for Siri / Shortcuts integration.
//
//  Intents:
//  • StartRecordingIntent  — starts a new session (optional name + quality).
//  • StopRecordingIntent   — stops the active session and returns a summary.
//
//  The intents bridge to AppState (the @Observable singleton that owns the
//  AudioRecorderActor) so state stays perfectly in sync with the UI.
//

import AppIntents
import Foundation

// MARK: - AudioQualityEntity

/// Makes AudioQuality available as a parameter type in Shortcuts.
enum AudioQualityEntity: String, AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Audio Quality"
    static var caseDisplayRepresentations: [AudioQualityEntity: DisplayRepresentation] = [
        .low:    "Low  (8 kHz)",
        .medium: "Medium (16 kHz)",
        .high:   "High (44.1 kHz)"
    ]

    case low
    case medium
    case high

    var audioQuality: AudioQuality {
        switch self {
        case .low:    return .low
        case .medium: return .medium
        case .high:   return .high
        }
    }
}

// MARK: - StartRecordingIntent

struct StartRecordingIntent: AppIntent {

    static var title: LocalizedStringResource = "Start TwinMind Recording"
    static var description = IntentDescription("Starts a new audio recording session in TwinMind.")

    // ── Optional parameters ───────────────────────────────────────────────
    @Parameter(title: "Session Name", default: "")
    var sessionName: String

    @Parameter(title: "Audio Quality", default: .medium)
    var quality: AudioQualityEntity

    // ── Opens the app ─────────────────────────────────────────────────────
    static var openAppWhenRun: Bool = true

    // ── Perform ───────────────────────────────────────────────────────────
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let appState = AppState.shared
        guard !appState.isRecording else {
            return .result(dialog: "A recording is already in progress.")
        }
        let name = sessionName.isEmpty
            ? "Shortcut Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
            : sessionName
        try await appState.startRecording(title: name, quality: quality.audioQuality)
        return .result(dialog: "Recording started: \(name)")
    }
}

// MARK: - StopRecordingIntent

struct StopRecordingIntent: AppIntent {

    static var title: LocalizedStringResource = "Stop TwinMind Recording"
    static var description = IntentDescription("Stops the active TwinMind recording session and returns a summary.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let appState = AppState.shared
        guard appState.isRecording else {
            return .result(dialog: "No recording is currently active.")
        }
        let summary = await appState.stopRecording()
        let dialog  = "Recording stopped. \(summary)"
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - TwinMindShortcuts

/// Registers the default suggested Shortcuts visible in the Shortcuts app.
struct TwinMindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Begin a new \(.applicationName) session"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: StopRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "End the \(.applicationName) session"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.circle"
        )
    }
}
