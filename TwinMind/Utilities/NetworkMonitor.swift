//
//  NetworkMonitor.swift
//  TwinMind
//
//  @Observable wrapper around NWPathMonitor for the UI layer.
//  Publishes `isConnected` which the SessionListView toolbar indicator reads.
//

import Foundation
import Network
import Observation

@MainActor
@Observable
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    // ── Published state ───────────────────────────────────────────────────
    var isConnected: Bool = true

    // ── Internal ──────────────────────────────────────────────────────────
    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "com.twinmind.network-ui-monitor")

    /// Closure called when we transition from offline → online.
    var onReconnect: (() async -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasConnected = self.isConnected
                self.isConnected = path.status == .satisfied

                // Fire reconnect callback on offline → online transition
                if !wasConnected && self.isConnected {
                    await self.onReconnect?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
