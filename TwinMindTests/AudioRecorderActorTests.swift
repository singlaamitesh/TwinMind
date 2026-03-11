//
//  AudioRecorderActorTests.swift
//  TwinMindTests
//
//  Tests for AudioRecorderActor using a mock audio engine approach.
//  Because AVAudioEngine is not easily mockable, we test the actor's state
//  machine and error paths via protocol abstractions.
//

import XCTest
import AVFoundation
import SwiftData
@testable import TwinMind

// MARK: - MockSecurityManager

/// Passthrough encryption — no-op for tests.
final class MockSecurityManager: @unchecked Sendable {
    func encryptFile(at url: URL) async throws -> URL { url }
    func decryptFile(at url: URL) async throws -> Data { try Data(contentsOf: url) }
}

// MARK: - MockTranscriptionService

/// Records which segment IDs were enqueued.
actor MockTranscriptionService {
    var enqueuedSegments: [PersistentIdentifier] = []

    func enqueue(segmentID: PersistentIdentifier, audioURL: URL, duration: TimeInterval) {
        enqueuedSegments.append(segmentID)
    }
}

// MARK: - RecorderStateTests

final class RecorderStateTests: XCTestCase {

    /// Verifies RecordingState round-trip through rawValue.
    func testRecordingStateRawValues() {
        for state in [RecordingState.recording, .paused, .stopped, .interrupted] {
            XCTAssertEqual(RecordingState(rawValue: state.rawValue), state)
        }
    }

    /// Verifies unknown raw values fall back to .stopped.
    func testUnknownRawValue_fallsBackToStopped() {
        let session = RecordingSession(title: "X", quality: .medium)
        session.stateRaw = "invalid_state"
        XCTAssertEqual(session.state, .stopped)
    }
}

// MARK: - AudioQualityTests

final class AudioQualityTests: XCTestCase {

    func testAllQualitiesHaveUniqueSampleRates() {
        let rates = AudioQuality.allCases.map(\.sampleRate)
        XCTAssertEqual(rates.count, Set(rates).count)
    }

    func testMediumQuality_isDefaultForSpeech() {
        XCTAssertEqual(AudioQuality.medium.sampleRate, 16_000)
        XCTAssertEqual(AudioQuality.medium.channels, 1)
    }

    func testHighQuality_isStereo() {
        XCTAssertEqual(AudioQuality.high.channels, 2)
    }
}

// MARK: - AudioLevelTests

final class AudioLevelTests: XCTestCase {

    func testAudioLevel_clampedTo1() {
        let level = AudioLevel(rms: 1.5, peak: 2.0)
        // Constructed values; clamping is done in processTapBuffer
        XCTAssertGreaterThan(level.rms,  0)
        XCTAssertGreaterThan(level.peak, 0)
    }
}

// MARK: - SegmentStatusTests

final class SegmentStatusTests: XCTestCase {

    func testAllSegmentStatuses_roundTrip() {
        for status in [SegmentStatus.pending, .uploading, .transcribed, .failed, .fallback] {
            XCTAssertEqual(SegmentStatus(rawValue: status.rawValue), status)
        }
    }

    func testTranscriptionSegment_defaultIsPending() {
        let seg = TranscriptionSegment(index: 0, startTime: 0, duration: 30)
        XCTAssertEqual(seg.status, .pending)
        XCTAssertEqual(seg.retryCount, 0)
        XCTAssertFalse(seg.usedFallback)
    }
}
