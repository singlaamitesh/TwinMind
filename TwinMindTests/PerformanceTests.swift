//
//  PerformanceTests.swift
//  TwinMindTests
//
//  Performance and memory benchmarks.
//
//  Strategy:
//  • Measure time to batch-insert 10 k segments into an in-memory store.
//  • Measure time to fetch + group 10 k segments.
//  • Estimate memory footprint growth during a 1-hour simulated recording
//    (120 × 30-second chunks).
//

import XCTest
import SwiftData
@testable import TwinMind

final class PerformanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeDataManager() throws -> DataManagerActor {
        let schema = Schema([RecordingSession.self, TranscriptionSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return DataManagerActor(modelContainer: container)
    }

    // MARK: - Bulk Insert

    /// Insert 10 000 segments into an in-memory store — should complete < 3 s.
    func testBulkInsert_10k_segments() async throws {
        let dm  = try makeDataManager()
        let sid = try await dm.createSession(title: "Perf", quality: .medium)

        let descriptors = (0..<10_000).map { i in
            (index: i,
             startTime: TimeInterval(i * 30),
             duration: 30.0,
             audioFileURL: Optional<String>.none)
        }

        let start = ContinuousClock.now
        try await dm.batchInsertSegments(sessionID: sid, descriptors: descriptors)
        let elapsed = ContinuousClock.now - start

        print("[Perf] 10 k batch insert: \(elapsed)")
        let sessions = try await dm.fetchAllSessions()
        XCTAssertEqual(sessions.first?.totalSegments, 10_000)

        // Soft performance assertion — adjust threshold for CI hardware.
        XCTAssertLessThan(elapsed, .seconds(5),
                          "Batch insert of 10 k segments exceeded 5 s threshold")
    }

    // MARK: - Fetch & Sort

    /// Fetch and sort 10 000 segments — should complete < 500 ms.
    func testFetchAndSort_10k_segments() async throws {
        let dm  = try makeDataManager()
        let sid = try await dm.createSession(title: "FetchPerf", quality: .medium)
        let descriptors = (0..<10_000).map { i in
            (index: i, startTime: TimeInterval(i * 30), duration: 30.0, audioFileURL: Optional<String>.none)
        }
        try await dm.batchInsertSegments(sessionID: sid, descriptors: descriptors)

        let start = ContinuousClock.now
        let segs  = try await dm.fetchSegments(for: sid)
        let elapsed = ContinuousClock.now - start

        print("[Perf] 10 k fetch: \(elapsed)")
        XCTAssertEqual(segs.count, 500,  // fetchLimit = 500 in DataManagerActor
                       "Expected paginated result of 500 segments")
        XCTAssertLessThan(elapsed, .seconds(1),
                          "Fetch of 500 segments exceeded 1 s threshold")
    }

    // MARK: - 1-Hour Recording Simulation

    /// Simulate inserting 120 × 30-second chunks (one hour of recording)
    /// and measure peak memory delta using mach_task_basic_info.
    func testOneHourRecording_memoryFootprint() async throws {
        let memBefore = currentMemoryUsageBytes()
        let dm  = try makeDataManager()
        let sid = try await dm.createSession(title: "1h", quality: .medium)

        for i in 0..<120 {
            let segID = try await dm.insertSegment(
                sessionID: sid,
                index: i,
                startTime: TimeInterval(i * 30),
                duration: 30
            )
            // Simulate transcription arriving
            try await dm.markSegmentTranscribed(
                id: segID,
                text: "Segment \(i): Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
                confidence: 0.97,
                usedFallback: false
            )
        }

        let memAfter  = currentMemoryUsageBytes()
        let deltaMB   = Double(memAfter - memBefore) / 1_048_576.0
        print("[Perf] 1-hour simulation memory delta: \(String(format: "%.2f", deltaMB)) MB")

        // 120 segments × ~200 bytes text ≈ < 10 MB expected overhead.
        XCTAssertLessThan(deltaMB, 50.0, "Memory growth exceeded 50 MB for 1-hour simulation")
    }

    // MARK: - Memory Helper

    private func currentMemoryUsageBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
