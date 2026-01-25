import Foundation
import PolarBleSdk
import RxSwift

// MARK: - Fetched Data Models

struct PolarFetchedData {
    let ppIntervals: [PolarPPInterval]
    let heartRateSamples: [PolarHRSample]
    let temperatureSamples: [PolarTemperatureSample]
    let sleepData: [PolarSleepResult]
    let nightlyRecharge: [PolarNightlyRechargeResult]
    let stepsSamples: [PolarStepsSample]
    let fetchDate: Date
}

struct PolarStepsSample {
    let date: Date
    let steps: Int
}

/// Pre-computed nightly recovery data from Polar device
struct PolarNightlyRechargeResult {
    let date: DateComponents?
    let hrvRMSSD: Double          // HRV in milliseconds (RMSSD)
    let meanRRI: Double           // Mean RR interval in ms (60000/RRI = HR in bpm)
    let baselineRMSSD: Double?    // Baseline HRV for comparison
    let recoveryIndicator: Int?   // Recovery score (0-3+)
    let ansStatus: Double?        // ANS status

    /// Computed resting heart rate from mean RRI
    var restingHeartRate: Double {
        guard meanRRI > 0 else { return 0 }
        return 60000.0 / meanRRI
    }
}

struct PolarSleepResult {
    let sleepStartTime: Date
    let sleepEndTime: Date
    let sleepDurationMinutes: Int
    let sleepPhases: [PolarSleepPhase]
    let sleepResultDate: DateComponents?

    var sleepInterval: DateInterval {
        DateInterval(start: sleepStartTime, end: sleepEndTime)
    }
}

struct PolarSleepPhase {
    let secondsFromSleepStart: UInt32
    let state: PolarSleepState

    func timestamp(relativeTo sleepStart: Date) -> Date {
        sleepStart.addingTimeInterval(Double(secondsFromSleepStart))
    }
}

enum PolarSleepState: String {
    case unknown = "UNKNOWN"
    case wake = "WAKE"
    case rem = "REM"
    case lightSleep = "NONREM12"  // Stages 1-2
    case deepSleep = "NONREM3"   // Stage 3

    var isAsleep: Bool {
        switch self {
        case .rem, .lightSleep, .deepSleep:
            return true
        case .wake, .unknown:
            return false
        }
    }
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

        // Check sleep recording state before fetching sleep data
        var sleepData: [PolarSleepResult] = []
        var sleepRecordingActive = false
        do {
            print("PolarDataFetcher: Checking sleep recording state...")
            sleepRecordingActive = try await getSleepRecordingState(deviceId: deviceId)
            print("PolarDataFetcher: Sleep recording active: \(sleepRecordingActive)")
        } catch {
            print("PolarDataFetcher: Failed to check sleep recording state - \(error)")
        }

        // Fetch sleep data (even if recording is active, there might be previous nights' data)
        do {
            print("PolarDataFetcher: Fetching sleep data...")
            let rawSleepData = try await fetchSleepData(deviceId: deviceId, fromDate: fromDate, toDate: toDate)
            print("PolarDataFetcher: Received \(rawSleepData.count) sleep record(s)")
            sleepData = parseSleepData(rawSleepData)
            for (idx, sleep) in sleepData.enumerated() {
                print("PolarDataFetcher: Sleep \(idx + 1): \(sleep.sleepStartTime) - \(sleep.sleepEndTime) (\(sleep.sleepDurationMinutes) min)")
            }

            if sleepData.isEmpty && sleepRecordingActive {
                print("PolarDataFetcher: ⚠️ No sleep data available - device is still recording sleep")
                print("PolarDataFetcher: Sleep data becomes available ~90 minutes after waking")
            }
        } catch {
            print("PolarDataFetcher: Failed to fetch sleep data - \(error)")
        }

        // Fetch nightly recharge data (pre-computed HRV and recovery metrics)
        var nightlyRecharge: [PolarNightlyRechargeResult] = []
        do {
            print("PolarDataFetcher: Fetching nightly recharge data...")
            let rawNightlyData = try await fetchNightlyRecharge(deviceId: deviceId, fromDate: fromDate, toDate: toDate)
            print("PolarDataFetcher: Received \(rawNightlyData.count) nightly recharge record(s)")
            nightlyRecharge = parseNightlyRechargeData(rawNightlyData)
            for (idx, nr) in nightlyRecharge.enumerated() {
                print("PolarDataFetcher: Nightly \(idx + 1): HRV=\(String(format: "%.1f", nr.hrvRMSSD))ms, RHR=\(String(format: "%.1f", nr.restingHeartRate))bpm, Recovery=\(nr.recoveryIndicator ?? -1)")
            }
        } catch {
            print("PolarDataFetcher: Failed to fetch nightly recharge data - \(error)")
        }

        // Fetch steps data
        var stepsSamples: [PolarStepsSample] = []
        do {
            print("PolarDataFetcher: Fetching steps data...")
            let rawStepsData = try await fetchSteps(deviceId: deviceId, fromDate: fromDate, toDate: toDate)
            print("PolarDataFetcher: Received \(rawStepsData.count) steps record(s)")
            stepsSamples = parseStepsData(rawStepsData)
            for sample in stepsSamples {
                print("PolarDataFetcher: Steps on \(sample.date): \(sample.steps)")
            }
        } catch {
            print("PolarDataFetcher: Failed to fetch steps data - \(error)")
        }

        return PolarFetchedData(
            ppIntervals: ppIntervals,
            heartRateSamples: heartRateSamples,
            temperatureSamples: temperatureSamples,
            sleepData: sleepData,
            nightlyRecharge: nightlyRecharge,
            stepsSamples: stepsSamples,
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
                // Debug: log first sample's status info
                if totalPpiValues == 0 && !statusList.isEmpty {
                    let firstStatus = statusList[0]
                    print("PolarDataFetcher: First PPI status - skinContact: \(String(describing: firstStatus.skinContact)), movement: \(String(describing: firstStatus.movement))")
                }

                for (index, ppi) in ppiValues.enumerated() {
                    let status = index < statusList.count ? statusList[index] : nil

                    // Check skin contact status - SKIN_CONTACT_DETECTED means contact is good
                    // If status is nil, assume contact is good (some devices don't report status)
                    let skinContact = status?.skinContact == .SKIN_CONTACT_DETECTED || status == nil

                    // Check movement status - only block if movement is explicitly detected
                    // If status is nil, assume no movement
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
    /// Note: Polar SDK returns times in local timezone, so we use local calendar throughout
    private func parseTimeAndCombineWithDate(timeString: String, baseDate: Date) -> Date? {
        // Use local calendar for all operations - Polar SDK uses device local time
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        // Parse time components directly from the string (HH:mm:ss.SSS or HH:mm:ss)
        let timeParts = timeString.split(separator: ":")
        guard timeParts.count >= 3 else { return nil }

        guard let hour = Int(timeParts[0]) else { return nil }

        guard let minute = Int(timeParts[1]) else { return nil }

        // Handle seconds which may have fractional part
        let secondsPart = String(timeParts[2])
        let secondsComponents = secondsPart.split(separator: ".")
        guard let second = Int(secondsComponents[0]) else { return nil }

        var nanosecond: Int = 0
        if secondsComponents.count > 1, let ms = Int(secondsComponents[1]) {
            // Convert milliseconds to nanoseconds
            nanosecond = ms * 1_000_000
        }

        // Combine base date with time components using local timezone
        var combined = calendar.dateComponents([.year, .month, .day, .timeZone], from: baseDate)
        combined.hour = hour
        combined.minute = minute
        combined.second = second
        combined.nanosecond = nanosecond

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

    // MARK: - Sleep Recording State

    private func getSleepRecordingState(deviceId: String) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.getSleepRecordingState(identifier: deviceId)
                .observe(on: MainScheduler.instance)
                .subscribe(
                    onSuccess: { isRecording in
                        continuation.resume(returning: isRecording)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: PolarFetchError.fetchFailed(error.localizedDescription))
                    }
                )
                .disposed(by: disposeBag)
        }
    }

    // MARK: - Fetch Sleep Data

    private func fetchSleepData(deviceId: String, fromDate: Date, toDate: Date) async throws -> [PolarSleepData.PolarSleepAnalysisResult] {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.getSleepData(identifier: deviceId, fromDate: fromDate, toDate: toDate)
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

    private func parseSleepData(_ dataArray: [PolarSleepData.PolarSleepAnalysisResult]) -> [PolarSleepResult] {
        var results: [PolarSleepResult] = []

        for sleepRecord in dataArray {
            guard let startTime = sleepRecord.sleepStartTime,
                  let endTime = sleepRecord.sleepEndTime else {
                print("PolarDataFetcher: Skipping sleep record - missing start/end time")
                continue
            }

            // Parse sleep phases
            var phases: [PolarSleepPhase] = []
            if let sleepPhases = sleepRecord.sleepWakePhases {
                for phase in sleepPhases {
                    let state: PolarSleepState
                    switch phase.state {
                    case .WAKE:
                        state = .wake
                    case .REM:
                        state = .rem
                    case .NONREM12:
                        state = .lightSleep
                    case .NONREM3:
                        state = .deepSleep
                    case .UNKNOWN, .none:
                        state = .unknown
                    }

                    phases.append(PolarSleepPhase(
                        secondsFromSleepStart: phase.secondsFromSleepStart,
                        state: state
                    ))
                }
            }

            let durationMinutes = Int(endTime.timeIntervalSince(startTime) / 60)

            let result = PolarSleepResult(
                sleepStartTime: startTime,
                sleepEndTime: endTime,
                sleepDurationMinutes: durationMinutes,
                sleepPhases: phases,
                sleepResultDate: sleepRecord.sleepResultDate
            )
            results.append(result)
        }

        // Sort by start time (most recent first)
        return results.sorted { $0.sleepStartTime > $1.sleepStartTime }
    }

    // MARK: - Fetch Nightly Recharge Data

    private func fetchNightlyRecharge(deviceId: String, fromDate: Date, toDate: Date) async throws -> [PolarNightlyRechargeData] {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.getNightlyRecharge(identifier: deviceId, fromDate: fromDate, toDate: toDate)
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

    private func parseNightlyRechargeData(_ dataArray: [PolarNightlyRechargeData]) -> [PolarNightlyRechargeResult] {
        var results: [PolarNightlyRechargeResult] = []

        for data in dataArray {
            // Skip if no RMSSD value (required for HRV)
            guard let rmssd = data.meanNightlyRecoveryRMSSD, rmssd > 0 else {
                print("PolarDataFetcher: Skipping nightly recharge - no RMSSD value")
                continue
            }

            guard let rri = data.meanNightlyRecoveryRRI, rri > 0 else {
                print("PolarDataFetcher: Skipping nightly recharge - no RRI value")
                continue
            }

            let result = PolarNightlyRechargeResult(
                date: data.sleepResultDate,
                hrvRMSSD: Double(rmssd),
                meanRRI: Double(rri),
                baselineRMSSD: data.meanBaselineRMSSD.map { Double($0) },
                recoveryIndicator: data.recoveryIndicator.map { Int($0) },
                ansStatus: data.ansStatus.map { Double($0) }
            )
            results.append(result)
        }

        // Sort by date (most recent first)
        return results
    }

    // MARK: - Fetch Steps Data

    private func fetchSteps(deviceId: String, fromDate: Date, toDate: Date) async throws -> [PolarStepsData] {
        return try await withCheckedThrowingContinuation { continuation in
            bleService.polarApi.getSteps(identifier: deviceId, fromDate: fromDate, toDate: toDate)
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

    private func parseStepsData(_ dataArray: [PolarStepsData]) -> [PolarStepsSample] {
        var samples: [PolarStepsSample] = []

        for data in dataArray {
            let sample = PolarStepsSample(
                date: data.date,
                steps: Int(data.steps)
            )
            samples.append(sample)
        }

        // Sort by date (most recent first)
        return samples.sorted { $0.date > $1.date }
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
