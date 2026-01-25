import Foundation
import HealthKit

// MARK: - Write Result

struct PolarHealthKitWriteResult {
    let hrvWritten: Bool
    let rhrWritten: Bool
    let temperatureWritten: Bool
    let sleepWritten: Bool
    let stepsWritten: Bool
    let writeDate: Date
    let errors: [String]

    var success: Bool {
        return errors.isEmpty && (hrvWritten || rhrWritten || temperatureWritten || sleepWritten || stepsWritten)
    }
}

// MARK: - Polar HealthKit Writer

@MainActor
final class PolarHealthKitWriter: ObservableObject {
    static let shared = PolarHealthKitWriter()

    private let healthStore = HKHealthStore()

    @Published var isAuthorized = false
    @Published var lastWriteResult: PolarHealthKitWriteResult?

    // Metadata key to identify Polar-written samples
    nonisolated static let polarSourceKey = "PolarLoopSync"

    private let writeTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = [
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!,
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        return types
    }()

    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!,
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)!
        ]
        return types
    }()

    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw PolarHealthKitError.healthKitUnavailable
        }

        try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
        isAuthorized = true
    }

    // MARK: - Write All Metrics

    func writeMetrics(
        hrv: PolarHRVResult?,
        rhr: PolarRHRResult?,
        temperature: Double?,
        sleep: PolarSleepResult?,
        steps: [PolarStepsSample] = [],
        measurementDate: Date
    ) async -> PolarHealthKitWriteResult {
        var errors: [String] = []
        var hrvWritten = false
        var rhrWritten = false
        var temperatureWritten = false
        var sleepWritten = false
        var stepsWritten = false

        // Write HRV
        if let hrv = hrv, hrv.isReliable {
            do {
                try await writeHRV(sdnn: hrv.sdnn, date: measurementDate)
                hrvWritten = true
                print("PolarHealthKitWriter: Wrote HRV \(hrv.sdnn) ms")
            } catch {
                errors.append("HRV: \(error.localizedDescription)")
            }
        }

        // Write RHR
        if let rhr = rhr {
            do {
                try await writeRestingHeartRate(rhr.restingHeartRate, date: measurementDate)
                rhrWritten = true
                print("PolarHealthKitWriter: Wrote RHR \(rhr.restingHeartRate) bpm")
            } catch {
                errors.append("RHR: \(error.localizedDescription)")
            }
        }

        // Write Temperature
        if let temperature = temperature {
            do {
                try await writeTemperature(temperature, date: measurementDate)
                temperatureWritten = true
                print("PolarHealthKitWriter: Wrote temperature \(temperature)°C")
            } catch {
                errors.append("Temperature: \(error.localizedDescription)")
            }
        }

        // Write Sleep
        if let sleep = sleep {
            do {
                try await writeSleep(sleep)
                sleepWritten = true
                print("PolarHealthKitWriter: Wrote sleep \(sleep.sleepDurationMinutes) min")
            } catch {
                errors.append("Sleep: \(error.localizedDescription)")
            }
        }

        // Write Steps
        print("PolarHealthKitWriter: Steps to write: \(steps.count) samples")
        if !steps.isEmpty {
            do {
                try await writeSteps(steps)
                stepsWritten = true
                let totalSteps = steps.reduce(0) { $0 + $1.steps }
                print("PolarHealthKitWriter: Successfully wrote \(totalSteps) steps across \(steps.count) days to HealthKit")
            } catch {
                print("PolarHealthKitWriter: Failed to write steps - \(error)")
                errors.append("Steps: \(error.localizedDescription)")
            }
        } else {
            print("PolarHealthKitWriter: No steps samples to write")
        }

        let result = PolarHealthKitWriteResult(
            hrvWritten: hrvWritten,
            rhrWritten: rhrWritten,
            temperatureWritten: temperatureWritten,
            sleepWritten: sleepWritten,
            stepsWritten: stepsWritten,
            writeDate: Date(),
            errors: errors
        )

        lastWriteResult = result
        return result
    }

    // MARK: - Write HRV

    func writeHRV(sdnn: Double, date: Date) async throws {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            throw PolarHealthKitError.invalidType
        }

        // Delete existing Polar sample for today (allows updating with new corrected value)
        if await hasPolarSample(type: hrvType, on: date) {
            print("PolarHealthKitWriter: Deleting old HRV sample to update with new value")
            try? await deletePolarSamples(type: hrvType, on: date)
        }

        let quantity = HKQuantity(unit: HKUnit.secondUnit(with: .milli), doubleValue: sdnn)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        // HRV is typically measured during sleep, associate with early morning
        let measurementTime = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: startOfDay) ?? date

        let sample = HKQuantitySample(
            type: hrvType,
            quantity: quantity,
            start: measurementTime,
            end: measurementTime,
            metadata: [
                HKMetadataKeyWasUserEntered: false,
                Self.polarSourceKey: true
            ]
        )

        try await healthStore.save(sample)
    }

    // MARK: - Write Resting Heart Rate

    func writeRestingHeartRate(_ heartRate: Double, date: Date) async throws {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            throw PolarHealthKitError.invalidType
        }

        // Delete existing Polar sample for today (allows updating with new corrected value)
        if await hasPolarSample(type: rhrType, on: date) {
            print("PolarHealthKitWriter: Deleting old RHR sample to update with new value")
            try? await deletePolarSamples(type: rhrType, on: date)
        }

        let quantity = HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()), doubleValue: heartRate)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let measurementTime = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: startOfDay) ?? date

        let sample = HKQuantitySample(
            type: rhrType,
            quantity: quantity,
            start: measurementTime,
            end: measurementTime,
            metadata: [
                HKMetadataKeyWasUserEntered: false,
                Self.polarSourceKey: true
            ]
        )

        try await healthStore.save(sample)
    }

    // MARK: - Write Temperature

    func writeTemperature(_ celsius: Double, date: Date) async throws {
        // Note: .appleSleepingWristTemperature rejects third-party writes
        // Use .bodyTemperature instead
        guard let tempType = HKQuantityType.quantityType(forIdentifier: .bodyTemperature) else {
            throw PolarHealthKitError.invalidType
        }

        // Check authorization status
        let authStatus = healthStore.authorizationStatus(for: tempType)
        print("PolarHealthKitWriter: Body temperature authorization status: \(authStatus.rawValue) (0=notDetermined, 1=denied, 2=authorized)")

        // Delete existing Polar sample for today (allows updating with new corrected value)
        if await hasPolarSample(type: tempType, on: date) {
            print("PolarHealthKitWriter: Deleting old temperature sample to update with new value")
            try? await deletePolarSamples(type: tempType, on: date)
        }

        let quantity = HKQuantity(unit: .degreeCelsius(), doubleValue: celsius)

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let measurementTime = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: startOfDay) ?? date

        let sample = HKQuantitySample(
            type: tempType,
            quantity: quantity,
            start: measurementTime,
            end: measurementTime,
            metadata: [
                HKMetadataKeyWasUserEntered: false,
                Self.polarSourceKey: true
            ]
        )

        print("PolarHealthKitWriter: Saving temperature sample \(celsius)°C for \(measurementTime)")
        try await healthStore.save(sample)
        print("PolarHealthKitWriter: Temperature save completed successfully")
    }

    // MARK: - Write Steps

    func writeSteps(_ stepsSamples: [PolarStepsSample]) async throws {
        guard let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            throw PolarHealthKitError.invalidType
        }

        var samplesToSave: [HKQuantitySample] = []
        let calendar = Calendar.current

        for stepSample in stepsSamples {
            // Skip days with 0 steps
            guard stepSample.steps > 0 else { continue }

            let startOfDay = calendar.startOfDay(for: stepSample.date)

            // Delete existing Polar steps for this day
            if await hasPolarSample(type: stepsType, on: stepSample.date) {
                print("PolarHealthKitWriter: Deleting old steps sample for \(startOfDay)")
                try? await deletePolarSamples(type: stepsType, on: stepSample.date)
            }

            // Distribute steps across waking hours (6 AM - 10 PM) for more realistic data
            let wakingStart = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: stepSample.date)!
            let wakingEnd = calendar.date(bySettingHour: 22, minute: 0, second: 0, of: stepSample.date)!

            // Create a single sample spanning the waking hours
            let quantity = HKQuantity(unit: .count(), doubleValue: Double(stepSample.steps))
            let sample = HKQuantitySample(
                type: stepsType,
                quantity: quantity,
                start: wakingStart,
                end: wakingEnd,
                metadata: [
                    HKMetadataKeyWasUserEntered: false,
                    Self.polarSourceKey: true
                ]
            )
            samplesToSave.append(sample)
            print("PolarHealthKitWriter: Preparing steps sample - \(stepSample.steps) steps for \(startOfDay)")
        }

        guard !samplesToSave.isEmpty else {
            print("PolarHealthKitWriter: No steps to write")
            return
        }

        print("PolarHealthKitWriter: Writing \(samplesToSave.count) steps samples to HealthKit...")

        try await healthStore.save(samplesToSave)
        print("PolarHealthKitWriter: Saved \(samplesToSave.count) steps samples")
    }

    // MARK: - Write Sleep

    func writeSleep(_ sleepResult: PolarSleepResult) async throws {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw PolarHealthKitError.invalidType
        }

        // Validate sleep times
        guard sleepResult.sleepStartTime < sleepResult.sleepEndTime else {
            print("PolarHealthKitWriter: Invalid sleep times - start (\(sleepResult.sleepStartTime)) >= end (\(sleepResult.sleepEndTime))")
            throw PolarHealthKitError.invalidSleepData
        }

        print("PolarHealthKitWriter: Writing sleep from \(sleepResult.sleepStartTime) to \(sleepResult.sleepEndTime) (\(sleepResult.sleepDurationMinutes) min, \(sleepResult.sleepPhases.count) phases)")

        // Check if we already have Polar sleep data for this night
        if await hasPolarSleepSample(overlapping: sleepResult.sleepInterval) {
            print("PolarHealthKitWriter: Deleting old sleep samples to update with new data")
            try? await deletePolarSleepSamples(overlapping: sleepResult.sleepInterval)
        }

        var samplesToSave: [HKCategorySample] = []

        // Write individual sleep phases if available
        if !sleepResult.sleepPhases.isEmpty {
            // Sort phases by time
            let sortedPhases = sleepResult.sleepPhases.sorted {
                $0.secondsFromSleepStart < $1.secondsFromSleepStart
            }

            for (index, phase) in sortedPhases.enumerated() {
                let phaseStart = phase.timestamp(relativeTo: sleepResult.sleepStartTime)
                let phaseEnd: Date

                if index < sortedPhases.count - 1 {
                    phaseEnd = sortedPhases[index + 1].timestamp(relativeTo: sleepResult.sleepStartTime)
                } else {
                    phaseEnd = sleepResult.sleepEndTime
                }

                // Skip invalid intervals
                guard phaseStart < phaseEnd else { continue }

                let categoryValue = healthKitSleepValue(for: phase.state)

                let sample = HKCategorySample(
                    type: sleepType,
                    value: categoryValue.rawValue,
                    start: phaseStart,
                    end: phaseEnd,
                    metadata: [
                        HKMetadataKeyWasUserEntered: false,
                        Self.polarSourceKey: true
                    ]
                )
                samplesToSave.append(sample)
            }
        } else {
            // No phase data - write as single asleep period
            let sample = HKCategorySample(
                type: sleepType,
                value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                start: sleepResult.sleepStartTime,
                end: sleepResult.sleepEndTime,
                metadata: [
                    HKMetadataKeyWasUserEntered: false,
                    Self.polarSourceKey: true
                ]
            )
            samplesToSave.append(sample)
        }

        // Also write an "inBed" sample for the entire duration
        let inBedSample = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: sleepResult.sleepStartTime,
            end: sleepResult.sleepEndTime,
            metadata: [
                HKMetadataKeyWasUserEntered: false,
                Self.polarSourceKey: true
            ]
        )
        samplesToSave.append(inBedSample)

        print("PolarHealthKitWriter: Saving \(samplesToSave.count) sleep samples from \(sleepResult.sleepStartTime) to \(sleepResult.sleepEndTime)")
        try await healthStore.save(samplesToSave)
        print("PolarHealthKitWriter: Sleep save completed successfully")
    }

    private func healthKitSleepValue(for polarState: PolarSleepState) -> HKCategoryValueSleepAnalysis {
        switch polarState {
        case .wake:
            return .awake
        case .rem:
            return .asleepREM
        case .lightSleep:
            return .asleepCore
        case .deepSleep:
            return .asleepDeep
        case .unknown:
            return .asleepUnspecified
        }
    }

    private func hasPolarSleepSample(overlapping interval: DateInterval) async -> Bool {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return false
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error = error {
                    print("PolarHealthKitWriter: Error checking for existing sleep samples: \(error)")
                    continuation.resume(returning: false)
                    return
                }

                let polarSamples = results?.filter { sample in
                    (sample.metadata?[Self.polarSourceKey] as? Bool) == true
                } ?? []

                print("PolarHealthKitWriter: Found \(polarSamples.count) existing Polar sleep samples")
                continuation.resume(returning: !polarSamples.isEmpty)
            }
            healthStore.execute(query)
        }
    }

    private func deletePolarSleepSamples(overlapping interval: DateInterval) async throws {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: .strictStartDate
        )

        let samples: [HKSample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: results ?? [])
            }
            healthStore.execute(query)
        }

        let polarSamples = samples.filter { sample in
            (sample.metadata?[Self.polarSourceKey] as? Bool) == true
        }

        guard !polarSamples.isEmpty else { return }

        try await healthStore.delete(polarSamples)
        print("PolarHealthKitWriter: Deleted \(polarSamples.count) old Polar sleep samples")
    }

    // MARK: - Duplicate Detection

    private func hasPolarSample(type: HKQuantityType, on date: Date) async -> Bool {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, error in
                if let error = error {
                    print("PolarHealthKitWriter: Error checking for existing samples: \(error)")
                    continuation.resume(returning: false)
                    return
                }

                let totalSamples = results?.count ?? 0
                let polarSamples = results?.filter { sample in
                    (sample.metadata?[Self.polarSourceKey] as? Bool) == true
                } ?? []

                print("PolarHealthKitWriter: Found \(totalSamples) total samples, \(polarSamples.count) Polar samples for \(type.identifier) on \(startOfDay)")
                continuation.resume(returning: !polarSamples.isEmpty)
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Delete Polar Samples

    func deletePolarSamples(for date: Date) async throws {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        for type in writeTypes {
            try await deletePolarSamples(type: type, predicate: predicate)
        }
    }

    /// Delete Polar samples for a specific type and date
    private func deletePolarSamples(type: HKQuantityType, on date: Date) async throws {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfDay,
            end: endOfDay,
            options: .strictStartDate
        )

        try await deletePolarSamples(type: type, predicate: predicate)
    }

    private func deletePolarSamples(type: HKSampleType, predicate: NSPredicate) async throws {
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

        let polarSamples = samples.filter { sample in
            (sample.metadata?[Self.polarSourceKey] as? Bool) == true
        }

        guard !polarSamples.isEmpty else { return }

        try await healthStore.delete(polarSamples)
    }
}

// MARK: - Errors

enum PolarHealthKitError: LocalizedError {
    case healthKitUnavailable
    case invalidType
    case writeFailed(Error)
    case notAuthorized
    case invalidSleepData

    var errorDescription: String? {
        switch self {
        case .healthKitUnavailable:
            return "HealthKit is not available on this device"
        case .invalidType:
            return "Invalid HealthKit type"
        case .writeFailed(let error):
            return "Failed to write to HealthKit: \(error.localizedDescription)"
        case .notAuthorized:
            return "HealthKit write permission not granted"
        case .invalidSleepData:
            return "Invalid sleep data (start time after end time)"
        }
    }
}
