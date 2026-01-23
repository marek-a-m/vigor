import Foundation
import HealthKit

/// Smart scheduling helper for background sync tasks
final class BackgroundSyncScheduler {
    static let shared = BackgroundSyncScheduler()

    private let healthStore = HKHealthStore()
    private let calendar = Calendar.current
    private let stateManager = SyncStateManager.shared

    private init() {}

    // MARK: - Time Calculations

    /// Calculate next morning sync time (6 AM, or after sleep ends)
    func nextMorningSyncTime() async -> Date {
        let now = Date()

        // Start with 6 AM today or tomorrow
        var targetTime = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now

        // If it's already past 6 AM today, schedule for tomorrow
        if targetTime <= now {
            targetTime = calendar.date(byAdding: .day, value: 1, to: targetTime) ?? now
        }

        // Try to get sleep end time for smarter scheduling
        if let sleepEndTime = await getLastSleepEndTime() {
            let sleepEndHour = calendar.component(.hour, from: sleepEndTime)

            // If sleep ended between 6-9 AM today, schedule for slightly after
            if sleepEndHour >= 6 && sleepEndHour < 9 {
                let adjustedTime = calendar.date(byAdding: .minute, value: 15, to: sleepEndTime) ?? sleepEndTime
                if adjustedTime > now {
                    return adjustedTime
                }
            }
        }

        return targetTime
    }

    /// Calculate next hourly sync time
    func nextHourlySyncTime() -> Date {
        let now = Date()

        // Default: 60 minutes from now
        var targetTime = calendar.date(byAdding: .minute, value: 60, to: now) ?? now

        // Check if we're in active hours (6 AM - 11 PM)
        let hour = calendar.component(.hour, from: now)
        if hour < 6 {
            // Before 6 AM, schedule for 6 AM
            targetTime = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: now) ?? now
        } else if hour >= 23 {
            // After 11 PM, schedule for 6 AM tomorrow
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            targetTime = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow) ?? now
        }

        return targetTime
    }

    /// Calculate retry time based on failure type and count
    func retryTime(for failureType: SyncFailureType) -> Date {
        let now = Date()
        let failureCount = stateManager.consecutiveFailureCount

        let baseInterval: TimeInterval
        switch failureType {
        case .connectionTimeout:
            baseInterval = 5 * 60 // 5 minutes
        case .deviceBusy:
            baseInterval = 30 * 60 // 30 minutes
        case .other:
            // Exponential backoff: 15min, 30min, 1hr, 2hr (max)
            let multiplier = min(pow(2.0, Double(failureCount - 1)), 8.0)
            baseInterval = 15 * 60 * multiplier
        }

        return calendar.date(byAdding: .second, value: Int(baseInterval), to: now) ?? now
    }

    // MARK: - Checks

    /// Check if current time is within active hours (6 AM - 11 PM)
    func isWithinActiveHours() -> Bool {
        let hour = calendar.component(.hour, from: Date())
        return hour >= 6 && hour < 23
    }

    /// Check if it's a good time for morning sync (6 AM - 9 AM)
    func isMorningWindow() -> Bool {
        let hour = calendar.component(.hour, from: Date())
        return hour >= 6 && hour < 9
    }

    // MARK: - HealthKit Sleep Data

    private func getLastSleepEndTime() async -> Date? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

        // Check for read authorization
        let status = healthStore.authorizationStatus(for: sleepType)
        guard status == .sharingAuthorized else { return nil }

        return await withCheckedContinuation { continuation in
            let now = Date()
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

            let predicate = HKQuery.predicateForSamples(
                withStart: yesterday,
                end: now,
                options: .strictEndDate
            )

            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard error == nil,
                      let sample = samples?.first as? HKCategorySample else {
                    continuation.resume(returning: nil)
                    return
                }

                // Only consider "asleep" states (not just "in bed")
                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue,
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
                ]

                if asleepValues.contains(sample.value) {
                    continuation.resume(returning: sample.endDate)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            healthStore.execute(query)
        }
    }
}

// MARK: - Failure Types

enum SyncFailureType {
    case connectionTimeout
    case deviceBusy
    case other
}
