# TwinMind — Audio Intelligence App

> A production-ready iOS audio recording app that records, transcribes in real time, and persists everything with SwiftData — designed to survive every real-world interruption.

---

## Table of Contents
1. [Features](#features)
2. [Requirements](#requirements)
3. [Setup](#setup)
4. [Project Structure](#project-structure)
5. [Architecture Overview](#architecture-overview)
6. [Configuration](#configuration)
7. [Running Tests](#running-tests)
8. [Known Issues & Limitations](#known-issues--limitations)

---

## Features

| Pillar | Details |
|---|---|
| **Audio Engine** | AVAudioEngine tap → 30-second chunking, RMS/Peak level meters, interruption + route-change recovery |
| **Transcription** | Deepgram Nova-2 API with exponential backoff; 5-failure fallback to SFSpeechRecognizer; NWPathMonitor offline queue |
| **Persistence** | SwiftData `@ModelActor` (DataManagerActor) — `RecordingSession ↔ TranscriptionSegment` (1:N), indexed queries, batch saves |
| **Live Activity** | Dynamic Island + Lock Screen showing live timer, input device, transcription progress, audio level bar |
| **App Intents** | `StartRecordingIntent` + `StopRecordingIntent` wired to Siri & Shortcuts |
| **Security** | AES-256-GCM file encryption (CryptoKit), API key in iOS Keychain |
| **UI** | TabView (Record / History), session search, segment detail with copy/export, real-time waveform, VoiceOver labels |

---

## Requirements

- Xcode 16+
- iOS 17.0+ deployment target
- Swift 5.10+
- A **Deepgram API key** (sign up at [console.deepgram.com](https://console.deepgram.com))

### Entitlements needed in Xcode

Add the following to the app's entitlements:

```xml
<!-- Background Modes -->
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>processing</string>
</array>

<!-- Live Activities -->
<key>NSSupportsLiveActivities</key>
<true/>
<key>NSSupportsLiveActivitiesFrequentUpdates</key>
<true/>
```

### Info.plist keys

```xml
<key>NSMicrophoneUsageDescription</key>
<string>TwinMind records audio to provide real-time transcription.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>TwinMind uses on-device speech recognition as a transcription fallback.</string>
```

---

## Setup

```bash
# 1. Clone the repo
git clone https://github.com/your-username/TwinMind.git
cd TwinMind

# 2. Open in Xcode
open TwinMind.xcodeproj

# 3. Select your development team in Signing & Capabilities

# 4. Build & run on a physical device (AVAudioEngine requires real hardware for full testing)
```

### Adding your Deepgram API key

The app provides a **Settings** screen (gear icon in the top-right) where you paste your Deepgram key. It is immediately encrypted and stored in the iOS Keychain — never in `UserDefaults` or any plain-text file.

Alternatively, seed it programmatically (e.g. in a test scheme's launch argument):

```swift
try KeychainManager.save("YOUR-DEEPGRAM-KEY", for: .deepgramAPIKey)
```

---

## Project Structure

```
TwinMind/
├── Models/
│   ├── RecordingSession.swift        # @Model — root entity
│   └── TranscriptionSegment.swift   # @Model — 30-second chunk
│
├── Data/
│   └── DataManagerActor.swift       # @ModelActor — all SwiftData I/O
│
├── Audio/
│   └── AudioRecorderActor.swift     # Actor — AVAudioEngine, chunking, recovery
│
├── Transcription/
│   └── TranscriptionService.swift   # Actor — Deepgram, backoff, SFSpeech fallback
│
├── Security/
│   └── KeychainManager.swift        # Keychain wrapper + AES-256-GCM (SecurityManager)
│
├── LiveActivity/
│   ├── RecordingActivityAttributes.swift   # ActivityKit schema
│   ├── LiveActivityManager.swift           # start / update / end lifecycle
│   └── RecordingLiveActivityView.swift     # Dynamic Island + Lock Screen UI
│
├── AppIntents/
│   └── RecordingIntents.swift       # StartRecordingIntent, StopRecordingIntent
│
├── UI/
│   ├── ViewModels/
│   │   └── AppState.swift           # @Observable coordinator (@MainActor)
│   └── Views/
│       ├── ContentView.swift        # TabView root
│       ├── RecordingView.swift      # Record tab
│       ├── SessionListView.swift    # History tab
│       ├── SessionDetailView.swift  # Per-session segments + transcript export
│       └── SettingsView.swift       # API key, quality, storage cleanup
│
└── TwinMindTests/
    ├── DataManagerActorTests.swift  # In-memory SwiftData CRUD
    ├── AudioRecorderActorTests.swift # State machine + model tests
    ├── TranscriptionServiceTests.swift # Backoff math + error descriptions
    └── PerformanceTests.swift       # 10 k segment insert/fetch + 1-hour memory
```

---

## Architecture Overview

```
┌─────────────────── @MainActor ───────────────────────────────┐
│  AppState (@Observable)                                       │
│  ┌──────────┐  ┌────────────────┐  ┌──────────────────────┐  │
│  │  SwiftUI │  │ LiveActivity   │  │  App Intents         │  │
│  │  Views   │◄─│ Manager        │  │  (Siri/Shortcuts)    │  │
│  └──────────┘  └────────────────┘  └──────────────────────┘  │
└──────────────────────────┬───────────────────────────────────┘
                           │ async/await
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
  ┌───────────────┐ ┌─────────────────┐ ┌────────────────────┐
  │ AudioRecorder │ │ Transcription   │ │ DataManager        │
  │ Actor         │─► Service (Actor) │─► Actor (@ModelActor)│
  │               │ │                 │ │                    │
  │ AVAudioEngine │ │ Deepgram Nova-2 │ │ SwiftData          │
  │ 30s chunking  │ │ + SFSpeech fall │ │ RecordingSession   │
  │ RMS levels    │ │ + NWPathMonitor │ │ TranscriptionSeg.  │
  └───────────────┘ └─────────────────┘ └────────────────────┘
          │                                       ▲
          │         AES-256-GCM                   │
          └──────► SecurityManager (Actor) ───────┘
                   Keychain (API key + enc key)
```

### Key Decisions

| Decision | Rationale |
|---|---|
| Actor per subsystem | Eliminates data races; each actor owns its state exclusively |
| `@ModelActor` for SwiftData | Apple-recommended pattern; gives a dedicated ModelContext on a background queue; prevents UI jank |
| AsyncStream for state/levels | Provides backpressure-safe, structured-concurrency-friendly pub/sub between actors and the UI |
| Hybrid transcription | Deepgram Nova-2 gives highest accuracy; SFSpeechRecognizer ensures the app degrades gracefully offline or on repeated failures |
| AES-256-GCM per file | Each audio segment is independently encrypted at rest; key is device-bound (Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) |
| ActivityKit (not push) | Gives sub-second Dynamic Island updates for timer/level without a server round-trip |

---

## Configuration

### Audio Quality

| Preset | Sample Rate | Channels | Best For |
|---|---|---|---|
| Low | 8 kHz | Mono | Phone calls, low storage |
| **Medium** (default) | **16 kHz** | **Mono** | **Speech transcription** |
| High | 44.1 kHz | Stereo | Music, interviews |

### Transcription Backoff

| Attempt | Delay |
|---|---|
| 1 | 1 s |
| 2 | 2 s |
| 3 | 4 s |
| 4 | 8 s |
| 5 | 16 s |
| 6+ | 32 s (max) |

After 5 consecutive failures, the service switches to SFSpeechRecognizer for all subsequent segments until the next app launch.

---

## Running Tests

```bash
# Run all unit tests
xcodebuild test \
  -scheme TwinMind \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:TwinMindTests

# Run only performance tests
xcodebuild test \
  -scheme TwinMind \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:TwinMindTests/PerformanceTests
```

### Test Coverage

| Test File | What It Covers |
|---|---|
| `DataManagerActorTests` | CRUD, search, retry queue — in-memory store |
| `AudioRecorderActorTests` | RecordingState machine, AudioQuality properties, AudioLevel |
| `TranscriptionServiceTests` | Exponential backoff formula, segment status transitions, error descriptions |
| `PerformanceTests` | 10 k batch insert/fetch, 1-hour simulation memory delta |

---

## Known Issues & Limitations

1. **Simulator microphone** — `AVAudioEngine` returns silence on most simulators; test audio capture on a physical device.
2. **Background time limit** — iOS grants ~3 minutes of background processing for tasks without the `audio` background mode. Ensure the `UIBackgroundModes: audio` entitlement is active to record indefinitely.
3. **SFSpeechRecognizer quota** — Apple limits on-device speech recognition to ~1 minute per utterance and imposes daily request caps. Long sessions will be split correctly by the 30 s chunking, but very high traffic may hit the rate limit.
4. **Live Activity widget target** — `RecordingLiveActivityView` must be added to a separate **Widget Extension** target in Xcode. The current code resides in the main app target for clarity; move it to a `TwinMindWidgets` extension before submission.
5. **Deepgram audio format** — Deepgram accepts most audio formats including `wav`, `mp3`, `m4a`, `flac`, `ogg`, etc. The current implementation uploads CAF (PCM) with `audio/wav` content type. Consider converting with `AVAssetExportSession` to reduce upload size on low-quality networks.
6. **No iCloud sync** — SwiftData is configured for local storage only. Adding `ModelConfiguration(cloudKitDatabase: .automatic)` enables CloudKit sync but requires additional entitlements and conflict resolution logic.
7. **Encrypted file decryption on export** — The export function in `SessionDetailView` exports only the transcription text. Exporting the raw audio requires a decrypt step via `SecurityManager.decryptFile(at:)` before sharing.
