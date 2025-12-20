import WatchKit
import HealthKit
import WidgetKit

class ExtensionDelegate: NSObject, WKApplicationDelegate {
    private let healthStore = HKHealthStore()

    func applicationDidFinishLaunching() {
        scheduleNextBackgroundRefresh()
    }

    func applicationDidBecomeActive() {
        // Refresh data when app becomes active
        Task {
            await refreshHealthData()
        }
        scheduleNextBackgroundRefresh()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            switch task {
            case let refreshTask as WKApplicationRefreshBackgroundTask:
                // Fetch fresh health data in background
                Task {
                    await refreshHealthData()
                    scheduleNextBackgroundRefresh()
                    refreshTask.setTaskCompletedWithSnapshot(false)
                }

            case let snapshotTask as WKSnapshotRefreshBackgroundTask:
                snapshotTask.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: Date.distantFuture, userInfo: nil)

            default:
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func scheduleNextBackgroundRefresh() {
        // Schedule next refresh in 3 minutes
        let refreshDate = Date().addingTimeInterval(3 * 60)

        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: refreshDate,
            userInfo: nil
        ) { error in
            if let error = error {
                print("Failed to schedule background refresh: \(error)")
            }
        }
    }

    private func refreshHealthData() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        async let hr = fetchLatestHeartRate()
        async let steps = fetchStepsToday()

        let heartRate = await hr
        let stepsCount = await steps

        // Save to shared storage
        let watchData = SharedWatchData(
            heartRate: heartRate.map { Int($0) },
            steps: stepsCount,
            date: Date()
        )
        SharedDataManager.shared.saveWatchData(watchData)

        // Reload widget timelines
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func fetchLatestHeartRate() async -> Double? {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return nil
        }

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                let value = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func fetchStepsToday() async -> Int? {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return nil
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                guard let sum = result?.sumQuantity() else {
                    continuation.resume(returning: nil)
                    return
                }
                let steps = Int(sum.doubleValue(for: .count()))
                continuation.resume(returning: steps)
            }
            healthStore.execute(query)
        }
    }
}
