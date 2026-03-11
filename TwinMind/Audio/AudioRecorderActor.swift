//
//  AudioRecorderActor.swift
//  TwinMind
//
//  Production-ready audio recording engine built on AVAudioEngine.
//
//  Responsibilities:
//  • Configure & manage AVAudioSession (category, mode, options).
//  • Install an input-node tap for real-time audio capture.
//  • Auto-chunk audio into 30-second segments, write each to an encrypted file.
//  • Calculate RMS / peak power for level-meter visualization.
//  • Handle interruptions (calls, Siri, alarms) and automatically resume.
//  • Handle route changes (headphones in/out, BT connect/disconnect).
//  • Publish state changes via AsyncStream so the UI can observe them.
//

import Foundation
import AVFoundation
import Combine
import SwiftData

// MARK: - Audio Level

/// Passed to the UI every ~100 ms via the level stream.
struct AudioLevel: Sendable {
    let rms: Float   // 0.0 – 1.0 linear (not dB)
    let peak: Float  // 0.0 – 1.0 linear
}

// MARK: - Recorder State

enum RecorderState: Sendable, Equatable {
    case idle
    case recording(sessionID: PersistentIdentifier)
    case paused(sessionID: PersistentIdentifier)
    case interrupted(sessionID: PersistentIdentifier)
    case stopped
    case error(String)
}

// MARK: - AudioRecorderActor

actor AudioRecorderActor {

    // ── Constants ─────────────────────────────────────────────────────────
    private static let chunkDuration: TimeInterval = 30.0
    private static let tapBufferSize: AVAudioFrameCount = 4096

    // ── Engine & nodes ────────────────────────────────────────────────────
    private let engine = AVAudioEngine()
    private var inputFormat: AVAudioFormat?

    // ── Segment state ─────────────────────────────────────────────────────
    private var currentSessionID: PersistentIdentifier?
    private var segmentIndex: Int = 0
    private var segmentStartSampleTime: AVAudioFramePosition = 0
    private var currentSegmentFileHandle: FileHandle?
    private var currentSegmentURL: URL?
    private var currentSegmentFrameCount: Int64 = 0
    private var sessionStartDate: Date = Date()

    // ── Level meter ───────────────────────────────────────────────────────
    private var levelContinuation: AsyncStream<AudioLevel>.Continuation?
    nonisolated var levelStream: AsyncStream<AudioLevel> {
        AsyncStream { continuation in
            Task { await self.setLevelContinuation(continuation) }
        }
    }

    // ── State stream ──────────────────────────────────────────────────────
    private var stateContinuation: AsyncStream<RecorderState>.Continuation?
    nonisolated var stateStream: AsyncStream<RecorderState> {
        AsyncStream { continuation in
            Task { await self.setStateContinuation(continuation) }
        }
    }

    // ── Dependencies ──────────────────────────────────────────────────────
    private let dataManager: DataManagerActor
    private let transcriptionService: TranscriptionService
    private let security: SecurityManager

    // ── Notification observers ────────────────────────────────────────────
    private var interruptionTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?

    // ── Internal state ────────────────────────────────────────────────────
    private var state: RecorderState = .idle {
        didSet { stateContinuation?.yield(state) }
    }
    private var shouldResumeAfterInterruption = false
    /// Guard against concurrent recovery attempts (interruption + route change
    /// can fire simultaneously and both try to reinstall the tap).
    private var isRecovering = false

    // MARK: - Init

    init(dataManager: DataManagerActor,
         transcriptionService: TranscriptionService,
         security: SecurityManager) {
        self.dataManager          = dataManager
        self.transcriptionService = transcriptionService
        self.security             = security
    }

    // MARK: - Public API

    /// Request microphone permission, configure session, start engine.
    func startRecording(title: String = "", quality: AudioQuality = .medium) async throws {
        // Only start if we are idle or already stopped
        switch state {
        case .idle, .stopped: break
        default: return
        }

        // 1. Permission check
        try await requestMicrophonePermission()

        // 2. Create session in DB
        let sessionTitle = title.isEmpty
            ? "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
            : title
        let sessionID = try await dataManager.createSession(title: sessionTitle, quality: quality)
        currentSessionID = sessionID
        segmentIndex     = 0
        sessionStartDate = Date()

        // 3. Configure AVAudioSession
        try await configureAVAudioSession(quality: quality)

        // 4. Start engine + tap (with fallback for format mismatches)
        do {
            try startEngineAndTap(quality: quality)
        } catch {
            print("[AudioRecorderActor] ⚠️ startEngineAndTap failed: \(error) — attempting full restart")
            guard await attemptFullEngineRestart(quality: quality) else {
                throw AudioError.engineStartFailed
            }
        }

        // 5. Register for notifications
        observeInterruptions()
        observeRouteChanges()

        // Track initial input device for smart route change detection
        lastInputPortUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid

        state = .recording(sessionID: sessionID)
        try await dataManager.updateSession(id: sessionID, state: .recording)
    }

    func pauseRecording() async throws {
        guard case .recording(let sessionID) = state else { return }
        engine.pause()
        try await finaliseCurrentSegment()
        state = .paused(sessionID: sessionID)
        try await dataManager.updateSession(id: sessionID, state: .paused)
    }

    func resumeRecording() async throws {
        guard case .paused(let sessionID) = state else { return }
        // Pause finalised the previous segment, so we need a new one.
        segmentIndex += 1

        // Re-derive quality from session
        let sessions = try await dataManager.fetchAllSessions()
        let quality  = sessions.first?.audioQuality ?? .medium

        // Full tear-down and reinstall — during pause, the audio route may have
        // changed (e.g. AirPods switched profiles, headphones plugged in).
        // Just calling engine.start() with the old tap will crash or silently fail.
        try await configureAVAudioSession(quality: quality)
        // startEngineAndTap already does removeTap + engine.stop() + installTap
        do {
            try startEngineAndTap(quality: quality)
        } catch {
            print("[AudioRecorderActor] ⚠️ Resume: startEngineAndTap failed: \(error) — attempting full restart")
            guard await attemptFullEngineRestart(quality: quality) else {
                throw AudioError.engineStartFailed
            }
        }

        state = .recording(sessionID: sessionID)
        try await dataManager.updateSession(id: sessionID, state: .recording)
    }

    func stopRecording() async throws {
        let sessionIDToStop: PersistentIdentifier?
        switch state {
        case .recording(let id), .paused(let id), .interrupted(let id):
            sessionIDToStop = id
        default:
            return
        }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try await finaliseCurrentSegment()
        cancelNotificationObservers()

        let elapsed = Date().timeIntervalSince(sessionStartDate)
        if let id = sessionIDToStop {
            try await dataManager.updateSession(id: id, state: .stopped, duration: elapsed)
        }
        currentSessionID = nil
        state = .stopped
    }

    // MARK: - Private: Permission

    private func requestMicrophonePermission() async throws {
        // iOS 17+: AVAudioApplication
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { throw AudioError.microphonePermissionDenied }
        } else {
            let granted = await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
            guard granted else { throw AudioError.microphonePermissionDenied }
        }
    }

    // MARK: - Private: AVAudioSession Setup

    private func configureAVAudioSession(quality: AudioQuality) async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers]
        )
        // These are HINTS — the hardware may not support the requested rate
        // (e.g., 16 kHz on iPhone hardware that only does 48 kHz).
        // Error -50 is common and non-fatal; the actual format will be
        // determined by the tap buffer in processTapBuffer().
        do { try session.setPreferredSampleRate(quality.sampleRate) }
        catch { print("[AudioRecorderActor] ⚠️ setPreferredSampleRate(\(quality.sampleRate)) unsupported: \(error)") }

        do { try session.setPreferredInputNumberOfChannels(quality.channels) }
        catch { print("[AudioRecorderActor] ⚠️ setPreferredInputNumberOfChannels(\(quality.channels)) unsupported: \(error)") }

        // setActive can also throw -50 on real devices if another app holds
        // the audio session. Retry up to 3 times with a small delay.
        var activated = false
        for attempt in 1...3 {
            do {
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                activated = true
                break
            } catch {
                print("[AudioRecorderActor] ⚠️ setActive attempt \(attempt) failed: \(error)")
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                }
            }
        }
        if !activated {
            throw AudioError.engineStartFailed
        }
    }

    // ── Flag: first buffer opens the segment file ───────────────────────
    private var needsSegmentFileOpen = false

    // MARK: - Private: Engine + Tap

    private func startEngineAndTap(quality: AudioQuality) throws {
        // IMPORTANT: Always remove any existing tap first.
        // If a tap is already installed (e.g. from a previous session or
        // failed cleanup during interruption/route-change), calling installTap
        // again crashes with: 'required condition is false: nullptr == Tap()'
        engine.inputNode.removeTap(onBus: 0)

        // Stop and RESET the engine to clear any cached format graph.
        // Without reset(), the engine keeps the old input device's format
        // (e.g. AirPods 16kHz HFP) and when the new device has a different
        // format (e.g. built-in mic 48kHz), engine.start() fails with
        // error -10868 (kAudioUnitErr_FormatNotSupported).
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()

        // After reset(), we must re-acquire the inputNode reference because
        // reset() can invalidate the old node's internal state.
        let inputNode = engine.inputNode

        // IMPORTANT: Pass `nil` as the tap format so AVAudioEngine delivers
        // buffers in its own native format. On real devices the hardware format
        // varies widely (48 kHz non-interleaved float32 on iPhone, 16 kHz int16
        // on some BT devices, etc.). Requesting a specific format can silently
        // fail or produce mismatched buffers → error -50 on write.
        //
        // Instead, we defer opening the segment file until the FIRST buffer
        // arrives, at which point we know the exact delivered format and can
        // create a perfectly matching WAV file.

        // We'll detect the actual format from the first buffer
        needsSegmentFileOpen = true
        inputFormat = nil   // Clear old format — new device may have different sample rate/channels

        inputNode.installTap(onBus: 0,
                             bufferSize: AudioRecorderActor.tapBufferSize,
                             format: nil) { [weak self] buffer, time in
            guard let self else { return }

            // ─────────────────────────────────────────────────────────────
            // CRITICAL: Capture data NOW on the audio thread.
            // AVAudioEngine reuses/recycles the buffer between callbacks.
            // If we defer to `Task { await actor.process(buffer) }`, by the
            // time the actor runs, the buffer memory is overwritten → empty
            // or corrupt segments, missing chunks.
            // ─────────────────────────────────────────────────────────────
            let format = buffer.format
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            // Capture raw bytes immediately
            let data = Self.captureRawBytes(from: buffer)

            // Compute RMS + Peak immediately
            var sumSquares: Float = 0
            var peak: Float = 0
            if let floatData = buffer.floatChannelData {
                let ptr = floatData[0]
                for i in 0..<frameCount {
                    let s = ptr[i]
                    sumSquares += s * s
                    let a = Swift.abs(s)
                    if a > peak { peak = a }
                }
            } else if let int16Data = buffer.int16ChannelData {
                let ptr = int16Data[0]
                for i in 0..<frameCount {
                    let s = Float(ptr[i]) / Float(Int16.max)
                    sumSquares += s * s
                    let a = Swift.abs(s)
                    if a > peak { peak = a }
                }
            }
            let rms = sqrt(sumSquares / Float(max(frameCount, 1)))

            // Now pass captured (copied) data to the actor — buffer can be recycled safely
            Task {
                await self.handleCapturedBuffer(
                    data: data,
                    format: format,
                    frameCount: frameCount,
                    rms: min(rms, 1.0),
                    peak: min(peak, 1.0),
                    quality: quality
                )
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Full engine restart with async retries: reset → re-acquire node → reinstall tap → prepare → start.
    /// Called when `startEngineAndTap` fails or when the engine needs a complete rebuild
    /// after a device switch (e.g., AirPods → built-in mic or vice versa).
    /// Retries up to 5 times with 500ms delay between attempts to let the audio hardware settle.
    /// Returns true if the engine was successfully started.
    private func attemptFullEngineRestart(quality: AudioQuality) async -> Bool {
        for attempt in 1...5 {
            // Wait before each attempt to let the audio hardware settle
            // The first delay is shorter, subsequent ones are longer
            let delayMs = attempt == 1 ? 300 : 500
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)

            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()

            // Re-acquire inputNode AFTER reset — the old reference is stale
            let freshNode = engine.inputNode
            needsSegmentFileOpen = true
            inputFormat = nil

            // Check if the input node has a valid format now
            let hwFormat = freshNode.inputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                print("[AudioRecorderActor] ⚠️ Full restart attempt \(attempt)/5: input format not ready (sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount))")
                continue
            }

            freshNode.installTap(onBus: 0,
                                 bufferSize: AudioRecorderActor.tapBufferSize,
                                 format: nil) { [weak self] buffer, time in
                guard let self else { return }
                let format = buffer.format
                let frameCount = Int(buffer.frameLength)
                guard frameCount > 0 else { return }
                let data = Self.captureRawBytes(from: buffer)
                var sumSquares: Float = 0
                var peak: Float = 0
                if let floatData = buffer.floatChannelData {
                    let ptr = floatData[0]
                    for i in 0..<frameCount {
                        let s = ptr[i]; sumSquares += s * s
                        let a = Swift.abs(s); if a > peak { peak = a }
                    }
                } else if let int16Data = buffer.int16ChannelData {
                    let ptr = int16Data[0]
                    for i in 0..<frameCount {
                        let s = Float(ptr[i]) / Float(Int16.max); sumSquares += s * s
                        let a = Swift.abs(s); if a > peak { peak = a }
                    }
                }
                let rms = sqrt(sumSquares / Float(max(frameCount, 1)))
                Task {
                    await self.handleCapturedBuffer(
                        data: data, format: format, frameCount: frameCount,
                        rms: min(rms, 1.0), peak: min(peak, 1.0), quality: quality
                    )
                }
            }

            engine.prepare()
            do {
                try engine.start()
                let device = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Unknown"
                print("[AudioRecorderActor] ✅ Full restart succeeded on attempt \(attempt)/5 — using \(device) at \(hwFormat.sampleRate) Hz")
                return true
            } catch {
                print("[AudioRecorderActor] ⚠️ Full restart attempt \(attempt)/5 failed: \(error)")
                // Clean up the tap we just installed before retrying
                freshNode.removeTap(onBus: 0)
            }
        }

        print("[AudioRecorderActor] ❌ Full restart failed after 5 attempts")
        return false
    }

    /// Capture raw sample bytes from an AVAudioPCMBuffer immediately on the audio thread.
    /// This is a `nonisolated static` so it can be called from the tap closure without
    /// awaiting the actor.
    private nonisolated static func captureRawBytes(from buffer: AVAudioPCMBuffer) -> Data {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return Data() }

        let format = buffer.format
        let channels = Int(format.channelCount)

        if format.isInterleaved {
            let abl = buffer.audioBufferList.pointee
            let buf = abl.mBuffers
            guard let ptr = buf.mData else { return Data() }
            return Data(bytes: ptr, count: Int(buf.mDataByteSize))
        } else {
            let bytesPerSample: Int
            switch format.commonFormat {
            case .pcmFormatFloat32: bytesPerSample = 4
            case .pcmFormatFloat64: bytesPerSample = 8
            case .pcmFormatInt16:   bytesPerSample = 2
            case .pcmFormatInt32:   bytesPerSample = 4
            @unknown default:       bytesPerSample = 4
            }

            let totalBytes = frameCount * channels * bytesPerSample
            var interleaved = Data(count: totalBytes)

            interleaved.withUnsafeMutableBytes { rawPtr in
                guard let base = rawPtr.baseAddress else { return }
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for frame in 0..<frameCount {
                    for ch in 0..<channels {
                        let srcBuf = abl[ch]
                        guard let srcPtr = srcBuf.mData else { continue }
                        let srcOffset = frame * bytesPerSample
                        let dstOffset = (frame * channels + ch) * bytesPerSample
                        memcpy(base + dstOffset, srcPtr + srcOffset, bytesPerSample)
                    }
                }
            }
            return interleaved
        }
    }

    // MARK: - Private: Handle Captured Buffer (Actor-Isolated)

    /// Process already-captured audio data. Called from a Task spawned by the tap
    /// callback. The raw bytes and level values were captured on the audio thread
    /// before the buffer could be recycled.
    private func handleCapturedBuffer(
        data: Data,
        format: AVAudioFormat,
        frameCount: Int,
        rms: Float,
        peak: Float,
        quality: AudioQuality
    ) async {

        // ── First buffer: detect format & open file ──────────────────────
        if needsSegmentFileOpen {
            needsSegmentFileOpen = false
            inputFormat = format
            print("[AudioRecorderActor] 🎤 Tap delivers: \(format.sampleRate) Hz, \(format.channelCount) ch, commonFormat=\(format.commonFormat.rawValue), interleaved=\(format.isInterleaved)")
            do {
                try openNewSegmentFile(quality: quality)
            } catch {
                print("[AudioRecorderActor] ❌ Failed to open segment file: \(error)")
                return
            }
        }

        // ── Emit audio level ─────────────────────────────────────────────
        levelContinuation?.yield(AudioLevel(rms: rms, peak: peak))

        // ── Write captured data to file ──────────────────────────────────
        if let handle = currentSegmentFileHandle, !data.isEmpty {
            handle.write(data)
            currentSegmentFrameCount += Int64(frameCount)
        }

        // ── Check 30-second boundary ─────────────────────────────────────
        guard let fmt = inputFormat else { return }
        let chunkFrames = Int64(AudioRecorderActor.chunkDuration * fmt.sampleRate)
        if currentSegmentFrameCount >= chunkFrames {
            await rolloverToNextSegment(quality: quality)
        }
    }

    // MARK: - Private: Segment File Management

    private func openNewSegmentFile(quality: AudioQuality) throws {
        guard let sessionID = currentSessionID else { return }

        // Write as .wav so TranscriptionService can upload directly
        let fileName = "seg_\(sessionID.hashValue)_\(segmentIndex).wav"
        let url      = FileManager.documentsURL
            .appendingPathComponent("AudioSegments", isDirectory: true)
            .appendingPathComponent(fileName)

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let tapFormat = inputFormat else {
            throw AudioError.engineStartFailed
        }

        // Determine PCM parameters from the actual tap format
        let sampleRate = UInt32(tapFormat.sampleRate)
        let channels   = UInt16(tapFormat.channelCount)
        let bitsPerSample: UInt16
        let audioFormat: UInt16  // 1 = PCM integer, 3 = IEEE float
        switch tapFormat.commonFormat {
        case .pcmFormatFloat32:
            bitsPerSample = 32
            audioFormat   = 3     // IEEE float
        case .pcmFormatFloat64:
            bitsPerSample = 64
            audioFormat   = 3
        case .pcmFormatInt16:
            bitsPerSample = 16
            audioFormat   = 1     // PCM integer
        case .pcmFormatInt32:
            bitsPerSample = 32
            audioFormat   = 1
        @unknown default:
            bitsPerSample = 32
            audioFormat   = 3
        }

        let blockAlign    = channels * (bitsPerSample / 8)
        let byteRate      = sampleRate * UInt32(blockAlign)

        // Build a 44-byte canonical WAV header with placeholder sizes.
        // Sizes will be patched in finaliseCurrentSegment().
        var header = Data(count: 44)
        header.withUnsafeMutableBytes { buf in
            let p = buf.baseAddress!

            // RIFF header
            memcpy(p,      "RIFF", 4)
            // ChunkSize — placeholder (will patch later)
            var chunkSize: UInt32 = 0
            memcpy(p + 4,  &chunkSize, 4)
            memcpy(p + 8,  "WAVE", 4)

            // fmt sub-chunk
            memcpy(p + 12, "fmt ", 4)
            var fmtSize: UInt32 = 16
            memcpy(p + 16, &fmtSize, 4)
            var af = audioFormat
            memcpy(p + 20, &af, 2)
            var ch = channels
            memcpy(p + 22, &ch, 2)
            var sr = sampleRate
            memcpy(p + 24, &sr, 4)
            var br = byteRate
            memcpy(p + 28, &br, 4)
            var ba = blockAlign
            memcpy(p + 32, &ba, 2)
            var bps = bitsPerSample
            memcpy(p + 34, &bps, 2)

            // data sub-chunk
            memcpy(p + 36, "data", 4)
            // DataSize — placeholder (will patch later)
            var dataSize: UInt32 = 0
            memcpy(p + 40, &dataSize, 4)
        }

        // Create the file and write the header
        FileManager.default.createFile(atPath: url.path, contents: header)
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()

        currentSegmentFileHandle = handle
        currentSegmentURL        = url
        currentSegmentFrameCount = 0

        print("[AudioRecorderActor] 📁 Opened WAV segment: \(fileName), \(sampleRate) Hz, \(channels) ch, \(bitsPerSample) bit, format=\(audioFormat == 3 ? "float" : "int")")
    }

    /// Patch the WAV header with final sizes after recording is done.
    private func patchWAVHeader(handle: FileHandle, dataByteCount: UInt32) {
        // Patch RIFF ChunkSize at offset 4
        let riffSize = dataByteCount + 36  // 44 - 8
        handle.seek(toFileOffset: 4)
        var rs = riffSize
        handle.write(Data(bytes: &rs, count: 4))

        // Patch data SubChunkSize at offset 40
        handle.seek(toFileOffset: 40)
        var ds = dataByteCount
        handle.write(Data(bytes: &ds, count: 4))
    }

    private func rolloverToNextSegment(quality: AudioQuality) async {
        // ── FAST PATH: close current file + open next, no async work ──────
        // This must be as fast as possible so the actor doesn't block and
        // drop incoming audio buffers while doing encryption/DB/network.
        guard
            let sessionID = currentSessionID,
            let url       = currentSegmentURL,
            let handle    = currentSegmentFileHandle,
            let fmt       = inputFormat
        else { return }

        let frameCount = currentSegmentFrameCount
        let segIdx     = segmentIndex

        // Compute data byte count for WAV header patching
        let bytesPerSample: UInt32
        switch fmt.commonFormat {
        case .pcmFormatFloat32: bytesPerSample = 4
        case .pcmFormatFloat64: bytesPerSample = 8
        case .pcmFormatInt16:   bytesPerSample = 2
        case .pcmFormatInt32:   bytesPerSample = 4
        @unknown default:       bytesPerSample = 4
        }
        let dataByteCount = UInt32(frameCount) * UInt32(fmt.channelCount) * bytesPerSample

        // Patch WAV header & close file — synchronous, fast
        patchWAVHeader(handle: handle, dataByteCount: dataByteCount)
        try? handle.synchronizeFile()
        try? handle.close()

        // Clear current segment state immediately
        currentSegmentFileHandle = nil
        currentSegmentURL        = nil
        currentSegmentFrameCount = 0

        // Open next segment file immediately (synchronous) so no buffers are lost
        segmentIndex += 1
        do {
            try openNewSegmentFile(quality: quality)
        } catch {
            print("[AudioRecorderActor] ❌ Rollover: failed to open next segment: \(error)")
        }

        // ── SLOW PATH: encryption, DB, transcription — fire-and-forget ────
        let duration  = Double(frameCount) / fmt.sampleRate
        let startTime = Double(segIdx) * AudioRecorderActor.chunkDuration

        print("[AudioRecorderActor] 📼 Finalising segment \(segIdx): \(frameCount) frames, \(String(format: "%.1f", duration))s, url=\(url.lastPathComponent)")

        guard frameCount > 0 else {
            print("[AudioRecorderActor] ⚠️ Segment \(segIdx) has 0 frames — skipping")
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Do heavy work in detached task — doesn't block the actor
        let security = self.security
        let dataManager = self.dataManager
        let transcriptionService = self.transcriptionService

        Task.detached(priority: .utility) {
            // Encrypt
            let encryptedURL: URL
            do {
                encryptedURL = try await security.encryptFile(at: url)
                try? FileManager.default.removeItem(at: url)
            } catch {
                encryptedURL = url
                print("[AudioRecorderActor] Encryption failed: \(error)")
            }

            // Store in DB
            let relPath = "AudioSegments/" + encryptedURL.lastPathComponent
            do {
                let segID = try await dataManager.insertSegment(
                    sessionID: sessionID,
                    index: segIdx,
                    startTime: startTime,
                    duration: duration,
                    audioFileURL: relPath
                )

                // Enqueue transcription
                await transcriptionService.enqueue(
                    segmentID: segID,
                    audioURL: encryptedURL,
                    duration: duration
                )
            } catch {
                print("[AudioRecorderActor] Rollover DB/transcription error: \(error)")
            }
        }
    }

    /// Close the current segment file, encrypt it, register it in the DB,
    /// and hand it off to the transcription service.
    private func finaliseCurrentSegment() async throws {
        guard
            let sessionID = currentSessionID,
            let url       = currentSegmentURL,
            let handle    = currentSegmentFileHandle,
            let fmt       = inputFormat
        else { return }

        let frameCount = currentSegmentFrameCount

        // Compute data byte count for WAV header patching
        let bytesPerSample: UInt32
        switch fmt.commonFormat {
        case .pcmFormatFloat32: bytesPerSample = 4
        case .pcmFormatFloat64: bytesPerSample = 8
        case .pcmFormatInt16:   bytesPerSample = 2
        case .pcmFormatInt32:   bytesPerSample = 4
        @unknown default:       bytesPerSample = 4
        }
        let dataByteCount = UInt32(frameCount) * UInt32(fmt.channelCount) * bytesPerSample

        // Patch the WAV header with correct sizes
        patchWAVHeader(handle: handle, dataByteCount: dataByteCount)

        // Close the file
        try? handle.synchronizeFile()
        try? handle.close()
        currentSegmentFileHandle = nil
        currentSegmentURL        = nil
        currentSegmentFrameCount = 0

        let duration  = Double(frameCount) / fmt.sampleRate
        let startTime = Double(segmentIndex) * AudioRecorderActor.chunkDuration

        print("[AudioRecorderActor] 📼 Finalising segment \(segmentIndex): \(frameCount) frames, \(String(format: "%.1f", duration))s, url=\(url.lastPathComponent)")

        // Skip empty segments (can happen on very short pause/stop)
        guard frameCount > 0 else {
            print("[AudioRecorderActor] ⚠️ Segment \(segmentIndex) has 0 frames — skipping")
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Encrypt the WAV file on disk
        let encryptedURL: URL
        do {
            encryptedURL = try await security.encryptFile(at: url)
            // Delete the plaintext version
            try? FileManager.default.removeItem(at: url)
        } catch {
            // If encryption fails, keep plaintext and continue
            encryptedURL = url
            print("[AudioRecorderActor] Encryption failed: \(error)")
        }

        // Store the relative path including the AudioSegments folder
        let relPath = "AudioSegments/" + encryptedURL.lastPathComponent
        let segID   = try await dataManager.insertSegment(
            sessionID: sessionID,
            index: segmentIndex,
            startTime: startTime,
            duration: duration,
            audioFileURL: relPath
        )

        // Hand off to transcription pipeline (fire-and-forget — it manages its own queue)
        Task.detached(priority: .utility) { [weak transcriptionService] in
            await transcriptionService?.enqueue(
                segmentID: segID,
                audioURL: encryptedURL,
                duration: duration
            )
        }
    }

    // MARK: - Private: Interruption Handling

    private func observeInterruptions() {
        interruptionTask?.cancel()
        interruptionTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification
            )
            for await notification in notifications {
                await self?.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) async {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch interruptionType {
        case .began:
            // Interruption started (e.g. phone call, Siri)
            if case .recording(let id) = state {
                engine.pause()
                try? await finaliseCurrentSegment()
                // Increment segment index so the next segment after resume
                // gets a new index and file name.
                segmentIndex += 1
                state = .interrupted(sessionID: id)
                try? await dataManager.updateSession(id: id, state: .interrupted)
                print("[AudioRecorderActor] ⚡ Interrupted — segment \(segmentIndex - 1) finalised, waiting for resume")
            }
            shouldResumeAfterInterruption = true

        case .ended:
            guard shouldResumeAfterInterruption else { return }
            shouldResumeAfterInterruption = false

            // Guard: if route-change handler is already recovering, skip
            guard !isRecovering else {
                print("[AudioRecorderActor] ⏭️ Skipping interruption resume — recovery already in progress")
                return
            }

            // Always try to resume if we were interrupted — some interruptions
            // (Siri, brief calls) don't set .shouldResume but the session is
            // still recoverable. If it truly can't resume, the catch handles it.
            guard case .interrupted(let id) = state else { return }
            isRecovering = true
            defer {
                isRecovering = false
                // Update tracked port UID — device may have changed during interruption
                lastInputPortUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
                lastRouteRecoveryTime = Date()
            }
            do {
                // iOS may have torn down the audio graph during the interruption.
                // Remove the old tap and reinstall a fresh one to guarantee
                // buffer delivery resumes correctly.
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)

                // Re-derive quality from session
                let sessions = try await dataManager.fetchAllSessions()
                let quality  = sessions.first?.audioQuality ?? .medium

                try await configureAVAudioSession(quality: quality)

                // Reinstall tap — this will also open a new segment file
                // on the first buffer (needsSegmentFileOpen = true inside startEngineAndTap)
                do {
                    try startEngineAndTap(quality: quality)
                } catch {
                    print("[AudioRecorderActor] ⚠️ Interruption resume: startEngineAndTap failed: \(error) — attempting full restart")
                    guard await attemptFullEngineRestart(quality: quality) else {
                        state = .error("Failed to resume after interruption: engine restart failed")
                        return
                    }
                }

                state = .recording(sessionID: id)
                try await dataManager.updateSession(id: id, state: .recording)
                print("[AudioRecorderActor] ▶️ Resumed after interruption — new segment \(segmentIndex)")
            } catch {
                state = .error("Failed to resume after interruption: \(error.localizedDescription)")
            }

        @unknown default:
            break
        }
    }

    // MARK: - Private: Route Change Handling

    private func observeRouteChanges() {
        routeChangeTask?.cancel()
        routeChangeTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification
            )
            for await notification in notifications {
                await self?.handleRouteChange(notification)
            }
        }
    }

    /// Timestamp of the last route-change recovery to debounce rapid-fire notifications
    private var lastRouteRecoveryTime: Date = .distantPast
    /// Track the last known input port UID to detect *actual* device changes
    /// vs. cosmetic route notifications that don't need a tap restart.
    private var lastInputPortUID: String?

    private func handleRouteChange(_ notification: Notification) async {
        guard
            let info   = notification.userInfo,
            let reason = info[AVAudioSessionRouteChangeReasonKey] as? UInt
        else { return }

        let routeReason = AVAudioSession.RouteChangeReason(rawValue: reason)

        // Log every route change for diagnostics
        var currentInput = AVAudioSession.sharedInstance().currentRoute.inputs.first
        let deviceName = currentInput?.portName ?? "none"
        let portType = currentInput?.portType.rawValue ?? "unknown"
        print("[AudioRecorderActor] 🔀 Route change: reason=\(reason) (\(routeReasonName(routeReason))), device=\(deviceName) (\(portType))")

        switch routeReason {
        case .oldDeviceUnavailable,    // headphones/BT unplugged/disconnected
             .newDeviceAvailable,       // headphones/BT plugged in/connected
             .routeConfigurationChange, // BT profile switch (A2DP ↔ HFP)
             .categoryChange:           // audio category changed by system

            // Only act if we're currently recording or interrupted
            let sessionID: PersistentIdentifier
            switch state {
            case .recording(let id):
                sessionID = id
            case .interrupted(let id):
                sessionID = id
            default:
                return
            }

            // ── Wait for input device if none is available ────────────────
            // During BT profile switches (e.g., AirPods A2DP → HFP for a call),
            // iOS fires .categoryChange with NO input device momentarily.
            // Wait up to 2 seconds for a device to appear before giving up.
            if currentInput == nil {
                print("[AudioRecorderActor] ⏳ No input device — waiting for system to settle…")
                var deviceAppeared = false
                for attempt in 1...4 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    currentInput = AVAudioSession.sharedInstance().currentRoute.inputs.first
                    if currentInput != nil {
                        print("[AudioRecorderActor] ✅ Input device appeared after \(attempt * 500)ms: \(currentInput!.portName)")
                        deviceAppeared = true
                        break
                    }
                }
                if !deviceAppeared {
                    print("[AudioRecorderActor] ⏭️ No input device after 2s — skipping (will recover on next notification)")
                    return
                }
            }

            // Smart detection: only restart if the actual input device changed.
            // Many BT route changes are cosmetic (e.g., output switch) and
            // don't affect the input tap.
            let newPortUID = currentInput?.uid
            if let newPortUID, newPortUID == lastInputPortUID,
               routeReason != .oldDeviceUnavailable {
                print("[AudioRecorderActor] ⏭️ Same input device (\(currentInput?.portName ?? "?")) — skipping tap restart")
                return
            }

            // Debounce: skip if another route recovery happened within 1 second
            let now = Date()
            guard now.timeIntervalSince(lastRouteRecoveryTime) > 1.0 else {
                print("[AudioRecorderActor] ⏭️ Debouncing route change — too soon after last recovery")
                return
            }

            // Guard: if interruption handler is already recovering, skip
            guard !isRecovering else {
                print("[AudioRecorderActor] ⏭️ Skipping route change recovery — recovery already in progress")
                return
            }
            isRecovering = true
            defer {
                isRecovering = false
                lastRouteRecoveryTime = Date()
                // Update tracked port UID
                lastInputPortUID = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
            }

            do {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)

                // Only finalize if we were recording (not if we were interrupted)
                if case .recording = state {
                    try? await finaliseCurrentSegment()
                    segmentIndex += 1
                }

                // Re-derive quality from session
                let sessions = try await dataManager.fetchAllSessions()
                let quality  = sessions.first?.audioQuality ?? .medium
                try await configureAVAudioSession(quality: quality)
                do {
                    try startEngineAndTap(quality: quality)
                } catch {
                    print("[AudioRecorderActor] ⚠️ Route change: startEngineAndTap failed: \(error) — attempting full restart")
                    guard await attemptFullEngineRestart(quality: quality) else {
                        state = .error("Route change recovery failed: engine restart failed")
                        return
                    }
                }
                state = .recording(sessionID: sessionID)

                let newDevice = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Unknown"
                print("[AudioRecorderActor] 🔄 Route change recovered — now using \(newDevice), segment \(segmentIndex)")
            } catch {
                state = .error("Route change recovery failed: \(error.localizedDescription)")
            }

        default:
            break
        }
    }

    /// Human-readable name for route change reasons (for logging)
    private func routeReasonName(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .unknown:                  return "unknown"
        case .newDeviceAvailable:       return "newDeviceAvailable"
        case .oldDeviceUnavailable:     return "oldDeviceUnavailable"
        case .categoryChange:           return "categoryChange"
        case .override:                 return "override"
        case .wakeFromSleep:            return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "routeConfigurationChange"
        default:                        return "other(\(reason?.rawValue ?? 99))"
        }
    }

    // MARK: - Private: Helpers

    private func cancelNotificationObservers() {
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
        interruptionTask = nil
        routeChangeTask  = nil
    }

    private func setLevelContinuation(_ cont: AsyncStream<AudioLevel>.Continuation) {
        levelContinuation = cont
    }

    private func setStateContinuation(_ cont: AsyncStream<RecorderState>.Continuation) {
        stateContinuation = cont
    }

    // MARK: - Current Input Device Name

    /// Returns the human-readable name of the currently active input port
    /// (e.g. "AirPods Pro", "iPhone Microphone").
    func currentInputDeviceName() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.inputs.first?.portName ?? "Unknown"
    }
}

// MARK: - AudioError

nonisolated enum AudioError: LocalizedError {
    case microphonePermissionDenied
    case engineStartFailed
    case fileCreationFailed
    case noActiveSession

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: return "Microphone access was denied. Please enable it in Settings."
        case .engineStartFailed:          return "The audio engine failed to start."
        case .fileCreationFailed:         return "Could not create the audio segment file."
        case .noActiveSession:            return "No active recording session."
        }
    }
}
