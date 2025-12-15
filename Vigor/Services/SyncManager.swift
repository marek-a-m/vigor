import Foundation
import SwiftData

@MainActor
final class SyncManager: ObservableObject {
    private let healthKitManager: HealthKitManager
    private let calculator = VigorCalculator()
    private let modelContext: ModelContext

    private static let lastSyncDateKey = "lastHealthKitSyncDate"
    private static let initialSyncCompletedKey = "initialHealthKitSyncCompleted"
    private static let historyDays = 30

    @Published var isSyncing = false
    @Published var syncProgress: Double = 0
    @Published var lastSyncDate: Date?
    @Published var errorMessage: String?

    init(healthKitManager: HealthKitManager, modelContext: ModelContext) {
        self.healthKitManager = healthKitManager
        self.modelContext = modelContext
        self.lastSyncDate = UserDefaults.standard.object(forKey: Self.lastSyncDateKey) as? Date
    }

    var isInitialSyncCompleted: Bool {
        UserDefaults.standard.bool(forKey: Self.initialSyncCompletedKey)
    }

    /// Perform sync - initial 30-day sync or incremental sync
    func performSync() async {
        guard !isSyncing else { return }

        isSyncing = true
        syncProgress = 0
        errorMessage = nil

        defer {
            isSyncing = false
            syncProgress = 1.0
        }

        do {
            if !isInitialSyncCompleted {
                try await performInitialSync()
            } else {
                try await performIncrementalSync()
            }

            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: Self.lastSyncDateKey)
        } catch {
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// Initial sync: fetch 30 days of historical data
    private func performInitialSync() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let startDate = calendar.date(byAdding: .day, value: -Self.historyDays, to: today)!

        syncProgress = 0.1

        // Fetch all historical data from HealthKit
        let historicalData = await healthKitManager.fetchHistoricalMetrics(from: startDate, to: today)

        syncProgress = 0.5

        // Store daily metrics and calculate scores
        for (index, dailyData) in historicalData.enumerated() {
            let metrics = DailyMetrics(
                date: dailyData.date,
                sleepHours: dailyData.sleepHours,
                hrvAverage: dailyData.hrvAverage,
                restingHeartRate: dailyData.restingHeartRate,
                wristTemperature: dailyData.wristTemperature
            )
            modelContext.insert(metrics)

            // Update progress
            syncProgress = 0.5 + (0.3 * Double(index + 1) / Double(historicalData.count))
        }

        try modelContext.save()

        syncProgress = 0.8

        // Calculate vigor scores for all days
        try await calculateAllVigorScores()

        syncProgress = 0.95

        // Mark initial sync as completed
        UserDefaults.standard.set(true, forKey: Self.initialSyncCompletedKey)

        syncProgress = 1.0
    }

    /// Incremental sync: only fetch data since last sync
    private func performIncrementalSync() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Determine start date - either day after last sync, or yesterday if no recent sync
        let startDate: Date
        if let lastSync = lastSyncDate {
            let lastSyncDay = calendar.startOfDay(for: lastSync)
            // Re-sync the last synced day (in case it was partial) plus any new days
            startDate = lastSyncDay
        } else {
            // Fallback: sync last 2 days
            startDate = calendar.date(byAdding: .day, value: -1, to: today)!
        }

        syncProgress = 0.2

        // Fetch recent data
        let recentData = await healthKitManager.fetchHistoricalMetrics(from: startDate, to: today)

        syncProgress = 0.5

        // Update or insert daily metrics
        for dailyData in recentData {
            try await upsertDailyMetrics(dailyData)
        }

        try modelContext.save()

        syncProgress = 0.7

        // Recalculate vigor scores for updated days
        for dailyData in recentData {
            try await calculateVigorScore(for: dailyData.date)
        }

        try modelContext.save()

        syncProgress = 1.0
    }

    /// Insert or update daily metrics for a specific day
    private func upsertDailyMetrics(_ data: DailyHealthData) async throws {
        let dayStart = Calendar.current.startOfDay(for: data.date)

        let descriptor = FetchDescriptor<DailyMetrics>(
            predicate: #Predicate { $0.date == dayStart }
        )

        let existing = try modelContext.fetch(descriptor)

        if let metrics = existing.first {
            // Update existing
            metrics.sleepHours = data.sleepHours
            metrics.hrvAverage = data.hrvAverage
            metrics.restingHeartRate = data.restingHeartRate
            metrics.wristTemperature = data.wristTemperature
            metrics.lastUpdated = Date()
        } else {
            // Insert new
            let metrics = DailyMetrics(
                date: data.date,
                sleepHours: data.sleepHours,
                hrvAverage: data.hrvAverage,
                restingHeartRate: data.restingHeartRate,
                wristTemperature: data.wristTemperature
            )
            modelContext.insert(metrics)
        }
    }

    /// Calculate vigor scores for all days with metrics
    private func calculateAllVigorScores() async throws {
        let descriptor = FetchDescriptor<DailyMetrics>(
            sortBy: [SortDescriptor(\.date, order: .forward)]
        )

        let allMetrics = try modelContext.fetch(descriptor)

        for metrics in allMetrics {
            try await calculateVigorScore(for: metrics.date, dailyMetrics: metrics)
        }

        try modelContext.save()
    }

    /// Calculate vigor score for a specific day
    private func calculateVigorScore(for date: Date, dailyMetrics: DailyMetrics? = nil) async throws {
        let dayStart = Calendar.current.startOfDay(for: date)

        // Get daily metrics if not provided
        let metrics: DailyMetrics
        if let provided = dailyMetrics {
            metrics = provided
        } else {
            let descriptor = FetchDescriptor<DailyMetrics>(
                predicate: #Predicate { $0.date == dayStart }
            )
            guard let found = try modelContext.fetch(descriptor).first else {
                return // No metrics for this day
            }
            metrics = found
        }

        // Calculate baselines from cached data (30-day average before this date)
        let baselines = try calculateBaselines(before: dayStart)

        // Convert to HealthMetrics
        let healthMetrics = metrics.toHealthMetrics(
            hrvBaseline: baselines.hrv,
            rhrBaseline: baselines.rhr
        )

        // Skip if no meaningful data
        guard healthMetrics.availableMetrics.count > 0 else { return }

        // Calculate score
        let vigorScore = calculator.calculate(from: healthMetrics, date: dayStart)

        // Upsert vigor score
        let scoreDescriptor = FetchDescriptor<VigorScore>(
            predicate: #Predicate { $0.date == dayStart }
        )

        let existingScores = try modelContext.fetch(scoreDescriptor)

        if let existing = existingScores.first {
            // Update existing score
            existing.score = vigorScore.score
            existing.sleepScore = vigorScore.sleepScore
            existing.hrvScore = vigorScore.hrvScore
            existing.rhrScore = vigorScore.rhrScore
            existing.temperatureScore = vigorScore.temperatureScore
            existing.sleepHours = vigorScore.sleepHours
            existing.hrvValue = vigorScore.hrvValue
            existing.rhrValue = vigorScore.rhrValue
            existing.temperatureDeviation = vigorScore.temperatureDeviation
            existing.missingMetrics = vigorScore.missingMetrics
        } else {
            // Insert new score
            modelContext.insert(vigorScore)
        }
    }

    /// Calculate 30-day baselines from cached data
    private func calculateBaselines(before date: Date) throws -> (hrv: Double?, rhr: Double?) {
        let calendar = Calendar.current
        let startDate = calendar.date(byAdding: .day, value: -30, to: date)!

        let descriptor = FetchDescriptor<DailyMetrics>(
            predicate: #Predicate { metrics in
                metrics.date >= startDate && metrics.date < date
            }
        )

        let metricsInRange = try modelContext.fetch(descriptor)

        // Calculate HRV baseline
        let hrvValues = metricsInRange.compactMap { $0.hrvAverage }
        let hrvBaseline = hrvValues.isEmpty ? nil : hrvValues.reduce(0, +) / Double(hrvValues.count)

        // Calculate RHR baseline
        let rhrValues = metricsInRange.compactMap { $0.restingHeartRate }
        let rhrBaseline = rhrValues.isEmpty ? nil : rhrValues.reduce(0, +) / Double(rhrValues.count)

        return (hrvBaseline, rhrBaseline)
    }

    /// Get current baselines from cached data
    func getCurrentBaselines() throws -> (hrv: Double?, rhr: Double?) {
        try calculateBaselines(before: Date())
    }

    /// Force a full re-sync (clears sync state)
    func forceFullSync() async {
        UserDefaults.standard.set(false, forKey: Self.initialSyncCompletedKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncDateKey)
        lastSyncDate = nil
        await performSync()
    }
}
