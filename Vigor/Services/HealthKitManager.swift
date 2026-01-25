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

    // Must match PolarHealthKitWriter.polarSourceKey
    private static let polarSourceKey = "PolarLoopSync"

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
        // Prefer Polar sleep data if available (more accurate sleep tracking)
        if let polarSleep = await fetchPolarSleep() {
            print("HealthKitManager: Using Polar sleep: \(String(format: "%.1f", polarSleep)) hours")
            return polarSleep
        }

        // Fall back to all sleep sources (Apple Watch, etc.)
        let sleep = await fetchAllSleepSources()
        if let sleep = sleep {
            print("HealthKitManager: Using generic sleep: \(String(format: "%.1f", sleep)) hours")
        }
        return sleep
    }

    /// Fetch sleep specifically from Polar source
    private func fetchPolarSleep() async -> Double? {
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

        let polarKey = Self.polarSourceKey

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

                // Filter to only Polar samples
                let polarSamples = samples.filter { sample in
                    (sample.metadata?[polarKey] as? Bool) == true
                }

                print("HealthKitManager: fetchPolarSleep - \(samples.count) total samples, \(polarSamples.count) Polar samples")

                guard !polarSamples.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                // Use inBed samples to get total sleep duration
                // This gives us the full sleep session time as reported by Polar
                let inBedSamples = polarSamples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }

                let totalSleep = inBedSamples
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

                let hours = totalSleep / 3600.0
                print("HealthKitManager: Polar sleep total (from inBed): \(String(format: "%.1f", hours)) hours")
                continuation.resume(returning: hours > 0 ? hours : nil)
            }

            healthStore.execute(query)
        }
    }

    /// Fetch sleep from all sources (fallback when Polar not available)
    private func fetchAllSleepSources() async -> Double? {
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

        let polarKey = Self.polarSourceKey

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

                // Exclude Polar samples to avoid double-counting if this is called as fallback
                let nonPolarSamples = samples.filter { sample in
                    (sample.metadata?[polarKey] as? Bool) != true
                }

                let asleepValues: Set<Int> = [
                    HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                    HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                    HKCategoryValueSleepAnalysis.asleepREM.rawValue
                ]

                let totalSleep = nonPolarSamples
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

        let polarKey = Self.polarSourceKey

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
                    (sample.metadata?[polarKey] as? Bool) == true
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
    /// Prefers Polar data when available to avoid double-counting with other sources
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

        let polarKey = Self.polarSourceKey

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

                // Separate Polar and non-Polar samples
                let polarSamples = samples.filter { sample in
                    (sample.metadata?[polarKey] as? Bool) == true
                }
                let nonPolarSamples = samples.filter { sample in
                    (sample.metadata?[polarKey] as? Bool) != true
                }

                print("HealthKitManager: Historical sleep - \(samples.count) total, \(polarSamples.count) Polar, \(nonPolarSamples.count) non-Polar")

                // Group sleep by the day it ends (wake up day)
                // For each day, prefer Polar data if available
                var polarSleepByDay: [Date: Double] = [:]
                var nonPolarSleepByDay: [Date: Double] = [:]

                // For Polar: use inBed samples to get total sleep duration per session
                // This avoids splitting sleep across midnight and excludes awake phases from count
                let polarInBedSamples = polarSamples.filter { $0.value == HKCategoryValueSleepAnalysis.inBed.rawValue }
                for sample in polarInBedSamples {
                    let wakeDay = calendar.startOfDay(for: sample.endDate)
                    let duration = sample.endDate.timeIntervalSince(sample.startDate) / 3600.0
                    polarSleepByDay[wakeDay, default: 0] += duration
                }

                // For non-Polar: sum individual asleep stages (traditional approach)
                for sample in nonPolarSamples where asleepValues.contains(sample.value) {
                    let wakeDay = calendar.startOfDay(for: sample.endDate)
                    let duration = sample.endDate.timeIntervalSince(sample.startDate) / 3600.0
                    nonPolarSleepByDay[wakeDay, default: 0] += duration
                }

                print("HealthKitManager: Polar sleep by day: \(polarSleepByDay.map { ($0.key, String(format: "%.1f", $0.value)) })")

                // Merge: use Polar data for days where it exists, otherwise use non-Polar
                var sleepByDay: [Date: Double] = nonPolarSleepByDay
                for (day, hours) in polarSleepByDay {
                    sleepByDay[day] = hours  // Polar overwrites non-Polar for that day
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
