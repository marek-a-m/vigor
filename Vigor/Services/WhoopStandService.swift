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

    private init() {
        if let groupDefaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
        loadTodayActiveHours()
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

            // Do an initial check
            Task {
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
                    .filter { $0.sourceRevision.source.name.uppercased().contains("WHOOP") }
                    .reduce(0.0) { $0 + $1.quantity.doubleValue(for: HKUnit.count()) }

                continuation.resume(returning: whoopSteps)
            }

            healthStore.execute(query)
        }
    }
}
