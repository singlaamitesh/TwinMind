//
//  RecordingLiveActivityView.swift
//  TwinMind
//
//  ActivityKit widget UI for both the Compact / Expanded Dynamic Island views
//  and the Lock Screen banner.
//

import SwiftUI
import ActivityKit
import WidgetKit

// MARK: - RecordingLiveActivityWidget

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            // ── Lock Screen / StandBy banner ──────────────────────────────
            LockScreenBannerView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                // ── Expanded ──────────────────────────────────────────────
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecordingPulse(isRecording: context.state.isRecording)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.attributes.sessionTitle)
                                .font(.caption.bold())
                                .lineLimit(1)
                            Text(context.state.stateLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    TimerView(elapsed: context.state.elapsedSeconds)
                        .font(.title3.monospacedDigit().bold())
                        .foregroundStyle(.red)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Label(context.state.inputDevice, systemImage: "mic.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(context.state.progressLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        AudioLevelBar(level: context.state.audioLevel)
                            .frame(height: 6)
                    }
                    .padding(.horizontal, 4)
                }

            } compactLeading: {
                // ── Compact Leading ───────────────────────────────────────
                RecordingPulse(isRecording: context.state.isRecording)
                    .frame(width: 12, height: 12)
            } compactTrailing: {
                // ── Compact Trailing ──────────────────────────────────────
                TimerView(elapsed: context.state.elapsedSeconds)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.red)
            } minimal: {
                // ── Minimal ───────────────────────────────────────────────
                RecordingPulse(isRecording: context.state.isRecording)
            }
            .keylineTint(context.state.isRecording ? .red : .orange)
        }
    }
}

// MARK: - Lock Screen Banner

private struct LockScreenBannerView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            RecordingPulse(isRecording: context.state.isRecording)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.sessionTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(context.state.stateLabel)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                TimerView(elapsed: context.state.elapsedSeconds)
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(.red)

                Text(context.state.progressLabel)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding()
        .overlay(alignment: .bottom) {
            VStack(spacing: 4) {
                Label(context.state.inputDevice, systemImage: "airpodspro")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                AudioLevelBar(level: context.state.audioLevel)
                    .frame(height: 4)
                    .padding(.horizontal)
            }
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Subviews

/// Pulsing red dot — animates while isRecording is true.
private struct RecordingPulse: View {
    let isRecording: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(isRecording ? Color.red : Color.orange)
            .scaleEffect(pulsing ? 1.3 : 1.0)
            .animation(
                isRecording
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: pulsing
            )
            .onAppear { pulsing = isRecording }
            .onChange(of: isRecording) { _, newValue in pulsing = newValue }
    }
}

/// Simple elapsed-time formatter (HH:MM:SS).
private struct TimerView: View {
    let elapsed: TimeInterval

    var body: some View {
        Text(formatted)
    }

    private var formatted: String {
        let total = Int(elapsed)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

/// Horizontal RMS level bar.
private struct AudioLevelBar: View {
    let level: Float  // 0.0 – 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(levelColor)
                    .frame(width: geo.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }

    private var levelColor: Color {
        switch level {
        case 0..<0.5: return .green
        case 0.5..<0.8: return .yellow
        default:        return .red
        }
    }
}
