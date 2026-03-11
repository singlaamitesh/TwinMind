//
//  SessionDetailView.swift
//  TwinMind
//
//  Shows all TranscriptionSegment objects for a session.
//  • Scrollable list with segment index, timestamp, status badge, and text.
//  • Real-time updates via @Query (SwiftData auto-refreshes on context changes).
//  • Share / export full transcript button.
//  • Inline copy for individual segments.
//

import SwiftUI
import SwiftData
import Combine

struct SessionDetailView: View {

    // Use a live query filtered by session so the view auto-updates
    // as new segments arrive from the background actor.
    @Bindable var session: RecordingSession
    @Environment(\.modelContext) private var ctx

    @State private var showingShareSheet = false
    @State private var exportText       = ""
    @State private var visibleSegmentCount = 100  // pagination batch size
    @State private var refreshTick: Int = 0       // drives re-evaluation of segments

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // ── Session metadata header ────────────────────────────────
                metadataCard

                Divider().padding(.horizontal)

                // ── Segments list (paginated for 10k+ datasets) ───────
                let _ = refreshTick   // force re-eval on tick
                if sortedSegments.isEmpty {
                    ContentUnavailableView(
                        "No Transcriptions Yet",
                        systemImage: "waveform",
                        description: Text("Segments will appear here as they are transcribed.")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(paginatedSegments) { seg in
                        SegmentRowView(segment: seg)
                        Divider().padding(.leading, 16)
                    }
                    // Load-more trigger
                    if paginatedSegments.count < sortedSegments.count {
                        Button {
                            visibleSegmentCount += 100
                        } label: {
                            Text("Load More Segments")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                        .accessibilityLabel("Load more segments")
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dataManagerDidSave)) { _ in
            // Instant refresh when background actor saves a transcription result
            ctx.processPendingChanges()
            refreshTick += 1
        }
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !sortedSegments.isEmpty {
                    Button {
                        exportText = buildFullTranscript()
                        showingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Export transcript")
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: [exportText])
        }
    }

    // MARK: - Metadata Card

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(session.createdAt.formatted(date: .long, time: .shortened),
                      systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                statusBadge
            }

            HStack(spacing: 20) {
                statItem(icon: "clock", label: "Duration", value: durationText)
                statItem(icon: "text.bubble", label: "Progress",
                         value: "\(session.transcribedSegments)/\(session.totalSegments)")
                statItem(icon: "waveform", label: "Quality",
                         value: session.audioQuality.displayName)
            }

            // Progress bar
            if session.totalSegments > 0 {
                ProgressView(value: session.transcriptionProgress)
                    .tint(.blue)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
    }

    // MARK: - Helpers

    private var sortedSegments: [TranscriptionSegment] {
        session.segments.sorted { $0.index < $1.index }
    }

    /// Paginated view — shows only the first `visibleSegmentCount` segments.
    private var paginatedSegments: [TranscriptionSegment] {
        Array(sortedSegments.prefix(visibleSegmentCount))
    }

    private var durationText: String {
        let d = Int(session.duration)
        if d >= 3600 { return String(format: "%dh %02dm", d / 3600, (d % 3600) / 60) }
        return String(format: "%dm %02ds", d / 60, d % 60)
    }

    private var statusBadge: some View {
        Text(session.state.rawValue.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }

    private func statItem(icon: String, label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.bold())
        }
    }

    private func buildFullTranscript() -> String {
        sortedSegments
            .compactMap { $0.transcriptionText }
            .joined(separator: "\n\n")
    }
}

// MARK: - SegmentRowView

struct SegmentRowView: View {
    let segment: TranscriptionSegment
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                // Index & timestamp
                Text("#\(segment.index + 1)")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(timestampLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                // Status badge
                segmentStatusBadge

                // Copy button
                if segment.transcriptionText != nil {
                    Button {
                        UIPasteboard.general.string = segment.transcriptionText
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await MainActor.run { withAnimation { copied = false } }
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(copied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Copied" : "Copy text")
                }
            }

            // Transcription text or placeholder
            Group {
                if let text = segment.transcriptionText, !text.isEmpty {
                    Text(text)
                        .font(.body)
                } else if segment.status == .transcribed || segment.status == .fallback {
                    Text("(No speech detected)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    statusPlaceholder
                }
            }

            // Fallback indicator
            if segment.usedFallback {
                Label("On-device transcription", systemImage: "iphone")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private var timestampLabel: String {
        let s = Int(segment.startTime)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var statusPlaceholder: some View {
        HStack(spacing: 6) {
            switch segment.status {
            case .pending:
                ProgressView().controlSize(.mini)
                Text("Queued…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .uploading:
                ProgressView().controlSize(.mini)
                Text("Transcribing…")
                    .font(.subheadline)
                    .foregroundStyle(.blue)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(segment.errorMessage ?? "Failed")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private var segmentStatusBadge: some View {
        let (label, color): (String, Color) = {
            switch segment.status {
            case .pending:     return ("Pending",    .secondary)
            case .uploading:   return ("Processing", .blue)
            case .transcribed: return ("Done",       .green)
            case .failed:      return ("Failed",     .red)
            case .fallback:    return ("On-device",  .orange)
            }
        }()

        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
