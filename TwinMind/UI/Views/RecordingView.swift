//
//  RecordingView.swift
//  TwinMind
//
//  Main recording screen:
//  • Audio level waveform visualization
//  • Start / Pause / Stop controls
//  • Live elapsed timer
//  • Transcription progress counter
//  • Input device label
//  • Error banner
//

import SwiftUI
import SwiftData

struct RecordingView: View {

    @Environment(AppState.self) private var appState
    @State private var showingSettings = false
    @State private var showingSessionName = false
    @State private var pendingSessionName = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                VStack(spacing: 32) {

                    // ── Header ─────────────────────────────────────────────
                    headerSection

                    Spacer()

                    // ── Level Meter ────────────────────────────────────────
                    if appState.isRecording || appState.isPaused {
                        WaveformView(level: appState.audioLevel.rms)
                            .frame(height: 80)
                            .padding(.horizontal)
                            .transition(.opacity.combined(with: .scale))
                    }

                    // ── Timer & Progress ───────────────────────────────────
                    if appState.isRecording || appState.isPaused || appState.isInterrupted {
                        statsSection
                    }

                    Spacer()

                    // ── Controls ───────────────────────────────────────────
                    controlSection

                    // ── Error Banner ───────────────────────────────────────
                    if let error = appState.errorMessage {
                        ErrorBanner(message: error) {
                            appState.errorMessage = nil
                        }
                        .transition(.move(edge: .bottom))
                    }
                }
                .padding(.bottom, 32)
                .animation(.spring(response: 0.4), value: appState.isRecording)
            }
            .navigationTitle("TwinMind")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .alert("Session Name", isPresented: $showingSessionName) {
                TextField("e.g. Team Standup", text: $pendingSessionName)
                Button("Start") { beginRecording() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Give this recording a name (optional).")
            }
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: 8) {
            // State badge
            HStack(spacing: 6) {
                Circle()
                    .fill(stateBadgeColor)
                    .frame(width: 10, height: 10)
                    .scaleEffect(appState.isRecording ? 1.0 : 0.8)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                               value: appState.isRecording)
                Text(appState.recorderStateLabel)
                    .font(.subheadline.bold())
                    .foregroundStyle(stateBadgeColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(stateBadgeColor.opacity(0.12), in: Capsule())

            if appState.isRecording || appState.isPaused {
                Label(appState.currentDevice, systemImage: inputDeviceIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var statsSection: some View {
        VStack(spacing: 12) {
            // Elapsed timer
            Text(appState.formattedElapsed)
                .font(.system(size: 56, weight: .thin, design: .monospaced))
                .foregroundStyle(appState.isInterrupted ? .orange : .primary)
                .contentTransition(.numericText(countsDown: false))

            // Transcription progress
            if appState.totalSegments > 0 {
                VStack(spacing: 6) {
                    HStack {
                        Text("Transcription")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(appState.transcribedSegments)/\(appState.totalSegments) chunks")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(appState.transcribedSegments),
                                 total: Double(max(appState.totalSegments, 1)))
                        .tint(.blue)
                }
                .padding(.horizontal, 32)
            }
        }
    }

    private var controlSection: some View {
        HStack(spacing: 40) {
            // Pause / Resume
            if appState.isRecording || appState.isPaused {
                CircleButton(
                    icon: appState.isPaused ? "play.fill" : "pause.fill",
                    color: .orange,
                    size: 56
                ) {
                    Task {
                        do {
                            if appState.isPaused {
                                try await appState.resumeRecording()
                            } else {
                                try await appState.pauseRecording()
                            }
                        } catch {
                            appState.errorMessage = error.localizedDescription
                        }
                    }
                }
                .accessibilityLabel(appState.isPaused ? "Resume Recording" : "Pause Recording")
            }

            // Start / Stop
            if appState.isRecording || appState.isPaused {
                CircleButton(icon: "stop.fill", color: .red, size: 72) {
                    Task { await appState.stopRecording() }
                }
                .accessibilityLabel("Stop Recording")
            } else {
                CircleButton(icon: "mic.fill", color: .red, size: 72) {
                    showingSessionName = true
                }
                .accessibilityLabel("Start Recording")
            }
        }
    }

    // MARK: - Helpers

    private func beginRecording() {
        Task {
            do {
                try await appState.startRecording(title: pendingSessionName)
                pendingSessionName = ""
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }

    private var stateBadgeColor: Color {
        if appState.isInterrupted { return .orange }
        if appState.isPaused      { return .yellow  }
        if appState.isRecording   { return .red     }
        return .secondary
    }

    private var inputDeviceIcon: String {
        let device = appState.currentDevice.lowercased()
        if device.contains("airpod") { return "airpodspro" }
        if device.contains("bluetooth") || device.contains("bt") { return "headphones" }
        return "iphone"
    }
}

// MARK: - WaveformView

/// Animated horizontal level-meter bars mimicking a waveform.
struct WaveformView: View {
    let level: Float
    private let barCount = 40

    var body: some View {
        Canvas { context, size in
            let barWidth = size.width / CGFloat(barCount)
            for i in 0..<barCount {
                let x = CGFloat(i) * barWidth + barWidth / 2
                // Randomise height a bit around the RMS level for visual richness
                let seed = sin(Double(i) * 0.7)
                let height = size.height * CGFloat(level) * CGFloat(0.5 + 0.5 * seed)
                let rect = CGRect(
                    x: x - barWidth * 0.35,
                    y: (size.height - height) / 2,
                    width: barWidth * 0.7,
                    height: max(height, 3)
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .color(barColor(for: Float(level))))
            }
        }
        .animation(.linear(duration: 0.1), value: level)
    }

    private func barColor(for level: Float) -> Color {
        switch level {
        case 0..<0.5:  return .green
        case 0.5..<0.8: return .yellow
        default:        return .red
        }
    }
}

// MARK: - CircleButton

struct CircleButton: View {
    let icon: String
    let color: Color
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color, in: Circle())
                .shadow(color: color.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ErrorBanner

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
