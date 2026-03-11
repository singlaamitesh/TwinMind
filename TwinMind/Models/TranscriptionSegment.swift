//
//  TranscriptionSegment.swift
//  TwinMind
//
//  SwiftData model — one 30-second audio chunk with its transcription result.
//

import Foundation
import SwiftData

// MARK: - Segment Status

nonisolated enum SegmentStatus: String, Codable, Sendable {
    case pending       // waiting for network / queue
    case uploading     // actively being sent to Deepgram
    case transcribed   // final text available
    case failed        // exhausted retries, no fallback possible
    case fallback      // transcribed via SFSpeechRecognizer
}

// MARK: - TranscriptionSegment

/// Child model linked to a `RecordingSession` (N side of the 1:N).
@Model
final class TranscriptionSegment {

    // ── Identity ──────────────────────────────────────────────────────────
    @Attribute(.unique) var id: UUID

    /// Zero-based ordinal within the parent session (used for ordering & deduplication).
    var index: Int

    // ── Parent ─────────────────────────────────────────────────────────────
    var session: RecordingSession?

    // ── Timing ────────────────────────────────────────────────────────────
    var startTime: TimeInterval      // seconds from session start
    var duration: TimeInterval       // actual chunk length (≤30 s)
    var createdAt: Date

    // ── Audio ─────────────────────────────────────────────────────────────
    /// Relative path inside the app's Documents directory (encrypted on disk).
    var audioFileURL: String?

    // ── Transcription ─────────────────────────────────────────────────────
    var statusRaw: String            // SegmentStatus.rawValue
    var transcriptionText: String?
    var confidence: Double?          // 0–1, from Deepgram alternative confidence
    var retryCount: Int
    var lastAttemptAt: Date?
    var errorMessage: String?
    var usedFallback: Bool           // true → SFSpeechRecognizer was used

    // ── Computed ──────────────────────────────────────────────────────────
    var status: SegmentStatus {
        get { SegmentStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    // ── Init ──────────────────────────────────────────────────────────────
    init(
        id: UUID = UUID(),
        index: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        audioFileURL: String? = nil
    ) {
        self.id           = id
        self.index        = index
        self.startTime    = startTime
        self.duration     = duration
        self.audioFileURL = audioFileURL
        self.createdAt    = Date()
        self.statusRaw    = SegmentStatus.pending.rawValue
        self.transcriptionText = nil
        self.confidence   = nil
        self.retryCount   = 0
        self.lastAttemptAt = nil
        self.errorMessage = nil
        self.usedFallback = false
    }
}
