//
//  RecordingActivityAttributes.swift
//  TwinMind
//
//  ActivityKit Live Activity & Dynamic Island definition.
//
//  Shows:
//  • Recording state (Recording / Paused / Interrupted / Stopped)
//  • Elapsed timer
//  • Current audio input device (e.g. "AirPods Pro")
//  • Transcription progress  (e.g. "4 / 10 chunks done")
//  • Real-time audio level bar
//

import ActivityKit
import Foundation

// MARK: - RecordingActivityAttributes

struct RecordingActivityAttributes: ActivityAttributes {

    // ── Static content (set once at Activity creation) ────────────────────
    /// The session title shown on Lock Screen.
    var sessionTitle: String

    // ── Content State (updated in real time) ─────────────────────────────
    struct ContentState: Codable, Hashable {

        // Recording state
        var stateLabel: String         // "Recording", "Paused", "Interrupted", "Stopped"
        var isRecording: Bool

        // Elapsed time (seconds since session start – used by the timer View)
        var elapsedSeconds: TimeInterval

        // Input device
        var inputDevice: String        // e.g. "AirPods Pro", "iPhone Microphone"

        // Transcription progress
        var transcribedSegments: Int
        var totalSegments: Int

        // Audio level (0.0 – 1.0 linear RMS) for the level-bar visualisation
        var audioLevel: Float

        // Human-readable progress string
        var progressLabel: String {
            guard totalSegments > 0 else { return "Transcribing…" }
            return "\(transcribedSegments)/\(totalSegments) chunks done"
        }
    }
}
