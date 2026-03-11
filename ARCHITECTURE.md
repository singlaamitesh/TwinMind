# TwinMind — Architecture Document

## 1. System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       iOS App Process                        │
│                                                              │
│  ┌──────────────────────── @MainActor ─────────────────────┐ │
│  │  AppState (@Observable)                                  │ │
│  │  • isRecording / isPaused / isInterrupted               │ │
│  │  • elapsedSeconds, audioLevel                           │ │
│  │  • transcribedSegments / totalSegments                  │ │
│  │  • errorMessage                                         │ │
│  │                                                          │ │
│  │  SwiftUI Views ──────► AppState.startRecording()        │ │
│  │  LiveActivityManager ◄── AppState (synced every 1 s)    │ │
│  │  App Intents ────────► AppState (singleton bridge)      │ │
│  └─────────────────────────────┬────────────────────────────┘ │
│                                │ async/await                   │
│         ┌──────────────────────┼───────────────┐              │
│         ▼                      ▼               ▼              │
│  ┌─────────────┐      ┌────────────────┐  ┌──────────────┐   │
│  │ AudioRecorder│     │ Transcription  │  │ DataManager  │   │
│  │ Actor        │────►│ Service (Actor)│─►│ Actor        │   │
│  └──────┬───────┘     └───────┬────────┘  │ @ModelActor  │   │
│         │                     │           └──────┬───────┘   │
│         │ encryptFile()        │ decryptFile()    │           │
│         └──────────────────┬──┘           SwiftData store     │
│                            ▼                                   │
│                  ┌──────────────────┐                         │
│                  │ SecurityManager  │                         │
│                  │ Actor            │                         │
│                  │ AES-256-GCM      │                         │
│                  │ Keychain         │                         │
│                  └──────────────────┘                         │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Audio System Design

### Session Configuration

```swift
AVAudioSession.setCategory(.playAndRecord,
    mode: .default,
    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker, .mixWithOthers])
```

The `.mixWithOthers` option allows other audio (music, navigation) to continue while TwinMind records. The `.allowBluetooth` / `.allowBluetoothA2DP` options ensure AirPods and other BT devices are preferred automatically.

### 30-Second Chunk Pipeline

```
AVAudioEngine.inputNode
       │  (tap buffer, ~100ms per call)
       ▼
processTapBuffer()
  ├── RMS/Peak power → AsyncStream<AudioLevel> → UI
  └── AVAudioFile.write(from:)
              │
              ▼ (every 30 s of frames)
       rolloverToNextSegment()
         1. finaliseCurrentSegment()
              a. Close AVAudioFile (flush)
              b. SecurityManager.encryptFile() → .enc file
              c. Delete plaintext
              d. DataManagerActor.insertSegment()
              e. TranscriptionService.enqueue()
         2. openNewSegmentFile()  ← starts next chunk
```

### Interruption Recovery State Machine

```
              ┌─────────┐
              │  IDLE   │
              └────┬────┘
                   │ startRecording()
                   ▼
        ┌──────────────────┐   pauseRecording()   ┌────────┐
        │    RECORDING     │─────────────────────►│ PAUSED │
        └────────┬─────────┘                       └───┬────┘
                 │                                     │
     interruptionBegan                          resumeRecording()
                 │                                     │
                 ▼                                     │
        ┌─────────────────┐                           │
        │  INTERRUPTED    │──── interruptionEnded ────►back to RECORDING
        └─────────────────┘     (shouldResume=true)
```

### Route Change Handling

| Reason | Action |
|---|---|
| `oldDeviceUnavailable` | Stop engine, finalise segment, re-configure AVAudioSession, restart tap with new hardware format |
| `newDeviceAvailable` | No restart needed; engine continues; UI `currentDevice` label refreshed |
| Other | No-op |

---

## 3. SwiftData Schema & Performance

### Entity Relationship

```
RecordingSession (1) ────── (N) TranscriptionSegment
  @Attribute(.unique) id            @Attribute(.unique) id
  @Attribute(.indexed) createdAt    @Attribute(.indexed) index
  title                             startTime
  stateRaw                          duration
  duration                          statusRaw
  audioQualityRaw                   transcriptionText
  audioFileURL                      confidence
  totalSegments                     retryCount
  transcribedSegments               usedFallback
  segments: [TranscriptionSegment]  session: RecordingSession?
```

### Performance Optimisations

| Technique | Implementation |
|---|---|
| `@Attribute(.indexed)` | Applied to `RecordingSession.createdAt` and `TranscriptionSegment.index` — enables O(log n) range queries |
| `@ModelActor` | Dedicated background ModelContext; zero UI-thread contention |
| Batch saves | `batchInsertSegments()` inserts N items then calls `modelContext.save()` once |
| `fetchLimit = 500` | `fetchSegments()` paginates to avoid loading 10 k+ rows into memory at once |
| `FetchDescriptor` predicates | Raw `statusRaw` string comparison avoids computed-property overhead in predicates |
| Cascade delete | `@Relationship(deleteRule: .cascade)` — deleting a session removes all segments in one operation |

---

## 4. Transcription Pipeline

```
AudioRecorderActor
     │ enqueue(segmentID:audioURL:duration:)
     ▼
TranscriptionService (Actor)
  jobQueue: [TranscriptionJob]
     │
     ▼  drainQueue()
  withTaskGroup(of: Void.self)  ← up to 4 concurrent jobs
     │
     ▼  processJob(_:)
  ┌──────────────────────────────────────────────┐
  │  attempt 0–5                                 │
  │   ├── isNetworkAvailable? (NWPathMonitor)    │
  │   ├── consecutiveFailures ≥ 5?               │
  │   │     └── YES → transcribeWithSpeechRecognizer()
  │   │                                          │
  │   ├── exponential backoff sleep              │
   │   └── transcribeWithDeepgram()                │
  │         ├── SUCCESS: markSegmentTranscribed  │
  │         └── FAILURE: attempt++               │
  │              └── attempt > 5:                │
  │                    transcribeWithSpeechRecognizer()
  └──────────────────────────────────────────────┘
```

### Deepgram API Request

- Endpoint: `POST https://api.deepgram.com/v1/listen?model=nova-2&smart_format=true&punctuate=true&language=en`
- Body: Raw audio bytes (no multipart)
- Content-Type: `audio/wav`
- Response: JSON with `results.channels[0].alternatives[0].transcript` and `.confidence`
- Auth: `Authorization: Token <key-from-keychain>`

---

## 5. Security Architecture

```
Audio file (plaintext .caf)
        │
        ▼ SecurityManager.encryptFile(at:)
  AES.GCM.seal(data, using: symmetricKey)
        │
        ▼
  .caf.enc  (nonce ++ ciphertext ++ tag, written with .completeFileProtectionUnlessOpen)
        │
        ▼  plaintext deleted immediately
```

The 256-bit symmetric key is generated once and stored as a base64 string under `com.twinmind.encryption.key` in the Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — meaning it is device-bound and never backed up to iCloud.

The Deepgram API key is stored similarly under `com.twinmind.deepgram.apikey`.

---

## 6. Live Activity Data Flow

```
AppState (Timer fires every 1 s)
    │
    ├── recorder.currentInputDeviceName()   ← from AVAudioSession.currentRoute
    │
    └── LiveActivityManager.update(
            stateLabel:        "Recording"
            isRecording:       true
            elapsedSeconds:    42
            inputDevice:       "AirPods Pro"
            transcribedSeg:    3
            totalSeg:          5
            audioLevel:        0.42         ← latest RMS from AudioRecorderActor
        )
            │
            └── Activity<RecordingActivityAttributes>.update(...)
                    ├── Dynamic Island Compact: [●] [00:42]
                    ├── Dynamic Island Expanded: title, state, timer, device, progress, level bar
                    └── Lock Screen Banner: same content in full-width layout
```

---

## 7. App Intents Integration

Both intents resolve through `AppState.shared` (a `@MainActor` singleton). This ensures that a Siri invocation from the background has the same effect as a button tap in the UI — the `isRecording` flag, the Live Activity, the timer, and the actor states all update atomically.

```
Siri: "Start recording with TwinMind"
    │
    └── StartRecordingIntent.perform()
            └── AppState.shared.startRecording(title:quality:)
                    ├── AudioRecorderActor.startRecording()
                    ├── LiveActivityManager.startActivity()
                    └── elapsedTimer starts
```
