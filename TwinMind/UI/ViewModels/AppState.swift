//
//  AppState.swift
//  TwinMind
//
//  Central @Observable coordinator owned by the App scene.
//  Bridges the actor-isolated backend (AudioRecorderActor, TranscriptionService,
//  DataManagerActor) to the @MainActor UI layer.
//

import Foundation
import SwiftData
import Observation
import AVFoundation
import Speech

@MainActor
@Observable
final class AppState {

    // ── Singleton (used by AppIntents) ────────────────────────────────────
    static let shared = AppState()

    // ── Dependencies ──────────────────────────────────────────────────────
    let security          = SecurityManager()
    let dataManager: DataManagerActor
    let transcription: TranscriptionService
    let recorder: AudioRecorderActor
    let networkMonitor    = NetworkMonitor.shared

    // ── Observable UI state ───────────────────────────────────────────────
    var isRecording    = false
    var isPaused       = false
    var isInterrupted  = false
    var elapsedSeconds: TimeInterval = 0
    var audioLevel: AudioLevel = AudioLevel(rms: 0, peak: 0)
    var currentDevice  = "iPhone Microphone"
    var currentSessionID: PersistentIdentifier?

    // Transcription progress for the active session
    var totalSegments      = 0
    var transcribedSegments = 0

    // Error banner
    var errorMessage: String?

    // Settings
    var selectedQuality: AudioQuality = .medium
    var deepgramKeySet: Bool = false

    // MARK: - Init

    init() {
        // Build the dependency graph
        let sec   = SecurityManager()
        let dm    = DataManagerActor(modelContainer: AppState.makeContainer())
        let ts    = TranscriptionService(dataManager: dm, security: sec)
        let rec   = AudioRecorderActor(dataManager: dm, transcriptionService: ts, security: sec)

        self.dataManager    = dm
        self.transcription  = ts
        self.recorder       = rec

        deepgramKeySet = (try? KeychainManager.read(key: .deepgramAPIKey)) != nil
        startObserving()
        wireNetworkReconnect()
        recoverPendingSegments()
        // Defer speech permission request — calling it synchronously in init()
        // can crash if the Info.plist key hasn't been loaded yet.
        Task { @MainActor [weak self] in
            self?.requestSpeechPermissionIfNeeded()
        }
    }

    // MARK: - SwiftData Container

    static func makeContainer() -> ModelContainer {
        // Ensure the Application Support directory exists — SwiftData/CoreData
        // expects it but iOS doesn't always create it automatically.
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            if !fm.fileExists(atPath: appSupport.path) {
                try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            }
        }
        
        let schema = Schema([RecordingSession.self, TranscriptionSegment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData container init failed: \(error)")
        }
    }

    // MARK: - Recording Control

    func startRecording(title: String = "", quality: AudioQuality? = nil) async throws {
        // ── Storage check ─────────────────────────────────────────────────
        try checkAvailableStorage(minimumMB: 50)

        let q = quality ?? selectedQuality
        // Reset transcription failure counter so previous session failures
        // don't immediately trigger the fallback path for the new session.
        await transcription.resetFailureState()
        try await recorder.startRecording(title: title, quality: q)
        elapsedSeconds = 0
        totalSegments  = 0
        transcribedSegments = 0
        // Start elapsed-time ticker
        startElapsedTimer()
        // Start transcription progress polling
        startProgressPolling()
        // Update device name
        currentDevice = await recorder.currentInputDeviceName()
        // Live Activity
        let sessionTitle = title.isEmpty ? "New Recording" : title
        LiveActivityManager.shared.startActivity(
            sessionTitle: sessionTitle,
            inputDevice: currentDevice
        )
    }

    func pauseRecording() async throws {
        try await recorder.pauseRecording()
    }

    func resumeRecording() async throws {
        try await recorder.resumeRecording()
    }

    /// Stop the active session and return a human-readable summary string.
    @discardableResult
    func stopRecording() async -> String {
        do {
            try await recorder.stopRecording()
        } catch {
            errorMessage = error.localizedDescription
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil

        let summary = "Duration: \(formattedElapsed), \(transcribedSegments)/\(totalSegments) segments transcribed."
        await LiveActivityManager.shared.endActivity(
            transcribedSegments: transcribedSegments,
            totalSegments: totalSegments,
            elapsedSeconds: elapsedSeconds
        )
        return summary
    }

    // MARK: - Formatted helpers

    var formattedElapsed: String {
        let total = Int(elapsedSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    var recorderStateLabel: String {
        if isInterrupted { return "Interrupted" }
        if isPaused      { return "Paused"      }
        if isRecording   { return "Recording"   }
        return "Idle"
    }

    // MARK: - Settings

    func saveAPIKey(_ key: String) {
        do {
            try KeychainManager.save(key, for: .deepgramAPIKey)
            deepgramKeySet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        try? KeychainManager.delete(key: .deepgramAPIKey)
        deepgramKeySet = false
    }

    // MARK: - Private: Timer

    private var elapsedTimer: Timer?
    private var progressTimer: Timer?

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.elapsedSeconds += 1
                await self.syncLiveActivity()
            }
        }
    }

    // MARK: - Private: Transcription Progress Polling

    /// Polls the DataManagerActor every 3 seconds to sync transcription progress
    /// back to the UI — covers segments completed by background TranscriptionService.
    private func startProgressPolling() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshTranscriptionProgress()
            }
        }
    }

    private func refreshTranscriptionProgress() async {
        guard let sessionID = currentSessionID else { return }
        do {
            let sessions = try await dataManager.fetchAllSessions()
            if let session = sessions.first(where: { $0.persistentModelID == sessionID }) {
                totalSegments       = session.totalSegments
                transcribedSegments = session.transcribedSegments
            }
        } catch {
            // Non-critical — will retry next tick
        }
    }

    // MARK: - Private: Storage Check

    /// Throws if the device has less than `minimumMB` megabytes free.
    private func checkAvailableStorage(minimumMB: Int) throws {
        let fileManager = FileManager.default
        let homeURL     = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let attrs = try? fileManager.attributesOfFileSystem(forPath: homeURL.path),
           let freeSpace = attrs[.systemFreeSize] as? Int64 {
            let freeMB = freeSpace / (1024 * 1024)
            if freeMB < Int64(minimumMB) {
                throw StorageError.insufficientStorage(freeMB: Int(freeMB))
            }
        }
    }

    // MARK: - Private: Network Reconnect → Retry Queue

    /// When the device transitions from offline → online, retry all pending segments.
    private func wireNetworkReconnect() {
        networkMonitor.onReconnect = { [weak self] in
            guard let self else { return }
            await self.transcription.retryOfflineQueue()
        }
    }

    // MARK: - Private: Termination Recovery

    /// On cold launch, find any pending / failed segments and re-enqueue them.
    private func recoverPendingSegments() {
        Task {
            await transcription.retryOfflineQueue()
        }
    }

    // MARK: - Private: Speech Permission

    /// Pre-request SFSpeechRecognizer authorization so the fallback path doesn't
    /// block on a first-time permission dialog during recording.
    private func requestSpeechPermissionIfNeeded() {
        SFSpeechRecognizer.requestAuthorization { status in
            if case .denied = status {
                Task { @MainActor in
                    self.errorMessage = "Speech recognition permission denied. On-device fallback unavailable."
                }
            }
        }
    }

    // MARK: - Private: Actor State Observers

    private func startObserving() {
        // Observe RecorderState stream
        Task { [weak self] in
            guard let self else { return }
            for await state in recorder.stateStream {
                await MainActor.run {
                    switch state {
                    case .recording(let id):
                        self.isRecording   = true
                        self.isPaused      = false
                        self.isInterrupted = false
                        self.currentSessionID = id
                    case .paused:
                        self.isRecording   = false
                        self.isPaused      = true
                        self.isInterrupted = false
                    case .interrupted:
                        self.isRecording   = false
                        self.isInterrupted = true
                    case .stopped, .idle:
                        self.isRecording   = false
                        self.isPaused      = false
                        self.isInterrupted = false
                    case .error(let msg):
                        self.errorMessage = msg
                    }
                }
            }
        }

        // Observe audio level stream
        Task { [weak self] in
            guard let self else { return }
            for await level in recorder.levelStream {
                await MainActor.run { self.audioLevel = level }
            }
        }
    }

    // MARK: - Private: Live Activity Sync

    private func syncLiveActivity() async {
        currentDevice = await recorder.currentInputDeviceName()
        await LiveActivityManager.shared.update(
            stateLabel: recorderStateLabel,
            isRecording: isRecording,
            elapsedSeconds: elapsedSeconds,
            inputDevice: currentDevice,
            transcribedSegments: transcribedSegments,
            totalSegments: totalSegments,
            audioLevel: audioLevel.rms
        )
    }
}

// MARK: - StorageError

nonisolated enum StorageError: LocalizedError {
    case insufficientStorage(freeMB: Int)

    var errorDescription: String? {
        switch self {
        case .insufficientStorage(let mb):
            return "Insufficient storage (\(mb) MB free). Free up space before recording."
        }
    }
}
