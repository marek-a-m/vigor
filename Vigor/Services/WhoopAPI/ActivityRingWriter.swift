import Foundation
import HealthKit

// MARK: - Activity Ring Writer

/// Writes Apple-style metrics to HealthKit for Activity Ring credit
@MainActor
final class ActivityRingWriter: ObservableObject {
    static let shared = ActivityRingWriter()

    private let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var lastWriteDate: Date?
    @Published var lastWriteStatus: WriteStatus = .idle

    enum WriteStatus: Equatable {
        case idle
        case writing
        case success(metrics: WrittenMetrics)
        case error(String)
    }

    struct WrittenMetrics: Equatable {
        let calories: Double
        let exerciseMinutes: Double
        let standHours: Int
    }

    // MARK: - HealthKit Types

    /// Types we need to WRITE to HealthKit
    private let writeTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = [
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .appleExerciseTime)!,
            HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        ]
        return types
    }()

    /// Types we need to READ (for conflict checking)
    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .appleExerciseTime)!,
            HKCategoryType.categoryType(forIdentifier: .appleStandHour)!
        ]
        return types
    }()

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw ActivityRingError.healthKitUnavailable
        }

        try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
        isAuthorized = true
    }

    // MARK: - Write Metrics

    /// Write Apple-style metrics to HealthKit
    /// - Parameters:
    ///   - metrics: The transformed metrics from Generosity Algorithm
    ///   - allowOverwrite: If true, delete existing data before writing
    func writeMetrics(_ metrics: AppleStyleMetrics, allowOverwrite: Bool = false) async throws {
        lastWriteStatus = .writing

        do {
            // Optionally clear existing data for the day
            if allowOverwrite {
                try await clearExistingData(for: metrics.date)
            }

            // Write all metrics
            try await writeActiveEnergy(metrics.activeEnergyBurned, for: metrics.date)
            try await writeExerciseMinutes(metrics.exerciseMinutes, for: metrics.date)
            try await writeStandHours(metrics.standHours, for: metrics.date)

            lastWriteDate = Date()
            lastWriteStatus = .success(metrics: WrittenMetrics(
                calories: metrics.activeEnergyBurned,
                exerciseMinutes: metrics.exerciseMinutes,
                standHours: metrics.standHours.count
            ))

        } catch {
            lastWriteStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Active Energy (Move Ring)

    /// Write active calories to HealthKit
    private func writeActiveEnergy(_ calories: Double, for date: Date) async throws {
        guard calories > 0 else { return }

        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            throw ActivityRingError.invalidType
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        // Distribute calories across waking hours (6 AM - 10 PM) for more realistic data
        let wakingStart = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: date)!
        let wakingEnd = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: date)!

        // Create hourly samples for more natural distribution
        let wakingHours = 16.0
        let caloriesPerHour = calories / wakingHours

        var samples: [HKQuantitySample] = []

        var currentHour = wakingStart
        while currentHour < wakingEnd {
            let nextHour = calendar.date(byAdding: .hour, value: 1, to: currentHour)!

            let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: caloriesPerHour)
            let sample = HKQuantitySample(
                type: energyType,
                quantity: quantity,
                start: currentHour,
                end: nextHour,
                metadata: [
                    HKMetadataKeyWasUserEntered: false,
                    "WhoopGenerositySync": true
                ]
            )
            samples.append(sample)

            currentHour = nextHour
        }

        try await healthStore.save(samples)
    }

    // MARK: - Exercise Minutes (Exercise Ring)

    /// Write exercise minutes to HealthKit
    private func writeExerciseMinutes(_ minutes: Double, for date: Date) async throws {
        guard minutes > 0 else { return }

        guard let exerciseType = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) else {
            throw ActivityRingError.invalidType
        }

        let calendar = Calendar.current

        // Distribute exercise minutes in 10-minute blocks throughout the day
        // This looks more natural than one big block
        let blocksNeeded = Int(ceil(minutes / 10.0))
        let minutesPerBlock = minutes / Double(blocksNeeded)

        // Spread blocks across typical active hours (7 AM - 9 PM)
        let startHour = 7
        let endHour = 21
        let availableHours = endHour - startHour
        let hourSpacing = max(1, availableHours / blocksNeeded)

        var samples: [HKQuantitySample] = []

        for i in 0..<blocksNeeded {
            let hour = startHour + (i * hourSpacing) % availableHours
            let minute = (i * 17) % 60 // Varied minute within hour

            guard let blockStart = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) else {
                continue
            }

            let blockDuration = min(minutesPerBlock, 10.0) // Max 10 min per block
            let blockEnd = blockStart.addingTimeInterval(blockDuration * 60)

            let quantity = HKQuantity(unit: .minute(), doubleValue: blockDuration)
            let sample = HKQuantitySample(
                type: exerciseType,
                quantity: quantity,
                start: blockStart,
                end: blockEnd,
                metadata: [
                    HKMetadataKeyWasUserEntered: false,
                    "WhoopGenerositySync": true
                ]
            )
            samples.append(sample)
        }

        try await healthStore.save(samples)
    }

    // MARK: - Stand Hours (Stand Ring)

    /// Write stand hours to HealthKit
    private func writeStandHours(_ hours: Set<Int>, for date: Date) async throws {
        guard !hours.isEmpty else { return }

        guard let standType = HKCategoryType.categoryType(forIdentifier: .appleStandHour) else {
            throw ActivityRingError.invalidType
        }

        let calendar = Calendar.current
        var samples: [HKCategorySample] = []

        for hour in hours {
            guard let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) else {
                continue
            }
            let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart)!

            let sample = HKCategorySample(
                type: standType,
                value: HKCategoryValueAppleStandHour.stood.rawValue,
                start: hourStart,
                end: hourEnd,
                metadata: [
                    HKMetadataKeyWasUserEntered: false,
                    "WhoopGenerositySync": true
                ]
            )
            samples.append(sample)
        }

        try await healthStore.save(samples)
    }

    // MARK: - Clear Existing Data

    /// Delete existing Vigor-written data for a specific day
    private func clearExistingData(for date: Date) async throws {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        // Delete our previously written samples (identified by metadata)
        for type in writeTypes {
            try await deleteVigorSamples(type: type, predicate: predicate)
        }
    }

    /// Delete samples that were written by Vigor
    private func deleteVigorSamples(type: HKSampleType, predicate: NSPredicate) async throws {
        // Fetch samples matching predicate
        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: results ?? [])
            }
            healthStore.execute(query)
        }

        // Filter to only our samples
        let vigorSamples = samples.filter { sample in
            (sample.metadata?["WhoopGenerositySync"] as? Bool) == true
        }

        guard !vigorSamples.isEmpty else { return }

        try await healthStore.delete(vigorSamples)
    }

    // MARK: - Check Existing Data

    /// Check if we've already written data for a specific date
    func hasWrittenData(for date: Date) async -> Bool {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return false
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: energyType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, results, _ in
                let hasVigorData = results?.contains { sample in
                    (sample.metadata?["WhoopGenerositySync"] as? Bool) == true
                } ?? false
                continuation.resume(returning: hasVigorData)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Read Current Ring Status

    /// Get current ring progress for a date (useful for UI)
    func getRingProgress(for date: Date) async -> (move: Double, exercise: Double, stand: Int)? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        async let move = fetchTotalQuantity(
            typeIdentifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            predicate: predicate
        )

        async let exercise = fetchTotalQuantity(
            typeIdentifier: .appleExerciseTime,
            unit: .minute(),
            predicate: predicate
        )

        async let stand = fetchStandHourCount(predicate: predicate)

        return await (move, exercise, stand)
    }

    private func fetchTotalQuantity(
        typeIdentifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        predicate: NSPredicate
    ) async -> Double {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: typeIdentifier) else {
            return 0
        }

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let value = statistics?.sumQuantity()?.doubleValue(for: unit) ?? 0
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func fetchStandHourCount(predicate: NSPredicate) async -> Int {
        guard let standType = HKCategoryType.categoryType(forIdentifier: .appleStandHour) else {
            return 0
        }

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: standType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                let stoodHours = results?.filter { sample in
                    (sample as? HKCategorySample)?.value == HKCategoryValueAppleStandHour.stood.rawValue
                }.count ?? 0
                continuation.resume(returning: stoodHours)
            }
            healthStore.execute(query)
        }
    }
}

// MARK: - Errors

enum ActivityRingError: LocalizedError {
    case healthKitUnavailable
    case notAuthorized
    case invalidType
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return "HealthKit is not available on this device"
        case .notAuthorized:
            return "HealthKit write permission not granted"
        case .invalidType:
            return "Invalid HealthKit type"
        case .writeFailed(let error):
            return "Failed to write to HealthKit: \(error.localizedDescription)"
        }
    }
}

// MARK: - Source Priority Information

extension ActivityRingWriter {
    /// Instructions for users on how to set up Source Priority
    static let sourcePriorityInstructions = """
    To ensure Vigor's data takes priority in your Activity Rings:

    1. Open the Apple Health app
    2. Tap your profile picture (top right)
    3. Scroll down and tap "Apps & Services"
    4. For each data type (Active Energy, Exercise Minutes, Stand Hours):
       a. Tap the data type
       b. Tap "Data Sources & Access"
       c. Tap "Edit" in the top right
       d. Drag "Vigor" above "WHOOP" in the priority list
       e. Tap "Done"

    This ensures Vigor's generous calculations are used for your rings
    instead of WHOOP's more conservative native sync.
    """
}
