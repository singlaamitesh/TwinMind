//
//  DataManagerActor.swift
//  TwinMind
//
//  @ModelActor that serialises ALL SwiftData mutations onto a private background
//  context.  UI reads are performed on the main actor via separate @Query macros.
//

import Foundation
import SwiftData

// MARK: - Notification for cross-context refresh

extension Notification.Name {
    /// Posted after DataManagerActor saves changes that the main-context @Query
    /// needs to pick up (segment transcribed, session updated, etc.).
    static let dataManagerDidSave = Notification.Name("com.twinmind.dataManagerDidSave")
}

// MARK: - DataManagerActor

/// Background SwiftData context manager.
/// • All write operations are funnelled through this actor.
/// • Batch-saves to amortise flush cost.
/// • Indexed queries for sessions ≥ 10 k, segments ≥ 10 k.
@ModelActor
actor DataManagerActor {

    /// Post a notification on the main thread after a save so that @Query
    /// in SwiftUI views can call `modelContext.refreshAll()` to pick up
    /// the background context's changes.
    private func notifyMainContext() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .dataManagerDidSave, object: nil)
        }
    }

    // MARK: - Session CRUD

    /// Insert a brand-new session and return its persistent identifier.
    func createSession(title: String, quality: AudioQuality) throws -> PersistentIdentifier {
        let session = RecordingSession(title: title, quality: quality)
        modelContext.insert(session)
        try modelContext.save()
        return session.persistentModelID
    }

    /// Update mutable fields on an existing session.
    func updateSession(
        id: PersistentIdentifier,
        state: RecordingState? = nil,
        duration: TimeInterval? = nil,
        audioFileURL: String? = nil,
        totalSegments: Int? = nil,
        transcribedSegments: Int? = nil
    ) throws {
        guard let session = modelContext.model(for: id) as? RecordingSession else { return }
        if let state              { session.state              = state              }
        if let duration           { session.duration           = duration           }
        if let audioFileURL       { session.audioFileURL       = audioFileURL       }
        if let totalSegments      { session.totalSegments      = totalSegments      }
        if let transcribedSegments { session.transcribedSegments = transcribedSegments }
        try modelContext.save()
        notifyMainContext()
    }

    /// Delete a session (cascade removes its segments).
    func deleteSession(id: PersistentIdentifier) throws {
        guard let session = modelContext.model(for: id) as? RecordingSession else { return }
        modelContext.delete(session)
        try modelContext.save()
        notifyMainContext()
    }

    // MARK: - Segment CRUD

    /// Insert a single segment linked to a session.
    func insertSegment(
        sessionID: PersistentIdentifier,
        index: Int,
        startTime: TimeInterval,
        duration: TimeInterval,
        audioFileURL: String? = nil
    ) throws -> PersistentIdentifier {
        guard let session = modelContext.model(for: sessionID) as? RecordingSession else {
            throw DataError.sessionNotFound
        }
        let segment = TranscriptionSegment(
            index: index,
            startTime: startTime,
            duration: duration,
            audioFileURL: audioFileURL
        )
        segment.session = session
        modelContext.insert(segment)
        session.totalSegments += 1
        try modelContext.save()
        notifyMainContext()
        return segment.persistentModelID
    }

    /// Batch-insert many segments in a single save (avoids N context saves).
    func batchInsertSegments(
        sessionID: PersistentIdentifier,
        descriptors: [(index: Int, startTime: TimeInterval, duration: TimeInterval, audioFileURL: String?)]
    ) throws {
        guard let session = modelContext.model(for: sessionID) as? RecordingSession else {
            throw DataError.sessionNotFound
        }
        for d in descriptors {
            let seg = TranscriptionSegment(
                index: d.index,
                startTime: d.startTime,
                duration: d.duration,
                audioFileURL: d.audioFileURL
            )
            seg.session = session
            modelContext.insert(seg)
        }
        session.totalSegments += descriptors.count
        try modelContext.save()
    }

    /// Mark a segment as transcribed with the resulting text.
    func markSegmentTranscribed(
        id: PersistentIdentifier,
        text: String,
        confidence: Double?,
        usedFallback: Bool
    ) throws {
        guard let segment = modelContext.model(for: id) as? TranscriptionSegment else { return }
        segment.transcriptionText = text
        segment.confidence        = confidence
        segment.status            = usedFallback ? .fallback : .transcribed
        segment.usedFallback      = usedFallback
        // Increment parent counter
        segment.session?.transcribedSegments += 1
        try modelContext.save()
        notifyMainContext()
    }

    /// Mark a segment as failed and record error detail.
    func markSegmentFailed(id: PersistentIdentifier, error: String) throws {
        guard let segment = modelContext.model(for: id) as? TranscriptionSegment else { return }
        segment.status        = .failed
        segment.errorMessage  = error
        segment.retryCount   += 1
        segment.lastAttemptAt = Date()
        try modelContext.save()
        notifyMainContext()
    }

    /// Increment retry count and update last-attempt timestamp.
    func incrementRetry(id: PersistentIdentifier) throws {
        guard let segment = modelContext.model(for: id) as? TranscriptionSegment else { return }
        segment.retryCount   += 1
        segment.lastAttemptAt = Date()
        segment.status        = .uploading
        try modelContext.save()
    }

    // MARK: - Queries

    /// Fetch all sessions sorted by creation date (newest first).
    /// Leverages the `.indexed` attribute on `createdAt`.
    func fetchAllSessions() throws -> [RecordingSession] {
        let descriptor = FetchDescriptor<RecordingSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// Fetch sessions matching a title substring.
    func searchSessions(query: String) throws -> [RecordingSession] {
        let predicate = #Predicate<RecordingSession> { session in
            session.title.localizedStandardContains(query)
        }
        let descriptor = FetchDescriptor<RecordingSession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// Fetch all segments for a session ordered by index.
    func fetchSegments(for sessionID: PersistentIdentifier) throws -> [TranscriptionSegment] {
        guard let session = modelContext.model(for: sessionID) as? RecordingSession else {
            throw DataError.sessionNotFound
        }
        let id = session.id  // capture value type for predicate
        let predicate = #Predicate<TranscriptionSegment> { seg in
            seg.session?.id == id
        }
        var descriptor = FetchDescriptor<TranscriptionSegment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.index)]
        )
        descriptor.fetchLimit = 500  // page in chunks if needed
        return try modelContext.fetch(descriptor)
    }

    /// Fetch all pending / failed segments eligible for retry.
    func fetchRetryableSegments() throws -> [TranscriptionSegment] {
        let predicate = #Predicate<TranscriptionSegment> { seg in
            seg.statusRaw == "pending" || seg.statusRaw == "failed"
        }
        let descriptor = FetchDescriptor<TranscriptionSegment>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor)
    }

    // MARK: - Cleanup

    /// Remove all audio files referenced by sessions older than `days` days.
    func cleanupOldAudioFiles(olderThan days: Int = 30) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = #Predicate<RecordingSession> { s in
            s.createdAt < cutoff
        }
        let descriptor = FetchDescriptor<RecordingSession>(predicate: predicate)
        let old = try modelContext.fetch(descriptor)
        let fm  = FileManager.default
        for session in old {
            if let rel = session.audioFileURL {
                let url = FileManager.documentsURL.appendingPathComponent(rel)
                try? fm.removeItem(at: url)
                session.audioFileURL = nil
            }
            for seg in session.segments {
                if let rel = seg.audioFileURL {
                    let url = FileManager.documentsURL.appendingPathComponent(rel)
                    try? fm.removeItem(at: url)
                    seg.audioFileURL = nil
                }
            }
        }
        try modelContext.save()
    }

    // MARK: - Reset

    /// Delete ALL sessions and segments from the database.
    /// This is a destructive operation used for "Reset App Data".
    /// We iterate and delete sessions to trigger the `.cascade` rule, ensuring
    /// proper relationship cleanup which pure batch delete sometimes fails on.
    func deleteAllData() throws {
        // 1. Delete all sessions (cascades to segments)
        let sessionDescriptor = FetchDescriptor<RecordingSession>()
        let sessions = try modelContext.fetch(sessionDescriptor)
        for session in sessions {
            modelContext.delete(session)
        }
        
        // 2. Cleanup any orphaned segments
        let segmentDescriptor = FetchDescriptor<TranscriptionSegment>()
        let segments = try modelContext.fetch(segmentDescriptor)
        for segment in segments {
            modelContext.delete(segment)
        }

        try modelContext.save()
    }
}

// MARK: - Errors

nonisolated enum DataError: LocalizedError {
    case sessionNotFound
    case segmentNotFound

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: return "Recording session not found in the database."
        case .segmentNotFound: return "Transcription segment not found in the database."
        }
    }
}

// MARK: - FileManager Helper

extension FileManager {
    nonisolated(unsafe) static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
