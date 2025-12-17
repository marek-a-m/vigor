import Foundation
import HealthKit

@MainActor
final class WatchHealthManager: ObservableObject {
    private let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var currentHeartRate: Double?
    @Published var stepsToday: Int?
    @Published var floorsClimbed: Int?
    @Published var isLoading = false

    private let readTypes: Set<HKObjectType> = [
        HKObjectType.quantityType(forIdentifier: .heartRate)!,
        HKObjectType.quantityType(forIdentifier: .stepCount)!,
        HKObjectType.quantityType(forIdentifier: .flightsClimbed)!
    ]

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            await fetchAllData()
        } catch {
            print("HealthKit authorization failed: \(error)")
        }
    }

    func fetchAllData() async {
        isLoading = true
        defer { isLoading = false }

        async let hr = fetchLatestHeartRate()
        async let steps = fetchStepsToday()
        async let floors = fetchFloorsToday()

        currentHeartRate = await hr
        stepsToday = await steps
        floorsClimbed = await floors

        // Save to shared storage for widgets
        let watchData = SharedWatchData(
            heartRate: currentHeartRate.map { Int($0) },
            steps: stepsToday,
            date: Date()
        )
        SharedDataManager.shared.saveWatchData(watchData)
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
            ) { _, samples, error in
                guard let sample = samples?.first as? HKQuantitySample, error == nil else {
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
            ) { _, result, error in
                guard let result = result, let sum = result.sumQuantity(), error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let steps = Int(sum.doubleValue(for: .count()))
                continuation.resume(returning: steps)
            }

            healthStore.execute(query)
        }
    }

    private func fetchFloorsToday() async -> Int? {
        guard let floorType = HKQuantityType.quantityType(forIdentifier: .flightsClimbed) else {
            return nil
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date(), options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: floorType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                guard let result = result, let sum = result.sumQuantity(), error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let floors = Int(sum.doubleValue(for: .count()))
                continuation.resume(returning: floors)
            }

            healthStore.execute(query)
        }
    }
}
