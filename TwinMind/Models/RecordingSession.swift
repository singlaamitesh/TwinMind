//
//  RecordingSession.swift
//  TwinMind
//
//  SwiftData model representing one complete recording session.
//

import Foundation
import SwiftData

// MARK: - Recording State

/// All possible states a recording session can be in.
nonisolated enum RecordingState: String, Codable, Sendable {
    case recording
    case paused
    case stopped
    case interrupted
}

// MARK: - Audio Quality

/// Configurable audio quality presets.
nonisolated enum AudioQuality: String, Codable, CaseIterable, Identifiable, Sendable {
    case low    // 8 kHz, mono
    case medium // 16 kHz, mono  (default — optimal for speech)
    case high   // 44.1 kHz, stereo

    var id: String { rawValue }

    var sampleRate: Double {
        switch self {
        case .low:    return 8_000
        case .medium: return 16_000
        case .high:   return 44_100
        }
    }

    var channels: Int {
        switch self {
        case .low, .medium: return 1
        case .high:         return 2
        }
    }

    var bitDepth: Int { 16 }

    var displayName: String {
        switch self {
        case .low:    return "Low (8 kHz)"
        case .medium: return "Medium (16 kHz)"
        case .high:   return "High (44.1 kHz)"
        }
    }
}

// MARK: - RecordingSession

/// Root SwiftData model — one session per recording tap.
@Model
final class RecordingSession {

    // ── Identity ──────────────────────────────────────────────────────────
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date

    // ── State ─────────────────────────────────────────────────────────────
    var stateRaw: String                  // RecordingState.rawValue
    var duration: TimeInterval            // seconds elapsed so far
    var audioQualityRaw: String           // AudioQuality.rawValue

    // ── File ──────────────────────────────────────────────────────────────
    /// Relative path inside the app's Documents directory.
    var audioFileURL: String?

    // ── Transcription summary ─────────────────────────────────────────────
    var totalSegments: Int
    var transcribedSegments: Int

    // ── Relationships ─────────────────────────────────────────────────────
    @Relationship(deleteRule: .cascade, inverse: \TranscriptionSegment.session)
    var segments: [TranscriptionSegment] = []

    // ── Computed helpers ───────────────────────────────────────────────────
    var state: RecordingState {
        get { RecordingState(rawValue: stateRaw) ?? .stopped }
        set { stateRaw = newValue.rawValue }
    }

    var audioQuality: AudioQuality {
        get { AudioQuality(rawValue: audioQualityRaw) ?? .medium }
        set { audioQualityRaw = newValue.rawValue }
    }

    var transcriptionProgress: Double {
        guard totalSegments > 0 else { return 0 }
        return Double(transcribedSegments) / Double(totalSegments)
    }

    // ── Init ──────────────────────────────────────────────────────────────
    init(
        id: UUID = UUID(),
        title: String = "Recording \(Date().formatted(date: .abbreviated, time: .shortened))",
        quality: AudioQuality = .medium
    ) {
        self.id                = id
        self.title             = title
        self.createdAt         = Date()
        self.stateRaw          = RecordingState.recording.rawValue
        self.duration          = 0
        self.audioQualityRaw   = quality.rawValue
        self.audioFileURL      = nil
        self.totalSegments     = 0
        self.transcribedSegments = 0
    }
}
