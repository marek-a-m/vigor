import Foundation
import Combine

// MARK: - Sync Configuration

struct WhoopSyncConfig {
    /// How often to sync (in hours)
    let syncIntervalHours: Int

    /// Number of days to backfill on first sync
    let backfillDays: Int

    /// Generosity preset to use
    let generosityPreset: GenerosityConfig

    /// Whether to allow overwriting existing data
    let allowOverwrite: Bool

    static let `default` = WhoopSyncConfig(
        syncIntervalHours: 1,
        backfillDays: 7,
        generosityPreset: .balanced,
        allowOverwrite: true
    )
}

// MARK: - Sync Status

enum SyncStatus: Equatable {
    case idle
    case syncing(progress: Double, message: String)
    case success(date: Date, metrics: ActivityRingWriter.WrittenMetrics)
    case error(String)
}

// MARK: - WHOOP Activity Ring Sync Manager

/// Coordinates fetching WHOOP data, applying Generosity Algorithm, and writing to HealthKit
@MainActor
final class WhoopActivityRingSyncManager: ObservableObject {
    static let shared = WhoopActivityRingSyncManager()

    // Dependencies
    private let whoopAPI = WhoopAPIService.shared
    private let ringWriter = ActivityRingWriter.shared
    private let algorithm: GenerosityAlgorithm

    // Configuration
    private var config: WhoopSyncConfig

    // State
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var syncHistory: [SyncHistoryEntry] = []

    private var syncTimer: Timer?
    private let defaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") ?? .standard

    struct SyncHistoryEntry: Identifiable, Codable {
        let id: UUID
        let date: Date
        let targetDate: Date
        let calories: Double
        let exerciseMinutes: Double
        let standHours: Int
        let wasSuccessful: Bool
    }

    private init() {
        self.config = .default
        self.algorithm = GenerosityAlgorithm(config: config.generosityPreset)
        loadSyncHistory()
    }

    // MARK: - Configuration

    func updateConfig(_ newConfig: WhoopSyncConfig) {
        config = newConfig
        // Restart timer with new interval
        stopAutoSync()
        startAutoSync()
    }

    // MARK: - Manual Sync

    /// Sync a single day's data
    func syncDay(_ date: Date) async throws {
        guard whoopAPI.isAuthenticated else {
            throw SyncError.notAuthenticated
        }

        syncStatus = .syncing(progress: 0.1, message: "Fetching WHOOP data...")

        // Fetch WHOOP data
        let whoopData = try await whoopAPI.fetchDailyPayload(for: date)

        syncStatus = .syncing(progress: 0.4, message: "Calculating Apple metrics...")

        // Apply Generosity Algorithm
        let appleMetrics = algorithm.calculateAppleStyleMetrics(from: whoopData)

        // Debug output
        algorithm.printBreakdown(appleMetrics)

        syncStatus = .syncing(progress: 0.7, message: "Writing to HealthKit...")

        // Write to HealthKit
        try await ringWriter.writeMetrics(appleMetrics, allowOverwrite: config.allowOverwrite)

        // Record success
        let entry = SyncHistoryEntry(
            id: UUID(),
            date: Date(),
            targetDate: date,
            calories: appleMetrics.activeEnergyBurned,
            exerciseMinutes: appleMetrics.exerciseMinutes,
            standHours: appleMetrics.standHours.count,
            wasSuccessful: true
        )
        addToHistory(entry)

        lastSyncDate = Date()
        syncStatus = .success(
            date: Date(),
            metrics: ActivityRingWriter.WrittenMetrics(
                calories: appleMetrics.activeEnergyBurned,
                exerciseMinutes: appleMetrics.exerciseMinutes,
                standHours: appleMetrics.standHours.count
            )
        )
    }

    /// Sync today's data
    func syncToday() async throws {
        try await syncDay(Date())
    }

    /// Backfill multiple days
    func backfill(days: Int) async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        for i in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -i, to: today) else { continue }

            let progress = Double(i + 1) / Double(days)
            syncStatus = .syncing(
                progress: progress,
                message: "Syncing day \(i + 1) of \(days)..."
            )

            do {
                try await syncDay(date)
            } catch {
                print("Failed to sync \(date): \(error)")
                // Continue with next day
            }

            // Rate limit protection
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
        }
    }

    // MARK: - Auto Sync

    func startAutoSync() {
        guard syncTimer == nil else { return }

        let interval = TimeInterval(config.syncIntervalHours * 3600)
        syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                try? await self?.syncToday()
            }
        }

        // Do an initial sync
        Task {
            try? await syncToday()
        }
    }

    func stopAutoSync() {
        syncTimer?.invalidate()
        syncTimer = nil
    }

    // MARK: - Sync History

    private func loadSyncHistory() {
        if let data = defaults.data(forKey: "whoopSyncHistory"),
           let history = try? JSONDecoder().decode([SyncHistoryEntry].self, from: data) {
            syncHistory = history
        }
    }

    private func addToHistory(_ entry: SyncHistoryEntry) {
        syncHistory.insert(entry, at: 0)

        // Keep only last 30 entries
        if syncHistory.count > 30 {
            syncHistory = Array(syncHistory.prefix(30))
        }

        saveSyncHistory()
    }

    private func saveSyncHistory() {
        if let data = try? JSONEncoder().encode(syncHistory) {
            defaults.set(data, forKey: "whoopSyncHistory")
        }
    }

    func clearHistory() {
        syncHistory = []
        defaults.removeObject(forKey: "whoopSyncHistory")
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notAuthenticated
    case fetchFailed(Error)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with WHOOP. Please log in first."
        case .fetchFailed(let error):
            return "Failed to fetch WHOOP data: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Failed to write to HealthKit: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview Helper

#if DEBUG
extension WhoopActivityRingSyncManager {
    static var preview: WhoopActivityRingSyncManager {
        let manager = WhoopActivityRingSyncManager.shared
        manager.syncStatus = .success(
            date: Date(),
            metrics: .init(calories: 523, exerciseMinutes: 45, standHours: 10)
        )
        return manager
    }
}
#endif
