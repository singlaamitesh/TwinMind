//
//  TranscriptionService.swift
//  TwinMind
//
//  The consumer side of the audio pipeline.
//
//  Architecture:
//  • Maintains an in-memory queue of pending TranscriptionJob items.
//  • Processes the queue using a TaskGroup so multiple segments fly in parallel
//    while strict result ordering (by segment index) is preserved.
//  • Each attempt uses exponential backoff (up to maxRetries = 5).
//  • If 5 consecutive Deepgram failures occur OR network is unavailable
//    (via NWPathMonitor), falls back to SFSpeechRecognizer.
//  • NWPathMonitor runs on a background actor to avoid blocking.
//

import Foundation
import Speech
import Network
import SwiftData
import AVFoundation

// MARK: - TranscriptionJob

private struct TranscriptionJob: Sendable {
    let segmentID: PersistentIdentifier
    let audioURL:  URL
    let duration:  TimeInterval
    var attempt:   Int = 0
}

// MARK: - TranscriptionService

actor TranscriptionService {

    // ── Config ────────────────────────────────────────────────────────────
    private static let maxRetries           = 5
    private static let maxParallelJobs      = 4   // concurrent Deepgram uploads
    private static let baseBackoffSeconds   = 1.0 // doubles each retry
    private static let maxBackoffSeconds    = 32.0
    private static let defaultSpeechSampleRate = 16_000
    private static let defaultSpeechChannels   = 1

    // ── State ─────────────────────────────────────────────────────────────
    private var jobQueue: [TranscriptionJob] = []
    private var consecutiveFailures: Int = 0
    private var isProcessing = false

    // ── Network monitor ───────────────────────────────────────────────────
    private let networkMonitor = NWPathMonitor()
    private var isNetworkAvailable: Bool = true
    private let monitorQueue = DispatchQueue(label: "com.twinmind.network-monitor")

    // ── Dependencies ──────────────────────────────────────────────────────
    private let dataManager: DataManagerActor
    private let security: SecurityManager

    // ── Speech recognizer (fallback) ──────────────────────────────────────
    private let speechRecognizer: SFSpeechRecognizer?

    // MARK: - Init

    init(dataManager: DataManagerActor, security: SecurityManager) {
        self.dataManager    = dataManager
        self.security       = security
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        startNetworkMonitor()
    }

    // MARK: - Public API

    /// Called by AudioRecorderActor for each completed 30-second chunk.
    func enqueue(segmentID: PersistentIdentifier, audioURL: URL, duration: TimeInterval) async {
        let job = TranscriptionJob(segmentID: segmentID, audioURL: audioURL, duration: duration)
        jobQueue.append(job)
        if !isProcessing {
            isProcessing = true
            Task { await drainQueue() }
        }
    }

    /// Reset failure state — call this at the start of each new recording session
    /// so that a previous session's failures don't poison the new one.
    func resetFailureState() {
        consecutiveFailures = 0
    }

    // MARK: - Private: Queue Drain

    /// Streaming pipeline — keeps exactly `maxParallelJobs` in flight at all times.
    /// As soon as one finishes, the next job from the queue starts immediately.
    /// No batch-level blocking.
    private func drainQueue() async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0

            // Seed initial batch
            while inFlight < TranscriptionService.maxParallelJobs, !jobQueue.isEmpty {
                let job = jobQueue.removeFirst()
                inFlight += 1
                group.addTask { await self.processJob(job) }
            }

            // As each job finishes, start the next one immediately
            for await _ in group {
                inFlight -= 1
                if !jobQueue.isEmpty {
                    let job = jobQueue.removeFirst()
                    inFlight += 1
                    group.addTask { await self.processJob(job) }
                }
            }
        }
        isProcessing = false
    }

    // MARK: - Private: Process Single Job

    private func processJob(_ job: TranscriptionJob) async {
        var currentJob = job

        while currentJob.attempt <= TranscriptionService.maxRetries {
            // ── Network / failure gate ────────────────────────────────────
            let shouldFallback = !isNetworkAvailable
                              || consecutiveFailures >= TranscriptionService.maxRetries

            if shouldFallback {
                print("[TranscriptionService] Falling back to on-device transcription (network=\(isNetworkAvailable), consecutiveFailures=\(consecutiveFailures))")
                await transcribeWithSpeechRecognizer(job: currentJob)
                return
            }

            // ── Exponential back-off (skip delay on first attempt) ────────
            if currentJob.attempt > 1 {
                let delay = min(
                    TranscriptionService.baseBackoffSeconds * pow(2.0, Double(currentJob.attempt - 2)),
                    TranscriptionService.maxBackoffSeconds
                )
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let result = try await transcribeWithDeepgram(job: currentJob)
                // ── Success ───────────────────────────────────────────────
                consecutiveFailures = 0
                print("[TranscriptionService] ✅ Deepgram success — \"\(result.text.prefix(80))\" (confidence: \(result.confidence ?? 0))")
                try await dataManager.markSegmentTranscribed(
                    id: currentJob.segmentID,
                    text: result.text,
                    confidence: result.confidence,
                    usedFallback: false
                )
                return

            } catch let error as TranscriptionError where error == .missingAPIKey {
                // ── Missing API key — skip all retries, fall back immediately ──
                print("[TranscriptionService] No Deepgram API key configured — falling back to on-device transcription.")
                await transcribeWithSpeechRecognizer(job: currentJob)
                return

            } catch {
                consecutiveFailures += 1
                currentJob.attempt  += 1
                print("[TranscriptionService] Deepgram attempt \(currentJob.attempt)/\(TranscriptionService.maxRetries) failed: \(error.localizedDescription)")
                if currentJob.attempt > TranscriptionService.maxRetries {
                    // All Deepgram retries exhausted — try local fallback.
                    print("[TranscriptionService] All retries exhausted — falling back to on-device transcription.")
                    await transcribeWithSpeechRecognizer(job: currentJob)
                    return
                }
            }
        }
    }

    // MARK: - Private: Deepgram Pre-recorded API

    /// Deepgram response models
    private struct DeepgramResponse: Decodable {
        let results: DeepgramResults
    }

    private struct DeepgramResults: Decodable {
        let channels: [DeepgramChannel]
    }

    private struct DeepgramChannel: Decodable {
        let alternatives: [DeepgramAlternative]
    }

    private struct DeepgramAlternative: Decodable {
        let transcript: String
        let confidence: Double
    }

    /// Parsed result used by processJob.
    private struct DeepgramTranscription {
        let text: String
        let confidence: Double?
    }

    private struct DeepgramUploadMetadata {
        let contentType: String
        let encoding: String?
        let sampleRate: Int?
        let channels: Int?
        let payload: Data
    }

    private func transcribeWithDeepgram(job: TranscriptionJob) async throws -> DeepgramTranscription {
        let apiKey: String
        do {
            apiKey = try KeychainManager.read(key: .deepgramAPIKey)
        } catch {
            throw TranscriptionError.missingAPIKey
        }

        let metadata = try await makeDeepgramUpload(for: job.audioURL)

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "language", value: "en")
        ]
        if let encoding = metadata.encoding {
            queryItems.append(URLQueryItem(name: "encoding", value: encoding))
        }
        if let sampleRate = metadata.sampleRate {
            queryItems.append(URLQueryItem(name: "sample_rate", value: String(sampleRate)))
        }
        if let channels = metadata.channels {
            queryItems.append(URLQueryItem(name: "channels", value: String(channels)))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(metadata.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = metadata.payload

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw TranscriptionError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)

        guard let firstChannel = decoded.results.channels.first,
              let bestAlt = firstChannel.alternatives.first else {
            throw TranscriptionError.invalidResponse
        }

        return DeepgramTranscription(
            text: bestAlt.transcript,
            confidence: bestAlt.confidence
        )
    }

    private func makeDeepgramUpload(for sourceURL: URL) async throws -> DeepgramUploadMetadata {
        // Audio segments are already valid WAV files written directly by
        // AudioRecorderActor (raw PCM + WAV header). Just decrypt and send.
        let plainData: Data
        do {
            plainData = try await security.decryptFile(at: sourceURL)
        } catch {
            plainData = try Data(contentsOf: sourceURL)
        }

        guard plainData.count > 44 else {
            print("[TranscriptionService] ⚠️ Audio data too small (\(plainData.count) bytes) for \(sourceURL.lastPathComponent)")
            throw TranscriptionError.invalidResponse
        }

        print("[TranscriptionService] 📦 WAV ready: \(plainData.count) bytes from \(sourceURL.lastPathComponent)")

        return DeepgramUploadMetadata(
            contentType: "audio/wav",
            encoding: nil,
            sampleRate: nil,
            channels: nil,
            payload: plainData
        )
    }

    // MARK: - Private: SFSpeechRecognizer Fallback

    private func transcribeWithSpeechRecognizer(job: TranscriptionJob) async {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            // No local recognizer — mark as transcribed with empty text rather than
            // leaving it permanently stuck in "failed" state.
            try? await dataManager.markSegmentTranscribed(
                id: job.segmentID,
                text: "(No speech recognizer available)",
                confidence: nil,
                usedFallback: true
            )
            return
        }

        do {
            // Decrypt before passing to recognizer
            let plainData: Data
            do {
                plainData = try await security.decryptFile(at: job.audioURL)
            } catch {
                plainData = try Data(contentsOf: job.audioURL)
            }

            // Write plaintext to a temp file for SFSpeechURLRecognitionRequest
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            try plainData.write(to: tempURL, options: .completeFileProtectionUnlessOpen)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let request = SFSpeechURLRecognitionRequest(url: tempURL)
            request.shouldReportPartialResults = false

            let text: String = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                var hasResumed = false
                recognizer.recognitionTask(with: request) { result, error in
                    guard !hasResumed else { return }
                    if let result, result.isFinal {
                        hasResumed = true
                        cont.resume(returning: result.bestTranscription.formattedString)
                    } else if let error {
                        hasResumed = true
                        cont.resume(throwing: error)
                    }
                }
            }

            consecutiveFailures = 0
            try await dataManager.markSegmentTranscribed(
                id: job.segmentID,
                text: text.isEmpty ? "(No speech detected)" : text,
                confidence: nil,
                usedFallback: true
            )

        } catch {
            // "No speech detected" and similar non-fatal errors from SFSpeech
            // should be treated as a successful empty transcription, not a failure.
            let errorDesc = error.localizedDescription.lowercased()
            let isNoSpeech = errorDesc.contains("no speech")
                          || errorDesc.contains("no utterances")
                          || errorDesc.contains("retry")
                          || (error as NSError).domain == "kAFAssistantErrorDomain"

            if isNoSpeech {
                print("[TranscriptionService] SFSpeech: no speech detected — marking as empty transcription")
                try? await dataManager.markSegmentTranscribed(
                    id: job.segmentID,
                    text: "(No speech detected)",
                    confidence: nil,
                    usedFallback: true
                )
            } else {
                print("[TranscriptionService] SFSpeech fallback failed: \(error.localizedDescription)")
                try? await dataManager.markSegmentFailed(
                    id: job.segmentID,
                    error: "Fallback transcription failed: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Private: Network Monitor

    private nonisolated func startNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.updateNetworkStatus(path.status == .satisfied) }
        }
        networkMonitor.start(queue: monitorQueue)
    }

    private func updateNetworkStatus(_ available: Bool) {
        isNetworkAvailable = available
    }

    // MARK: - Offline Queue Retry

    /// Retry all pending/failed segments — called when network becomes available.
    func retryOfflineQueue() async {
        guard isNetworkAvailable else { return }
        do {
            let retryable = try await dataManager.fetchRetryableSegments()
            for seg in retryable {
                guard let relPath = seg.audioFileURL else { continue }
                let url = FileManager.documentsURL.appendingPathComponent(relPath)
                await enqueue(segmentID: seg.persistentModelID,
                              audioURL: url,
                              duration: seg.duration)
            }
        } catch {
            print("[TranscriptionService] Retry queue load failed: \(error)")
        }
    }
}

// MARK: - Errors

nonisolated enum TranscriptionError: LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case httpError(Int, String?)
    case localModelUnavailable

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Deepgram API key not set. Add it in Settings."
        case .invalidResponse:
            return "Invalid response from transcription API."
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                return "Transcription API returned HTTP \(code): \(body)"
            }
            return "Transcription API returned HTTP \(code)."
        case .localModelUnavailable:
            return "Local speech recognizer is unavailable."
        }
    }
}
