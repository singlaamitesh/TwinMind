//
//  SessionListView.swift
//  TwinMind
//
//  Displays all RecordingSession objects grouped by date.
//  • Search / filter
//  • Pull-to-refresh
//  • Swipe-to-delete
//  • Pagination-ready (uses @Query with sortBy)
//

import SwiftUI
import SwiftData

struct SessionListView: View {

    @Environment(AppState.self)  private var appState
    @Environment(\.modelContext) private var ctx

    @Query(sort: \RecordingSession.createdAt, order: .reverse)
    private var sessions: [RecordingSession]

    @State private var searchText   = ""
    @State private var isRefreshing = false
    @State private var isShowingSettings = false
    @State private var refreshTick: Int = 0

    /// Live network status from NWPathMonitor (read-only in the view)
    private var isOnline: Bool { appState.networkMonitor.isConnected }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if filteredSessions.isEmpty {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Recordings")
            .searchable(text: $searchText, prompt: "Search sessions…")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    onlineIndicator
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dataManagerDidSave)) { _ in
                // Force the main context to pick up changes from the background actor context
                ctx.processPendingChanges()
                refreshTick += 1
            }
        }
    }

    // MARK: - Subviews

    private var sessionList: some View {
        List {
            ForEach(groupedSessions, id: \.0) { date, group in
                Section(header: Text(date, style: .date).font(.subheadline.bold())) {
                    ForEach(group) { session in
                        NavigationLink(destination: SessionDetailView(session: session)) {
                            SessionRowView(session: session)
                        }
                    }
                    .onDelete { offsets in
                        deleteItems(from: group, at: offsets)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            // Re-triggers @Query automatically; explicit refresh for UX feedback
            isRefreshing = true
            try? await Task.sleep(nanoseconds: 500_000_000)
            isRefreshing = false
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            label: {
                Label(
                    searchText.isEmpty ? "No Recordings Yet" : "No Results",
                    systemImage: searchText.isEmpty ? "mic.slash" : "magnifyingglass"
                )
            },
            description: {
                Text(searchText.isEmpty
                     ? "Tap Record to start your first session."
                     : "No sessions match \"\(searchText)\".")
            }
        )
    }

    private var onlineIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOnline ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            if !isOnline {
                Text("Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(isOnline ? "Online" : "Offline")
    }

    // MARK: - Computed

    private var filteredSessions: [RecordingSession] {
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Group sessions by calendar day for section headers.
    private var groupedSessions: [(Date, [RecordingSession])] {
        let cal = Calendar.current
        var dict: [Date: [RecordingSession]] = [:]
        for s in filteredSessions {
            let day = cal.startOfDay(for: s.createdAt)
            dict[day, default: []].append(s)
        }
        return dict.sorted { $0.key > $1.key }
    }

    // MARK: - Actions

    private func deleteItems(from group: [RecordingSession], at offsets: IndexSet) {
        for idx in offsets {
            let session = group[idx]
            Task {
                try? await appState.dataManager.deleteSession(id: session.persistentModelID)
            }
        }
    }
}

// MARK: - SessionRowView

struct SessionRowView: View {
    let session: RecordingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                computedBadge
            }

            HStack(spacing: 12) {
                Label(durationText, systemImage: "clock")
                Label(progressText, systemImage: "text.bubble")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Show progress bar for in-progress transcription
            if session.totalSegments > 0 {
                ProgressView(value: Double(session.transcribedSegments),
                             total: Double(max(session.totalSegments, 1)))
                    .tint(progressColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var durationText: String {
        let d = Int(session.duration)
        if d >= 3600 { return String(format: "%dh %02dm", d / 3600, (d % 3600) / 60) }
        return String(format: "%dm %02ds", d / 60, d % 60)
    }

    private var progressText: String {
        guard session.totalSegments > 0 else { return "No segments" }
        return "\(session.transcribedSegments)/\(session.totalSegments) transcribed"
    }

    /// Computed badge that reflects real transcription state, not just session.state
    private var computedBadge: some View {
        let (label, color) = computedStatus
        return Text(label)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var computedStatus: (String, Color) {
        // Active recording states take priority
        switch session.state {
        case .recording:   return ("Recording", .red)
        case .paused:      return ("Paused", .orange)
        case .interrupted: return ("Interrupted", .yellow)
        case .stopped:     break
        }
        // For stopped sessions, show transcription progress
        if session.totalSegments == 0 {
            return ("Stopped", .secondary)
        }
        if session.transcribedSegments >= session.totalSegments {
            return ("Done", .green)
        }
        // Some segments are still being transcribed
        let pending = session.totalSegments - session.transcribedSegments
        return ("\(pending) pending", .blue)
    }

    private var progressColor: Color {
        if session.transcribedSegments >= session.totalSegments {
            return .green
        }
        return .blue
    }
}
