import Foundation
import HealthKit

// MARK: - Write Result

struct PolarHealthKitWriteResult {
    let hrvWritten: Bool
    let rhrWritten: Bool
    let temperatureWritten: Bool
    let writeDate: Date
    let errors: [String]

    var success: Bool {
        return errors.isEmpty && (hrvWritten || rhrWritten || temperatureWritten)
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
    static let polarSourceKey = "PolarLoopSync"

    private let writeTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = [
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!
        ]
        return types
    }()

    private let readTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = [
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate)!,
            HKQuantityType.quantityType(forIdentifier: .bodyTemperature)!
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
        measurementDate: Date
    ) async -> PolarHealthKitWriteResult {
        var errors: [String] = []
        var hrvWritten = false
        var rhrWritten = false
        var temperatureWritten = false

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

        let result = PolarHealthKitWriteResult(
            hrvWritten: hrvWritten,
            rhrWritten: rhrWritten,
            temperatureWritten: temperatureWritten,
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

        // Check for existing Polar samples to prevent duplicates
        if await hasPolarSample(type: hrvType, on: date) {
            print("PolarHealthKitWriter: HRV already written for \(date)")
            return
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

        // Check for existing Polar samples
        if await hasPolarSample(type: rhrType, on: date) {
            print("PolarHealthKitWriter: RHR already written for \(date)")
            return
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

        // Check for existing Polar samples
        if await hasPolarSample(type: tempType, on: date) {
            print("PolarHealthKitWriter: Temperature already written for \(date)")
            return
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

        try await healthStore.save(sample)
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
            ) { _, results, _ in
                let hasPolarSample = results?.contains { sample in
                    (sample.metadata?[Self.polarSourceKey] as? Bool) == true
                } ?? false
                continuation.resume(returning: hasPolarSample)
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
        }
    }
}
