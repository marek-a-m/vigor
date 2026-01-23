import Foundation
import HealthKit

/// Raw daily metrics fetched from HealthKit for a single day
struct DailyHealthData {
    let date: Date
    var sleepHours: Double?
    var hrvAverage: Double?
    var restingHeartRate: Double?
    var wristTemperature: Double?
}

@MainActor
final class HealthKitManager: ObservableObject {
    private let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var metrics = HealthMetrics()
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var syncProgress: Double = 0

    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .restingHeartRate)!,
            HKObjectType.quantityType(forIdentifier: .bodyTemperature)!  // For Polar skin temperature
        ]
        if let tempType = HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature) {
            types.insert(tempType)
        }
        return types
    }()

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            errorMessage = "Health data not available on this device"
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            await fetchAllMetrics()
        } catch {
            errorMessage = "Failed to authorize HealthKit: \(error.localizedDescription)"
        }
    }

    func fetchAllMetrics() async {
        isLoading = true
        defer { isLoading = false }

        async let sleep = fetchSleepData()
        async let rhr = fetchRestingHeartRate()
        async let temp = fetchWristTemperature()
        async let hrvBase = fetchHRVBaseline()
        async let rhrBase = fetchRHRBaseline()
        async let tempBase = fetchTemperatureBaseline()

        metrics.sleepHours = await sleep
        metrics.restingHeartRate = await rhr
        metrics.hrvBaseline = await hrvBase
        metrics.rhrBaseline = await rhrBase
        metrics.temperatureBaseline = await tempBase

        // Fetch HRV with WHOOP fallback if no Apple Watch data
        metrics.hrv = await fetchHRVWithWhoopFallback()

        // Calculate temperature deviation from baseline
        if let currentTemp = await temp, let baselineTemp = metrics.temperatureBaseline {
            metrics.wristTemperatureDeviation = currentTemp - baselineTemp
        } else {
            metrics.wristTemperatureDeviation = nil
        }
    }

    /// Fetch HRV with WHOOP fallback if no data from other sources
    private func fetchHRVWithWhoopFallback() async -> Double? {
        // Always use WhoopHRVService for consistent logging and fallback logic
        return await WhoopHRVService.shared.fetchHRVWithWhoopFallback()
    }

    private func fetchSleepData() async -> Double? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfYesterday,
            end: now,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKCategorySample], error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue
                ]

                let totalSleep = samples
                    .filter { asleepValues.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

                let hours = totalSleep / 3600.0
                continuation.resume(returning: hours > 0 ? hours : nil)
            }

            healthStore.execute(query)
        }
    }

    func fetchHRVData() async -> Double? {
        // Prefer Polar data for HRV since it's measured during sleep (more accurate)
        if let polarHRV = await fetchPolarHRV() {
            print("HealthKitManager: Using Polar HRV: \(polarHRV) ms")
            return polarHRV
        }

        // Fall back to most recent HRV from any source
        let hrv = await fetchLatestQuantity(
            typeIdentifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli)
        )
        if let hrv = hrv {
            print("HealthKitManager: Using generic HRV: \(hrv) ms")
        }
        return hrv
    }

    /// Fetch HRV specifically from Polar source (most accurate - measured during sleep)
    private func fetchPolarHRV() async -> Double? {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfYesterday,
            end: now,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                // Find the most recent Polar sample
                let polarSample = samples.first { sample in
                    (sample.metadata?["PolarLoopSync"] as? Bool) == true
                }

                if let polarSample = polarSample {
                    let value = polarSample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            self.healthStore.execute(query)
        }
    }

    private func fetchRestingHeartRate() async -> Double? {
        // Prefer Polar data for RHR since it's measured during sleep (more accurate)
        if let polarRHR = await fetchPolarRHR() {
            print("HealthKitManager: Using Polar RHR: \(polarRHR) bpm")
            return polarRHR
        }

        // Fall back to most recent RHR from any source
        let rhr = await fetchLatestQuantity(
            typeIdentifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute())
        )
        if let rhr = rhr {
            print("HealthKitManager: Using generic RHR: \(rhr) bpm")
        }
        return rhr
    }

    /// Fetch RHR specifically from Polar source (most accurate - measured during sleep)
    private func fetchPolarRHR() async -> Double? {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfYesterday,
            end: now,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: rhrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                // Find the most recent Polar sample
                let polarSample = samples.first { sample in
                    (sample.metadata?["PolarLoopSync"] as? Bool) == true
                }

                if let polarSample = polarSample {
                    let value = polarSample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: nil)
                }
            }

            self.healthStore.execute(query)
        }
    }

    private func fetchWristTemperature() async -> Double? {
        // Try Apple's wrist temperature first (from Apple Watch)
        if let appleTemp = await fetchTemperatureOfType(.appleSleepingWristTemperature) {
            print("HealthKitManager: Using Apple wrist temperature: \(appleTemp)°C")
            return appleTemp
        }

        // Fall back to body temperature (from Polar or manual entry)
        if let bodyTemp = await fetchTemperatureOfType(.bodyTemperature) {
            print("HealthKitManager: Using body temperature (Polar): \(bodyTemp)°C")
            return bodyTemp
        }

        print("HealthKitManager: No temperature data available")
        return nil
    }

    private func fetchTemperatureOfType(_ typeIdentifier: HKQuantityTypeIdentifier) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        // Look back 2 days to ensure we catch the most recent sleep temperature
        let startDate = calendar.date(byAdding: .day, value: -2, to: calendar.startOfDay(for: now))!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: now,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let sample = samples?.first as? HKQuantitySample, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let value = sample.quantity.doubleValue(for: HKUnit.degreeCelsius())
                continuation.resume(returning: value)
            }

            self.healthStore.execute(query)
        }
    }

    private func fetchLatestQuantity(
        typeIdentifier: HKQuantityTypeIdentifier,
        unit: HKUnit
    ) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfYesterday,
            end: now,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let sample = samples?.first as? HKQuantitySample, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let value = sample.quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }

            healthStore.execute(query)
        }
    }

    private func fetchHRVBaseline() async -> Double? {
        await fetchAverageOverDays(
            typeIdentifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli),
            days: 30
        )
    }

    private func fetchRHRBaseline() async -> Double? {
        await fetchAverageOverDays(
            typeIdentifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            days: 30
        )
    }

    private func fetchTemperatureBaseline() async -> Double? {
        // Try Apple's wrist temperature baseline first
        if let appleBaseline = await fetchTemperatureBaselineOfType(.appleSleepingWristTemperature) {
            return appleBaseline
        }

        // Fall back to body temperature baseline (from Polar)
        return await fetchTemperatureBaselineOfType(.bodyTemperature)
    }

    private func fetchTemperatureBaselineOfType(_ typeIdentifier: HKQuantityTypeIdentifier) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -30, to: now)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: now,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample],
                      !samples.isEmpty,
                      error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let total = samples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: HKUnit.degreeCelsius()) }
                let average = total / Double(samples.count)
                continuation.resume(returning: average)
            }

            self.healthStore.execute(query)
        }
    }

    private func fetchAverageOverDays(
        typeIdentifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        days: Int
    ) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return nil
        }

        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: now)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: now,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample],
                      !samples.isEmpty,
                      error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                let total = samples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: unit) }
                let average = total / Double(samples.count)
                continuation.resume(returning: average)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Historical Data Fetching

    /// Fetch daily health metrics for a date range
    /// - Parameters:
    ///   - startDate: Start of the range (inclusive)
    ///   - endDate: End of the range (inclusive)
    /// - Returns: Array of daily health data, one entry per day
    func fetchHistoricalMetrics(from startDate: Date, to endDate: Date) async -> [DailyHealthData] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)

        // Generate all dates in range
        var dates: [Date] = []
        var current = start
        while current <= end {
            dates.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }

        // Initialize results dictionary
        var results: [Date: DailyHealthData] = [:]
        for date in dates {
            results[date] = DailyHealthData(date: date)
        }

        // Fetch all metric types in parallel
        async let sleepData = fetchHistoricalSleep(from: start, to: end)
        async let hrvData = fetchHistoricalQuantity(
            typeIdentifier: .heartRateVariabilitySDNN,
            unit: HKUnit.secondUnit(with: .milli),
            from: start,
            to: end
        )
        async let rhrData = fetchHistoricalQuantity(
            typeIdentifier: .restingHeartRate,
            unit: HKUnit.count().unitDivided(by: .minute()),
            from: start,
            to: end
        )
        async let tempData = fetchHistoricalWristTemperature(from: start, to: end)

        let (sleep, hrv, rhr, temp) = await (sleepData, hrvData, rhrData, tempData)

        // Merge results
        for (date, hours) in sleep {
            results[date]?.sleepHours = hours
        }
        for (date, value) in hrv {
            results[date]?.hrvAverage = value
        }
        for (date, value) in rhr {
            results[date]?.restingHeartRate = value
        }
        for (date, value) in temp {
            results[date]?.wristTemperature = value
        }

        return dates.compactMap { results[$0] }
    }

    /// Fetch historical sleep data grouped by day
    private func fetchHistoricalSleep(from startDate: Date, to endDate: Date) async -> [Date: Double] {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return [:]
        }

        let calendar = Calendar.current
        // Extend start date back by 1 day to catch sleep sessions that started the previous evening
        let adjustedStart = calendar.date(byAdding: .day, value: -1, to: startDate)!
        let adjustedEnd = calendar.date(byAdding: .day, value: 1, to: endDate)!

        let predicate = HKQuery.predicateForSamples(
            withStart: adjustedStart,
            end: adjustedEnd,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKCategorySample], error == nil else {
                    continuation.resume(returning: [:])
                    return
                }

                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue
                ]

                // Group sleep by the day it ends (wake up day)
                var sleepByDay: [Date: Double] = [:]
                for sample in samples where asleepValues.contains(sample.value) {
                    let wakeDay = calendar.startOfDay(for: sample.endDate)
                    let duration = sample.endDate.timeIntervalSince(sample.startDate) / 3600.0
                    sleepByDay[wakeDay, default: 0] += duration
                }

                continuation.resume(returning: sleepByDay)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch historical wrist temperature using sample query (statistics don't work well for this type)
    /// Checks both Apple wrist temperature and body temperature (Polar)
    private func fetchHistoricalWristTemperature(from startDate: Date, to endDate: Date) async -> [Date: Double] {
        // Fetch from both sources
        async let appleTemp = fetchHistoricalTemperatureOfType(.appleSleepingWristTemperature, from: startDate, to: endDate)
        async let bodyTemp = fetchHistoricalTemperatureOfType(.bodyTemperature, from: startDate, to: endDate)

        let (apple, body) = await (appleTemp, bodyTemp)

        // Merge results, preferring Apple Watch data when available
        var merged = body
        for (date, value) in apple {
            merged[date] = value  // Apple Watch overwrites Polar for same day
        }

        return merged
    }

    private func fetchHistoricalTemperatureOfType(_ typeIdentifier: HKQuantityTypeIdentifier, from startDate: Date, to endDate: Date) async -> [Date: Double] {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return [:]
        }

        let calendar = Calendar.current
        // Extend range to catch edge cases
        let adjustedStart = calendar.date(byAdding: .day, value: -1, to: startDate)!
        let adjustedEnd = calendar.date(byAdding: .day, value: 1, to: endDate)!

        let predicate = HKQuery.predicateForSamples(
            withStart: adjustedStart,
            end: adjustedEnd,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: true)]
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], error == nil else {
                    continuation.resume(returning: [:])
                    return
                }

                var valuesByDay: [Date: Double] = [:]
                for sample in samples {
                    // Associate temperature with the day it was recorded (wake day)
                    let day = calendar.startOfDay(for: sample.endDate)
                    let value = sample.quantity.doubleValue(for: HKUnit.degreeCelsius())
                    // Keep the most recent value for each day
                    valuesByDay[day] = value
                }

                continuation.resume(returning: valuesByDay)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch historical quantity data using statistics collection query
    private func fetchHistoricalQuantity(
        typeIdentifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async -> [Date: Double] {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return [:]
        }

        let calendar = Calendar.current
        let anchorDate = calendar.startOfDay(for: startDate)
        let daily = DateComponents(day: 1)

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: calendar.date(byAdding: .day, value: 1, to: endDate),
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: anchorDate,
                intervalComponents: daily
            )

            query.initialResultsHandler = { _, results, error in
                guard let results = results, error == nil else {
                    continuation.resume(returning: [:])
                    return
                }

                var valuesByDay: [Date: Double] = [:]
                results.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
                    if let avg = statistics.averageQuantity() {
                        let day = calendar.startOfDay(for: statistics.startDate)
                        valuesByDay[day] = avg.doubleValue(for: unit)
                    }
                }

                continuation.resume(returning: valuesByDay)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch metrics for a single day
    func fetchMetricsForDay(_ date: Date) async -> DailyHealthData {
        let results = await fetchHistoricalMetrics(from: date, to: date)
        return results.first ?? DailyHealthData(date: date)
    }
}
