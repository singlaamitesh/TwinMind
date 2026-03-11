//
//  DataManagerActorTests.swift
//  TwinMindTests
//
//  Unit tests for DataManagerActor using an in-memory SwiftData store.
//

import XCTest
import SwiftData
@testable import TwinMind

@MainActor
final class DataManagerActorTests: XCTestCase {

    // ── Helpers ───────────────────────────────────────────────────────────

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([RecordingSession.self, TranscriptionSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeDataManager() throws -> DataManagerActor {
        let container = try makeInMemoryContainer()
        return DataManagerActor(modelContainer: container)
    }

    // ── Session CRUD ──────────────────────────────────────────────────────

    func testCreateSession_returnsValidID() async throws {
        let dm = try makeDataManager()
        let id = try await dm.createSession(title: "Test Session", quality: .medium)
        XCTAssertNotNil(id)
    }

    func testUpdateSession_stateTransition() async throws {
        let dm   = try makeDataManager()
        let id   = try await dm.createSession(title: "X", quality: .medium)
        try await dm.updateSession(id: id, state: .paused, duration: 42)
        let sessions = try await dm.fetchAllSessions()
        let s = try XCTUnwrap(sessions.first)
        XCTAssertEqual(s.state,    .paused)
        XCTAssertEqual(s.duration, 42)
    }

    func testDeleteSession_removesFromStore() async throws {
        let dm  = try makeDataManager()
        let id  = try await dm.createSession(title: "Del Me", quality: .low)
        try await dm.deleteSession(id: id)
        let all = try await dm.fetchAllSessions()
        XCTAssertTrue(all.isEmpty)
    }

    // ── Segment CRUD ──────────────────────────────────────────────────────

    func testInsertSegment_incrementsTotalSegments() async throws {
        let dm   = try makeDataManager()
        let sid  = try await dm.createSession(title: "S", quality: .medium)
        _        = try await dm.insertSegment(sessionID: sid, index: 0,
                                              startTime: 0, duration: 30)
        let sessions = try await dm.fetchAllSessions()
        XCTAssertEqual(sessions.first?.totalSegments, 1)
    }

    func testMarkSegmentTranscribed_updatesTextAndCounter() async throws {
        let dm   = try makeDataManager()
        let sid  = try await dm.createSession(title: "T", quality: .medium)
        let segID = try await dm.insertSegment(sessionID: sid, index: 0,
                                               startTime: 0, duration: 30)
        try await dm.markSegmentTranscribed(id: segID, text: "Hello world",
                                            confidence: 0.95, usedFallback: false)
        let sessions = try await dm.fetchAllSessions()
        let session  = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.transcribedSegments, 1)
        let segs = try await dm.fetchSegments(for: sid)
        XCTAssertEqual(segs.first?.transcriptionText, "Hello world")
        XCTAssertEqual(segs.first?.status, .transcribed)
    }

    func testMarkSegmentFailed_setsErrorMessage() async throws {
        let dm    = try makeDataManager()
        let sid   = try await dm.createSession(title: "F", quality: .medium)
        let segID = try await dm.insertSegment(sessionID: sid, index: 0,
                                               startTime: 0, duration: 30)
        try await dm.markSegmentFailed(id: segID, error: "Network error")
        let segs = try await dm.fetchSegments(for: sid)
        XCTAssertEqual(segs.first?.status, .failed)
        XCTAssertEqual(segs.first?.errorMessage, "Network error")
    }

    func testBatchInsertSegments_savesAll() async throws {
        let dm  = try makeDataManager()
        let sid = try await dm.createSession(title: "Batch", quality: .high)
        let descriptors = (0..<10).map { i in
            (index: i, startTime: TimeInterval(i * 30), duration: 30.0, audioFileURL: Optional<String>.none)
        }
        try await dm.batchInsertSegments(sessionID: sid, descriptors: descriptors)
        let sessions = try await dm.fetchAllSessions()
        XCTAssertEqual(sessions.first?.totalSegments, 10)
    }

    // ── Search ─────────────────────────────────────────────────────────────

    func testSearchSessions_findsMatch() async throws {
        let dm = try makeDataManager()
        _      = try await dm.createSession(title: "Team Standup", quality: .medium)
        _      = try await dm.createSession(title: "1:1 Meeting",  quality: .medium)
        let results = try await dm.searchSessions(query: "standup")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Team Standup")
    }

    func testSearchSessions_emptyQuery_returnsAll() async throws {
        let dm = try makeDataManager()
        for i in 0..<5 {
            _ = try await dm.createSession(title: "Session \(i)", quality: .medium)
        }
        // fetchAllSessions returns all
        let all = try await dm.fetchAllSessions()
        XCTAssertEqual(all.count, 5)
    }

    // ── Retry queue ───────────────────────────────────────────────────────

    func testFetchRetryableSegments_returnsPendingAndFailed() async throws {
        let dm  = try makeDataManager()
        let sid = try await dm.createSession(title: "R", quality: .medium)
        _ = try await dm.insertSegment(sessionID: sid, index: 0, startTime: 0,  duration: 30)
        let id1 = try await dm.insertSegment(sessionID: sid, index: 1, startTime: 30, duration: 30)
        let id2 = try await dm.insertSegment(sessionID: sid, index: 2, startTime: 60, duration: 30)

        // id0 stays pending, id1 fails, id2 gets transcribed
        try await dm.markSegmentFailed(id: id1, error: "err")
        try await dm.markSegmentTranscribed(id: id2, text: "ok", confidence: nil, usedFallback: false)

        let retryable = try await dm.fetchRetryableSegments()
        // Should contain id0 (pending) and id1 (failed)
        XCTAssertEqual(retryable.count, 2)
        let statuses = Set(retryable.map(\.status))
        XCTAssertTrue(statuses.contains(.pending))
        XCTAssertTrue(statuses.contains(.failed))
    }
}
