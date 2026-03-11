//
//  TwinMindWidget.swift
//  TwinMind
//
//  Small Home Screen widget.
//  • If recording is active → shows timer + pulsing red indicator
//  • If idle → shows "Start Recording" button (opens app via deep link)
//  • Updates every 15 minutes when idle, every second via Timeline during recording.
//

import SwiftUI
import WidgetKit
import SwiftData

// MARK: - Widget Timeline Entry

struct RecordingWidgetEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let elapsedSeconds: TimeInterval
    let sessionTitle: String
    let transcribedSegments: Int
    let totalSegments: Int
}

// MARK: - Timeline Provider

struct RecordingTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> RecordingWidgetEntry {
        RecordingWidgetEntry(
            date: .now, isRecording: false, elapsedSeconds: 0,
            sessionTitle: "TwinMind", transcribedSegments: 0, totalSegments: 0
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordingWidgetEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingWidgetEntry>) -> Void) {
        // Read latest session state from SwiftData (shared container).
        // For a true implementation this would query the ModelContainer.
        // For now we provide a "tap to open" idle state with a refresh every 15 min.
        let entry = RecordingWidgetEntry(
            date: .now,
            isRecording: false,
            elapsedSeconds: 0,
            sessionTitle: "",
            transcribedSegments: 0,
            totalSegments: 0
        )
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Small Widget View

struct TwinMindSmallWidgetView: View {
    let entry: RecordingWidgetEntry

    var body: some View {
        Group {
            if entry.isRecording {
                recordingView
            } else {
                idleView
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // ── Active Recording ──────────────────────────────────────────────
    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text("Recording")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }

            Text(entry.sessionTitle.isEmpty ? "Session" : entry.sessionTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(formattedElapsed)
                .font(.title2.monospacedDigit().bold())

            if entry.totalSegments > 0 {
                Text("\(entry.transcribedSegments)/\(entry.totalSegments) transcribed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    // ── Idle ──────────────────────────────────────────────────────────
    private var idleView: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)

            Text("TwinMind")
                .font(.caption.bold())

            Text("Tap to Record")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var formattedElapsed: String {
        let total = Int(entry.elapsedSeconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Widget Config

struct TwinMindWidget: Widget {
    let kind = "TwinMindWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordingTimelineProvider()) { entry in
            TwinMindSmallWidgetView(entry: entry)
        }
        .configurationDisplayName("TwinMind")
        .description("Quick access to recording status.")
        .supportedFamilies([.systemSmall])
    }
}
