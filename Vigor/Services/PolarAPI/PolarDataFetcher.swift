import Foundation
import PolarBleSdk
import RxSwift

// MARK: - Fetched Data Models

struct PolarFetchedData {
    let ppIntervals: [PolarPPInterval]
    let heartRateSamples: [PolarHRSample]
    let temperatureSamples: [PolarTemperatureSample]
    let fetchDate: Date
}

struct PolarPPInterval {
    let timestamp: Date
    let intervalMs: Int
    let skinContact: Bool
    let blockerBit: Bool

    var isValid: Bool {
        return skinContact && !blockerBit && intervalMs >= 300 && intervalMs <= 2000
    }
}

struct PolarHRSample {
    let timestamp: Date
    let heartRate: Int
}

struct PolarTemperatureSample {
    let timestamp: Date
    let temperature: Double
}

// MARK: - Polar Data Fetcher

@MainActor
final class PolarDataFetcher: ObservableObject {
    static let shared = PolarDataFetcher()

    private let bleService = PolarBLEService.shared
    private let disposeBag = DisposeBag()

    @Published var isFetching = false
    @Published var lastFetchError: String?

    private init() {}

    // MARK: - Fetch 24/7 Activity Data

    func fetchOfflineData() async throws -> PolarFetchedData {
        guard case .connected(let deviceId) = bleService.connectionState else {
            throw PolarFetchError.notConnected
        }

        isFetching = true
        lastFetchError = nil
        defer { isFetching = false }

        // Fetch data from the last 2 days (to capture overnight data)
        let calendar = Calendar.current
        let toDate = Date()
        let fromDate = calendar.date(byAdding: .day, value: -2, to: toDate)!

        var ppIntervals: [PolarPPInterval] = []
        var heartRateSamples: [PolarHRSample] = []
        var temperatureSamples: [PolarTemperatureSample] = []

        print("PolarDataFetcher: Fetching data from \(fromDate) to \(toDate)")

        // Fetch 24/7 PPI samples for HRV calculation
        do {
            print("PolarDataFetcher: Fetching PPI samples...")
            let ppiData = try await fetch247PPiSamples(deviceId: deviceId, fromDate: fromDate, toDate: toDate)
            print("PolarDataFetcher: Received \(ppiData.count) day(s) of PPI data")
            for (idx, day) in ppiData.enumerated() {
                print("PolarDataFetcher: Day \(idx): \(day.samples.count) samples")
            }
            ppIntervals = parse247PPiData(ppiData)
            print("PolarDataFetcher: Fetched \(ppIntervals.count) PPI intervals")
            if let first = ppIntervals.first {
                print("PolarDataFetcher: First PPI: \(first.intervalMs)ms at \(first.timestamp), valid=\(first.isValid)")
            }
        } catch {
            print("PolarDataFetcher: Failed to fetch PPI data - \(error)")
        }

        // Fetch 24/7 HR samples for RHR calculation
        do {
            print("PolarDataFetcher: Fetching HR samples...")
            let hrData = try await fetch247HrSamples(deviceId: deviceId, fromDate: fromDate, toDate: toDate)
            print("PolarDataFetcher: Received \(hrData.count) day(s) of HR data")
            for (idx, day) in hrData.enumerated() {
                print("PolarDataFetcher: Day \(idx): \(day.samples.count) samples")
            }
            heartRateSamples = parse247HrData(hrData)
            print("PolarDataFetcher: Fetched \(heartRateSamples.count) HR samples")
            if let first = heartRateSamples.first {
                print("PolarDataFetcher: First HR: \(first.heartRate) bpm at \(first.timestamp)")
            }
        } catch {
            print("PolarDataFetcher: Failed to fetch HR data - \(error)")
        }

        // Fetch skin temperature data
        do {
            print("PolarDataFetcher: Fetching temperature samples...")
            let tempData = try await fetchSkinTemperature(deviceId: deviceId, fromDate: fromDate, toDate: toDate)
            print("PolarDataFetcher: Received \(tempData.count) day(s) of temperature data")
            temperatureSamples = parseSkinTemperatureData(tempData)
            print("PolarDataFetcher: Fetched \(temperatureSamples.count) temperature samples")
            if !temperatureSamples.isEmpty {
                let temps = temperatureSamples.map { $0.temperature }
                let minTemp = temps.min() ?? 0
                let maxTemp = temps.max() ?? 0
                let avgTemp = temps.reduce(0, +) / Double(temps.count)
                print("PolarDataFetcher: Temperature range: \(String(format: "%.2f", minTemp))°C - \(String(format: "%.2f", maxTemp))°C, avg: \(String(format: "%.2f", avgTemp))°C")
            }
        } catch {
            print("PolarDataFetcher: Failed to fetch temperature data - \(error)")
        }

        return PolarFetchedData(
            ppIntervals: ppIntervals,
            heartRateSamples: heartRateSamples,
            temperatureSamples: temperatureSamples,
            fetchDate: Date()
        )
    }

    // MARK: - Fetch 24/7 PPI Samples

    private func fetch247PPiSamples(deviceId: String, fromDate: Date, toDate: Date) async throws -> [Polar247PPiSamplesData] {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.get247PPiSamples(identifier: deviceId, fromDate: fromDate, toDate: toDate)
                .observe(on: MainScheduler.instance)
                .subscribe(
                    onSuccess: { data in
                        continuation.resume(returning: data)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: PolarFetchError.fetchFailed(error.localizedDescription))
                    }
                )
                .disposed(by: disposeBag)
        }
    }

    private func parse247PPiData(_ dataArray: [Polar247PPiSamplesData]) -> [PolarPPInterval] {
        var intervals: [PolarPPInterval] = []
        let calendar = Calendar.current

        var skippedDateParseCount = 0
        var totalPpiValues = 0
        var validPpiCount = 0

        for dayData in dataArray {
            // Get the date from dayData.date (DateComponents)
            guard let baseDate = calendar.date(from: dayData.date) else {
                print("PolarDataFetcher: Failed to parse day date from DateComponents")
                continue
            }
            print("PolarDataFetcher: Processing PPI data for date: \(baseDate)")

            for sample in dayData.samples {
                guard let startTimeStr = sample.startTime else {
                    print("PolarDataFetcher: PPI sample missing startTime")
                    continue
                }

                // Parse time-only string like '17:49:08.567' or '17:49:08'
                guard let startTime = parseTimeAndCombineWithDate(timeString: startTimeStr, baseDate: baseDate) else {
                    skippedDateParseCount += 1
                    if skippedDateParseCount <= 3 {
                        print("PolarDataFetcher: Failed to parse PPI startTime: '\(startTimeStr)'")
                    }
                    continue
                }

                let ppiValues = sample.ppiValueList ?? []
                let statusList = sample.statusList ?? []
                totalPpiValues += ppiValues.count

                var currentTime = startTime
                for (index, ppi) in ppiValues.enumerated() {
                    let status = index < statusList.count ? statusList[index] : nil

                    // Check skin contact status - SKIN_CONTACT_DETECTED means contact is good
                    let skinContact = status?.skinContact == .SKIN_CONTACT_DETECTED

                    // Check movement status - NO_MOVING_DETECTED means no movement (good for HRV)
                    let movementDetected = status?.movement == .MOVING_DETECTED

                    let interval = PolarPPInterval(
                        timestamp: currentTime,
                        intervalMs: Int(ppi),
                        skinContact: skinContact,
                        blockerBit: movementDetected
                    )

                    if interval.isValid {
                        validPpiCount += 1
                    }

                    intervals.append(interval)
                    currentTime = currentTime.addingTimeInterval(Double(ppi) / 1000.0)
                }
            }
        }

        if skippedDateParseCount > 0 {
            print("PolarDataFetcher: Skipped \(skippedDateParseCount) samples due to date parsing issues")
        }
        print("PolarDataFetcher: Total PPI values: \(totalPpiValues), Valid: \(validPpiCount)")

        return intervals
    }

    /// Parse a time-only string (e.g., '17:49:08.567') and combine with a base date
    private func parseTimeAndCombineWithDate(timeString: String, baseDate: Date) -> Date? {
        let calendar = Calendar.current

        // Try parsing with fractional seconds first: HH:mm:ss.SSS
        let timeFormatterWithFraction = DateFormatter()
        timeFormatterWithFraction.dateFormat = "HH:mm:ss.SSS"
        timeFormatterWithFraction.timeZone = TimeZone(identifier: "UTC")

        // Try without fractional seconds: HH:mm:ss
        let timeFormatterSimple = DateFormatter()
        timeFormatterSimple.dateFormat = "HH:mm:ss"
        timeFormatterSimple.timeZone = TimeZone(identifier: "UTC")

        var timeComponents: DateComponents?

        // Reference date for parsing time-only strings
        let referenceDate = Date(timeIntervalSince1970: 0)

        if let parsedTime = timeFormatterWithFraction.date(from: timeString) {
            timeComponents = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: parsedTime)
        } else if let parsedTime = timeFormatterSimple.date(from: timeString) {
            timeComponents = calendar.dateComponents([.hour, .minute, .second], from: parsedTime)
        }

        guard let tc = timeComponents else { return nil }

        // Combine base date with time components
        var combined = calendar.dateComponents([.year, .month, .day], from: baseDate)
        combined.hour = tc.hour
        combined.minute = tc.minute
        combined.second = tc.second
        combined.nanosecond = tc.nanosecond

        return calendar.date(from: combined)
    }

    // MARK: - Fetch 24/7 HR Samples

    private func fetch247HrSamples(deviceId: String, fromDate: Date, toDate: Date) async throws -> [Polar247HrSamplesData] {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.get247HrSamples(identifier: deviceId, fromDate: fromDate, toDate: toDate)
                .observe(on: MainScheduler.instance)
                .subscribe(
                    onSuccess: { data in
                        continuation.resume(returning: data)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: PolarFetchError.fetchFailed(error.localizedDescription))
                    }
                )
                .disposed(by: disposeBag)
        }
    }

    private func parse247HrData(_ dataArray: [Polar247HrSamplesData]) -> [PolarHRSample] {
        var samples: [PolarHRSample] = []

        for dayData in dataArray {
            let calendar = Calendar.current
            guard let date = calendar.date(from: dayData.date) else { continue }

            for sample in dayData.samples {
                guard let sampleDate = calendar.date(from: sample.time) else { continue }

                // Combine date and time components
                var components = calendar.dateComponents([.year, .month, .day], from: date)
                let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: sampleDate)
                components.hour = timeComponents.hour
                components.minute = timeComponents.minute
                components.second = timeComponents.second

                guard let timestamp = calendar.date(from: components) else { continue }

                for hr in sample.hrSamples {
                    let hrSample = PolarHRSample(
                        timestamp: timestamp,
                        heartRate: Int(hr)
                    )
                    samples.append(hrSample)
                }
            }
        }

        return samples
    }

    // MARK: - Fetch Skin Temperature

    private func fetchSkinTemperature(deviceId: String, fromDate: Date, toDate: Date) async throws -> [PolarSkinTemperatureData.PolarSkinTemperatureResult] {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.getSkinTemperature(identifier: deviceId, fromDate: fromDate, toDate: toDate)
                .observe(on: MainScheduler.instance)
                .subscribe(
                    onSuccess: { data in
                        continuation.resume(returning: data)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: PolarFetchError.fetchFailed(error.localizedDescription))
                    }
                )
                .disposed(by: disposeBag)
        }
    }

    private func parseSkinTemperatureData(_ dataArray: [PolarSkinTemperatureData.PolarSkinTemperatureResult]) -> [PolarTemperatureSample] {
        var samples: [PolarTemperatureSample] = []

        for result in dataArray {
            guard let date = result.date,
                  let tempSamples = result.skinTemperatureList else {
                continue
            }

            for sample in tempSamples {
                guard let temp = sample.temperature else { continue }

                let timestamp = date.addingTimeInterval(Double(sample.recordingTimeDeltaMs ?? 0) / 1000.0)
                let tempSample = PolarTemperatureSample(
                    timestamp: timestamp,
                    temperature: Double(temp)
                )
                samples.append(tempSample)
            }
        }

        return samples
    }

    // MARK: - Helper

    private func parseCustomDate(_ string: String) -> Date? {
        // Try common date formats
        let formatters: [DateFormatter] = [
            {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                f.timeZone = TimeZone(identifier: "UTC")
                return f
            }(),
            {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd HH:mm:ss"
                f.timeZone = TimeZone(identifier: "UTC")
                return f
            }()
        ]

        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}

// MARK: - Errors

enum PolarFetchError: LocalizedError {
    case notConnected
    case listFailed(String)
    case fetchFailed(String)
    case deleteFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Polar device not connected"
        case .listFailed(let message):
            return "Failed to list recordings: \(message)"
        case .fetchFailed(let message):
            return "Failed to fetch recording: \(message)"
        case .deleteFailed(let message):
            return "Failed to delete recording: \(message)"
        }
    }
}
