import Foundation
import HealthKit

final class WhoopStandService: ObservableObject {
    static let shared = WhoopStandService()

    private let healthStore = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private let stepsThreshold: Double = 100
    private let defaults: UserDefaults

    @Published var isMonitoring = false
    @Published var todayActiveHours: Int = 0
    @Published var lastSyncedActiveHours: Int = 0  // From 2 days ago (WHOOP delay)
    @Published var lastSyncedDate: Date?
    @Published var whoopStepsAvailable: Bool?  // nil = not checked, true/false = result
    @Published var whoopStepsInfo: String = ""

    private init() {
        if let groupDefaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
        loadTodayActiveHours()
    }

    // MARK: - Debug

    /// Check if WHOOP has ever written step data to Apple Health (last 30 days)
    func checkForWhoopStepData() async -> (hasData: Bool, sources: [String], totalSteps: Double) {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return (false, [], 0)
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
                sampleType: stepsType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], error == nil else {
                    continuation.resume(returning: (false, [], 0))
                    return
                }

                // Find all WHOOP-related sources
                let whoopSamples = samples.filter { sample in
                    let name = sample.sourceRevision.source.name.uppercased()
                    let bundleId = sample.sourceRevision.source.bundleIdentifier.lowercased()
                    return name.contains("WHOOP") || bundleId.contains("whoop")
                }

                let whoopSources = Array(Set(whoopSamples.map {
                    "\($0.sourceRevision.source.name) (\($0.sourceRevision.source.bundleIdentifier))"
                }))

                let totalSteps = whoopSamples.reduce(0.0) {
                    $0 + $1.quantity.doubleValue(for: HKUnit.count())
                }

                // Also list all sources for debugging
                let allSources = Array(Set(samples.map { $0.sourceRevision.source.name }))

                print("═══════════════════════════════════════════════════════")
                print("WHOOP Step Data Check (last 30 days):")
                print("═══════════════════════════════════════════════════════")
                print("All step sources found: \(allSources)")
                print("WHOOP sources found: \(whoopSources)")
                print("WHOOP total steps: \(Int(totalSteps))")
                print("═══════════════════════════════════════════════════════")

                continuation.resume(returning: (!whoopSamples.isEmpty, whoopSources, totalSteps))
            }

            healthStore.execute(query)
        }
    }

    /// Debug function to list all step sources in HealthKit
    func debugListAllStepSources() async {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            print("WhoopStandService DEBUG: Cannot get step count type")
            return
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfDay = calendar.startOfDay(for: now)

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: now,
            options: .strictStartDate
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let query = HKSampleQuery(
                sampleType: stepsType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error {
                    print("WhoopStandService DEBUG: Error - \(error.localizedDescription)")
                    continuation.resume()
                    return
                }

                guard let samples = samples as? [HKQuantitySample] else {
                    print("WhoopStandService DEBUG: No step samples found today")
                    continuation.resume()
                    return
                }

                // Group by source
                let sourceGroups = Dictionary(grouping: samples) { sample in
                    "\(sample.sourceRevision.source.name) (\(sample.sourceRevision.source.bundleIdentifier))"
                }

                print("═══════════════════════════════════════════════════════")
                print("WhoopStandService DEBUG: Step sources found today:")
                print("═══════════════════════════════════════════════════════")
                for (source, sourceSamples) in sourceGroups.sorted(by: { $0.key < $1.key }) {
                    let totalSteps = sourceSamples.reduce(0.0) { $0 + $1.quantity.doubleValue(for: HKUnit.count()) }
                    print("  • \(source): \(Int(totalSteps)) steps")
                }
                print("═══════════════════════════════════════════════════════")

                continuation.resume()
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            return false
        }

        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return false
        }

        let readTypes: Set<HKObjectType> = [stepsType]

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            print("WhoopStandService: Authorization failed - \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard !isMonitoring else { return }

        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return
        }

        observerQuery = HKObserverQuery(sampleType: stepsType, predicate: nil) { [weak self] _, completionHandler, error in
            if let error = error {
                print("WhoopStandService: Observer query error - \(error.localizedDescription)")
                completionHandler()
                return
            }

            Task {
                await self?.checkWhoopSteps()
                completionHandler()
            }
        }

        if let query = observerQuery {
            healthStore.execute(query)
            isMonitoring = true
            print("WhoopStandService: Started monitoring WHOOP steps")

            // Do an initial check and debug
            Task {
                // Check if WHOOP has ever written steps to Apple Health
                let (hasData, sources, totalSteps) = await checkForWhoopStepData()
                await MainActor.run {
                    self.whoopStepsAvailable = hasData
                    if hasData {
                        self.whoopStepsInfo = "WHOOP steps found: \(Int(totalSteps)) from \(sources.joined(separator: ", "))"
                    } else {
                        self.whoopStepsInfo = "No WHOOP step data in Apple Health (last 30 days)"
                    }
                }

                // WHOOP syncs with ~2 day delay - find most recent synced data
                await refreshLastSyncedActiveHours()

                // Debug: show WHOOP steps distribution
                await debugWhoopStepsByDay()

                await debugListAllStepSources()
                await checkWhoopSteps()
            }
        }
    }

    func stopMonitoring() {
        if let query = observerQuery {
            healthStore.stop(query)
            observerQuery = nil
        }
        isMonitoring = false
        print("WhoopStandService: Stopped monitoring")
    }

    // MARK: - Active Hours Tracking

    private func checkWhoopSteps() async {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        // Reset if it's a new day
        let lastSavedDate = defaults.object(forKey: "whoopLastDate") as? Date ?? Date.distantPast
        if !calendar.isDate(lastSavedDate, inSameDayAs: now) {
            await MainActor.run {
                self.todayActiveHours = 0
            }
            defaults.set(today, forKey: "whoopLastDate")
            defaults.set([Int](), forKey: "whoopActiveHoursSet")
        }

        // Check each hour of today
        var activeHoursSet = Set(defaults.array(forKey: "whoopActiveHoursSet") as? [Int] ?? [])
        let currentHour = calendar.component(.hour, from: now)

        for hour in 0...currentHour {
            guard !activeHoursSet.contains(hour) else { continue }

            let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: today)!
            let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart)!

            // Don't check incomplete hours (except current hour with some buffer)
            if hour == currentHour && calendar.component(.minute, from: now) < 5 {
                continue
            }

            let whoopSteps = await fetchWhoopStepsForHour(start: hourStart, end: min(hourEnd, now))

            if whoopSteps >= stepsThreshold {
                activeHoursSet.insert(hour)
                print("WhoopStandService: Hour \(hour) marked as active (\(Int(whoopSteps)) WHOOP steps)")
            }
        }

        // Save and update UI
        defaults.set(Array(activeHoursSet), forKey: "whoopActiveHoursSet")
        defaults.set(today, forKey: "whoopLastDate")

        let count = activeHoursSet.count
        await MainActor.run {
            self.todayActiveHours = count
        }
    }

    private func loadTodayActiveHours() {
        let calendar = Calendar.current
        let now = Date()
        let lastSavedDate = defaults.object(forKey: "whoopLastDate") as? Date ?? Date.distantPast

        if calendar.isDate(lastSavedDate, inSameDayAs: now) {
            let activeHoursSet = defaults.array(forKey: "whoopActiveHoursSet") as? [Int] ?? []
            todayActiveHours = activeHoursSet.count
        } else {
            todayActiveHours = 0
        }
    }

    private func fetchWhoopStepsForHour(start: Date, end: Date) async -> Double {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return 0
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: stepsType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], error == nil else {
                    continuation.resume(returning: 0)
                    return
                }

                // Filter only WHOOP samples and sum steps
                let whoopSteps = samples
                    .filter { sample in
                        let name = sample.sourceRevision.source.name.uppercased()
                        return name.contains("WHOOP") ||
                               sample.sourceRevision.source.bundleIdentifier.lowercased().contains("whoop")
                    }
                    .reduce(0.0) { $0 + $1.quantity.doubleValue(for: HKUnit.count()) }

                continuation.resume(returning: whoopSteps)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Yesterday's Active Hours (for delayed WHOOP sync)

    /// WHOOP syncs steps with ~2 day delay, so find most recent day with data
    func fetchLastSyncedActiveHours() async -> (hours: Int, date: Date?) {
        let calendar = Calendar.current
        let now = Date()

        // Check last 7 days, find the most recent day with WHOOP data
        for daysAgo in 1..<8 {
            guard let targetDate = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) else {
                continue
            }

            var activeHours = 0
            var totalSteps: Double = 0
            var hourlySteps: [Int: Double] = [:]

            for hour in 0..<24 {
                let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: targetDate)!
                let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart)!

                let whoopSteps = await fetchWhoopStepsForHour(start: hourStart, end: hourEnd)
                hourlySteps[hour] = whoopSteps
                totalSteps += whoopSteps

                if whoopSteps >= stepsThreshold {
                    activeHours += 1
                }
            }

            // If we found data for this day, use it
            if totalSteps > 0 {
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .short
                let dateStr = dateFormatter.string(from: targetDate)

                let nonZeroHours = hourlySteps.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                print("WhoopStandService: Found WHOOP data from \(daysAgo) days ago (\(dateStr))")
                print("  Total steps: \(Int(totalSteps))")
                print("  Active hours: \(activeHours) (hours with 100+ steps)")
                if !nonZeroHours.isEmpty {
                    print("  Hourly: \(nonZeroHours.map { "h\($0.key):\(Int($0.value))" }.joined(separator: ", "))")
                }

                return (activeHours, targetDate)
            }
        }

        print("WhoopStandService: No WHOOP step data found in last 7 days")
        return (0, nil)
    }

    /// Debug: Check WHOOP step data distribution over last 7 days
    func debugWhoopStepsByDay() async {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else { return }

        let calendar = Calendar.current
        let now = Date()

        print("═══════════════════════════════════════════════════════")
        print("WHOOP Steps by Day (last 7 days):")
        print("═══════════════════════════════════════════════════════")

        for daysAgo in 0..<7 {
            guard let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)

            let steps = await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
                let query = HKSampleQuery(
                    sampleType: stepsType,
                    predicate: predicate,
                    limit: HKObjectQueryNoLimit,
                    sortDescriptors: nil
                ) { _, samples, _ in
                    guard let samples = samples as? [HKQuantitySample] else {
                        continuation.resume(returning: 0)
                        return
                    }

                    let whoopSteps = samples
                        .filter { $0.sourceRevision.source.name.uppercased().contains("WHOOP") ||
                                  $0.sourceRevision.source.bundleIdentifier.lowercased().contains("whoop") }
                        .reduce(0.0) { $0 + $1.quantity.doubleValue(for: HKUnit.count()) }

                    continuation.resume(returning: whoopSteps)
                }
                healthStore.execute(query)
            }

            let dateStr = DateFormatter.localizedString(from: dayStart, dateStyle: .short, timeStyle: .none)
            let label = daysAgo == 0 ? "Today" : (daysAgo == 1 ? "Yesterday" : "\(daysAgo) days ago")
            print("  \(label) (\(dateStr)): \(Int(steps)) WHOOP steps")
        }
        print("═══════════════════════════════════════════════════════")
    }

    /// Refresh last synced active hours (call this on app launch)
    func refreshLastSyncedActiveHours() async {
        let (hours, date) = await fetchLastSyncedActiveHours()
        await MainActor.run {
            self.lastSyncedActiveHours = hours
            self.lastSyncedDate = date
        }
    }
}
