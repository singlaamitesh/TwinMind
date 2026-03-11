//
//  TwinMindTests.swift
//  TwinMindTests
//
//  Swift Testing-based tests covering model invariants and error types.
//
//  Created by Amitesh Gupta on 11/03/26.
//

import Testing
import Foundation
@testable import TwinMind

// MARK: - RecordingSession Model Tests

struct RecordingSessionTests {

    @Test func defaultSession_hasRecordingState() {
        let session = RecordingSession(title: "Test", quality: .medium)
        #expect(session.state == .recording)
        #expect(session.duration == 0)
        #expect(session.totalSegments == 0)
        #expect(session.transcribedSegments == 0)
    }

    @Test func session_stateRoundTrip() {
        let session = RecordingSession(title: "X", quality: .low)
        for state: RecordingState in [.recording, .paused, .stopped, .interrupted] {
            session.state = state
            #expect(session.state == state)
            #expect(session.stateRaw == state.rawValue)
        }
    }

    @Test func session_audioQualityRoundTrip() {
        let session = RecordingSession(title: "Y", quality: .high)
        #expect(session.audioQuality == .high)
        session.audioQuality = .low
        #expect(session.audioQualityRaw == "low")
    }

    @Test func session_transcriptionProgress_zeroSegments() {
        let session = RecordingSession(title: "Z", quality: .medium)
        #expect(session.transcriptionProgress == 0)
    }

    @Test func session_transcriptionProgress_partial() {
        let session = RecordingSession(title: "P", quality: .medium)
        session.totalSegments = 10
        session.transcribedSegments = 3
        #expect(session.transcriptionProgress == 0.3)
    }
}

// MARK: - TranscriptionSegment Model Tests

struct TranscriptionSegmentTests {

    @Test func defaultSegment_isPending() {
        let seg = TranscriptionSegment(index: 0, startTime: 0, duration: 30)
        #expect(seg.status == .pending)
        #expect(seg.retryCount == 0)
        #expect(seg.usedFallback == false)
        #expect(seg.transcriptionText == nil)
    }

    @Test func segment_statusTransitions() {
        let seg = TranscriptionSegment(index: 1, startTime: 30, duration: 30)
        seg.status = .uploading
        #expect(seg.statusRaw == "uploading")
        seg.status = .transcribed
        #expect(seg.statusRaw == "transcribed")
    }

    @Test func segment_invalidStatusRaw_fallsToPending() {
        let seg = TranscriptionSegment(index: 0, startTime: 0, duration: 30)
        seg.statusRaw = "invalid"
        #expect(seg.status == .pending)
    }
}

// MARK: - AudioQuality Tests

struct AudioQualityModelTests {

    @Test func allCases_haveUniqueSampleRates() {
        let rates = AudioQuality.allCases.map(\.sampleRate)
        #expect(rates.count == Set(rates).count)
    }

    @Test func medium_optimalForSpeech() {
        #expect(AudioQuality.medium.sampleRate == 16_000)
        #expect(AudioQuality.medium.channels == 1)
        #expect(AudioQuality.medium.bitDepth == 16)
    }

    @Test func high_isStereo() {
        #expect(AudioQuality.high.channels == 2)
        #expect(AudioQuality.high.sampleRate == 44_100)
    }
}

// MARK: - Error Description Tests

struct ErrorDescriptionTests {

    @Test func audioErrors_haveDescriptions() {
        let errors: [AudioError] = [.microphonePermissionDenied, .engineStartFailed,
                                     .fileCreationFailed, .noActiveSession]
        for err in errors {
            #expect(err.errorDescription != nil)
            #expect(!err.errorDescription!.isEmpty)
        }
    }

    @Test func transcriptionErrors_haveDescriptions() {
        let errors: [TranscriptionError] = [.missingAPIKey, .invalidResponse,
                                             .httpError(500, nil), .localModelUnavailable]
        for err in errors {
            #expect(err.errorDescription != nil)
        }
    }

    @Test func storageError_includesFreeMB() {
        let err = StorageError.insufficientStorage(freeMB: 12)
        #expect(err.errorDescription?.contains("12") == true)
    }

    @Test func dataError_sessionNotFound() {
        let err = DataError.sessionNotFound
        #expect(err.errorDescription?.contains("session") == true)
    }

    @Test func keychainError_descriptions() {
        let errors: [KeychainError] = [.unexpectedStatus(-25300), .itemNotFound, .encodingError]
        for err in errors {
            #expect(err.errorDescription != nil)
        }
    }

    @Test func securityError_descriptions() {
        let errors: [SecurityError] = [.encryptionFailed, .decryptionFailed, .keyNotFound]
        for err in errors {
            #expect(err.errorDescription != nil)
        }
    }
}
