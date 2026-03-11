//
//  LiveActivityManager.swift
//  TwinMind
//
//  Manages the lifecycle of the ActivityKit Live Activity:
//  start → update → end.
//
//  All public methods are @MainActor-safe.
//

import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {

    // ── Singleton ─────────────────────────────────────────────────────────
    static let shared = LiveActivityManager()
    private init() {}

    // ── Active activity handle ─────────────────────────────────────────────
    private var activity: Activity<RecordingActivityAttributes>?

    // MARK: - Start

    func startActivity(sessionTitle: String,
                       inputDevice: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivityManager] Live Activities not enabled.")
            return
        }

        let initialState = RecordingActivityAttributes.ContentState(
            stateLabel: "Recording",
            isRecording: true,
            elapsedSeconds: 0,
            inputDevice: inputDevice,
            transcribedSegments: 0,
            totalSegments: 0,
            audioLevel: 0
        )

        let attributes = RecordingActivityAttributes(sessionTitle: sessionTitle)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("[LiveActivityManager] Failed to start Live Activity: \(error)")
        }
    }

    // MARK: - Update

    func update(
        stateLabel: String,
        isRecording: Bool,
        elapsedSeconds: TimeInterval,
        inputDevice: String,
        transcribedSegments: Int,
        totalSegments: Int,
        audioLevel: Float
    ) async {
        guard let activity else { return }

        let newState = RecordingActivityAttributes.ContentState(
            stateLabel: stateLabel,
            isRecording: isRecording,
            elapsedSeconds: elapsedSeconds,
            inputDevice: inputDevice,
            transcribedSegments: transcribedSegments,
            totalSegments: totalSegments,
            audioLevel: audioLevel
        )

        await activity.update(
            ActivityContent(state: newState, staleDate: Date().addingTimeInterval(5))
        )
    }

    // MARK: - End

    func endActivity(
        transcribedSegments: Int,
        totalSegments: Int,
        elapsedSeconds: TimeInterval
    ) async {
        guard let activity else { return }

        let finalState = RecordingActivityAttributes.ContentState(
            stateLabel: "Stopped",
            isRecording: false,
            elapsedSeconds: elapsedSeconds,
            inputDevice: "—",
            transcribedSegments: transcribedSegments,
            totalSegments: totalSegments,
            audioLevel: 0
        )

        await activity.end(
            ActivityContent(state: finalState, staleDate: nil),
            dismissalPolicy: .after(Date().addingTimeInterval(5))
        )
        self.activity = nil
    }
}
