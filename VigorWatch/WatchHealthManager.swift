import Foundation
import HealthKit
import WidgetKit
import WorkoutKit

@MainActor
final class WatchHealthManager: NSObject, ObservableObject {
    private let healthStore = HKHealthStore()
    private var heartRateQuery: HKAnchoredObjectQuery?
    private var stepsQuery: HKObserverQuery?
    private var refreshTimer: Timer?
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?

    @Published var isAuthorized = false
    @Published var currentHeartRate: Double?
    @Published var stepsToday: Int?
    @Published var floorsClimbed: Int?
    @Published var isLoading = false
    @Published var isMonitoring = false

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
            startHeartRateMonitoring()
            startStepsMonitoring()
            enableBackgroundDelivery()
            startPeriodicRefresh()
        } catch {
            print("HealthKit authorization failed: \(error)")
        }
    }

    private func startPeriodicRefresh() {
        // Refresh steps and floors every 30 seconds
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.fetchStepsAndFloors()
            }
        }
    }

    private func fetchStepsAndFloors() async {
        async let steps = fetchStepsToday()
        async let floors = fetchFloorsToday()

        stepsToday = await steps
        floorsClimbed = await floors
        updateSharedData()
    }

    // MARK: - Real-time Heart Rate Monitoring

    private func startHeartRateMonitoring() {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        // Stop existing query if any
        if let existingQuery = heartRateQuery {
            healthStore.stop(existingQuery)
        }

        // Create anchored query for real-time updates
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: nil,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            Task { @MainActor in
                self?.processHeartRateSamples(samples)
            }
        }

        // Handle updates
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            Task { @MainActor in
                self?.processHeartRateSamples(samples)
            }
        }

        heartRateQuery = query
        healthStore.execute(query)
    }

    private func startStepsMonitoring() {
        guard let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }

        // Stop existing query if any
        if let existingQuery = stepsQuery {
            healthStore.stop(existingQuery)
        }

        // Observer query to get notified of step changes
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, _, error in
            if error == nil {
                Task { @MainActor in
                    await self?.fetchStepsAndFloors()
                }
            }
        }

        stepsQuery = query
        healthStore.execute(query)
    }

    private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let samples = samples as? [HKQuantitySample],
              let latestSample = samples.last else { return }

        let heartRate = latestSample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        self.currentHeartRate = heartRate
        self.updateSharedData()
    }

    private func enableBackgroundDelivery() {
        // Enable for heart rate
        if let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            healthStore.enableBackgroundDelivery(for: heartRateType, frequency: .immediate) { _, error in
                if let error = error {
                    print("HR background delivery error: \(error)")
                }
            }
        }

        // Enable for steps
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            healthStore.enableBackgroundDelivery(for: stepType, frequency: .immediate) { _, error in
                if let error = error {
                    print("Steps background delivery error: \(error)")
                }
            }
        }
    }

    private func updateSharedData() {
        let watchData = SharedWatchData(
            heartRate: currentHeartRate.map { Int($0) },
            steps: stepsToday,
            date: Date()
        )
        SharedDataManager.shared.saveWatchData(watchData)
        WidgetCenter.shared.reloadAllTimelines()
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

        updateSharedData()
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

    // MARK: - Workout Session for Continuous HR

    func startMonitoring() {
        guard !isMonitoring else { return }

        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .unknown

        do {
            workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            workoutBuilder = workoutSession?.associatedWorkoutBuilder()

            workoutSession?.delegate = self
            workoutBuilder?.delegate = self
            workoutBuilder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

            let startDate = Date()
            workoutSession?.startActivity(with: startDate)
            workoutBuilder?.beginCollection(withStart: startDate) { _, _ in }

            isMonitoring = true
        } catch {
            print("Failed to start workout session: \(error)")
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }

        workoutSession?.end()
        workoutBuilder?.endCollection(withEnd: Date()) { _, _ in }
        workoutBuilder?.finishWorkout { _, _ in }

        workoutSession = nil
        workoutBuilder = nil
        isMonitoring = false
    }
}

// MARK: - Workout Session Delegate

extension WatchHealthManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            if toState == .ended {
                isMonitoring = false
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("Workout session failed: \(error)")
    }
}

// MARK: - Workout Builder Delegate

extension WatchHealthManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(heartRateType) else { return }

        let statistics = workoutBuilder.statistics(for: heartRateType)
        let heartRate = statistics?.mostRecentQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))

        Task { @MainActor in
            if let hr = heartRate {
                self.currentHeartRate = hr
                self.updateSharedData()
            }
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
