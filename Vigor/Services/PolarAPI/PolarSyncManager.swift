import Foundation
import PolarBleSdk
import RxSwift

// MARK: - Notifications

extension Notification.Name {
    static let polarSyncCompleted = Notification.Name("PolarSyncCompleted")
}

// MARK: - Sync Status

enum PolarSyncStatus: Equatable {
    case idle
    case connecting
    case initializingSync
    case fetchingData
    case calculatingMetrics
    case writingToHealthKit
    case completed(PolarSyncResult)
    case failed(String)

    var isInProgress: Bool {
        switch self {
        case .idle, .completed, .failed:
            return false
        default:
            return true
        }
    }

    var description: String {
        switch self {
        case .idle:
            return "Ready to sync"
        case .connecting:
            return "Connecting to device..."
        case .initializingSync:
            return "Preparing device for sync..."
        case .fetchingData:
            return "Fetching data from device..."
        case .calculatingMetrics:
            return "Calculating metrics..."
        case .writingToHealthKit:
            return "Writing to Apple Health..."
        case .completed(let result):
            return "Sync completed: \(result.summary)"
        case .failed(let error):
            return "Sync failed: \(error)"
        }
    }
}

// MARK: - Sync Result

struct PolarSyncResult: Equatable {
    let hrvValue: Double?
    let rhrValue: Double?
    let temperatureValue: Double?
    let syncDate: Date
    let recordingsProcessed: Int
    let sleepDurationMinutes: Int?

    var summary: String {
        var parts: [String] = []
        if let sleep = sleepDurationMinutes {
            let hours = sleep / 60
            let mins = sleep % 60
            parts.append("Sleep: \(hours)h\(mins)m")
        }
        if let hrv = hrvValue { parts.append("HRV: \(Int(hrv))ms") }
        if let rhr = rhrValue { parts.append("RHR: \(Int(rhr))bpm") }
        if let temp = temperatureValue { parts.append("Temp: \(String(format: "%.1f", temp))°C") }
        return parts.isEmpty ? "No data" : parts.joined(separator: ", ")
    }
}

// MARK: - Polar Sync Manager

@MainActor
final class PolarSyncManager: ObservableObject {
    static let shared = PolarSyncManager()

    private let bleService = PolarBLEService.shared
    private let dataFetcher = PolarDataFetcher.shared
    private let hrvCalculator = PolarHRVCalculator.shared
    private let healthKitWriter = PolarHealthKitWriter.shared
    private let settingsManager = SettingsManager.shared
    private let disposeBag = DisposeBag()

    @Published var syncStatus: PolarSyncStatus = .idle
    @Published var lastSyncResult: PolarSyncResult?
    @Published var lastSyncDate: Date?

    private init() {}

    // MARK: - Sync Initialization

    /// Start sync session - flushes cached 24/7 data to files for retrieval
    private func startSyncSession(deviceId: String) async throws {
        print("PolarSyncManager: Starting sync session for device \(deviceId)...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bleService.polarApi.sendInitializationAndStartSyncNotifications(identifier: deviceId)
                .subscribe(
                    onCompleted: {
                        print("PolarSyncManager: Sync session started successfully")
                        continuation.resume()
                    },
                    onError: { error in
                        print("PolarSyncManager: Failed to start sync session - \(error)")
                        continuation.resume(throwing: error)
                    }
                )
                .disposed(by: disposeBag)
        }

        // Wait for device to flush 24/7 data to files after sync initialization
        // The SDK docs say data is flushed when sync starts, but device needs time to process
        print("PolarSyncManager: Waiting for device to flush data...")
        try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
    }

    /// End sync session
    private func endSyncSession(deviceId: String) async {
        print("PolarSyncManager: Ending sync session...")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bleService.polarApi.sendTerminateAndStopSyncNotifications(identifier: deviceId)
                .subscribe(
                    onCompleted: {
                        print("PolarSyncManager: Sync session ended successfully")
                        continuation.resume()
                    },
                    onError: { error in
                        print("PolarSyncManager: Failed to end sync session - \(error)")
                        continuation.resume()
                    }
                )
                .disposed(by: disposeBag)
        }
    }

    // MARK: - Full Sync Flow

    func performSync() async {
        guard settingsManager.polarIntegrationEnabled else {
            syncStatus = .failed("Polar integration not enabled")
            return
        }

        // Connect if not already connected
        if !bleService.connectionState.isConnected {
            syncStatus = .connecting
            bleService.autoReconnect()

            // Wait for connection (with timeout)
            for _ in 0..<30 {
                if bleService.connectionState.isConnected {
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }

        guard case .connected(let deviceId) = bleService.connectionState else {
            syncStatus = .failed("Could not connect to device")
            return
        }

        do {
            // Initialize sync session - this flushes cached 24/7 data to files
            syncStatus = .initializingSync
            try await startSyncSession(deviceId: deviceId)

            // Fetch offline data
            syncStatus = .fetchingData
            let fetchedData = try await dataFetcher.fetchOfflineData()

            // Calculate metrics - prefer pre-computed nightly recharge data
            syncStatus = .calculatingMetrics
            let sleepData = fetchedData.sleepData
            let nightlyRecharge = fetchedData.nightlyRecharge
            print("PolarSyncManager: Using \(sleepData.count) sleep record(s), \(nightlyRecharge.count) nightly recharge record(s)")

            // Use nightly recharge for HRV/RHR if available (pre-computed by device)
            var hrv: PolarHRVResult? = nil
            var rhr: PolarRHRResult? = nil

            if let latestNightly = nightlyRecharge.first {
                print("PolarSyncManager: Using pre-computed nightly recharge data")
                print("  - Device HRV (RMSSD): \(latestNightly.hrvRMSSD) ms")
                print("  - Device RHR: \(String(format: "%.1f", latestNightly.restingHeartRate)) bpm")

                // Create HRV result from nightly recharge (RMSSD -> estimate SDNN)
                // SDNN is typically 1.5-2x RMSSD for nocturnal measurements
                let estimatedSDNN = latestNightly.hrvRMSSD * 1.5
                hrv = PolarHRVResult(
                    sdnn: estimatedSDNN,
                    rmssd: latestNightly.hrvRMSSD,
                    meanRR: latestNightly.meanRRI,
                    validIntervalCount: 1000,  // Mark as valid
                    totalIntervalCount: 1000,
                    calculationDate: Date()
                )

                // Create RHR result from nightly recharge
                rhr = PolarRHRResult(
                    restingHeartRate: latestNightly.restingHeartRate,
                    sampleCount: 1000,  // Mark as valid
                    measurementPeriod: DateInterval(start: Date().addingTimeInterval(-8*3600), end: Date())
                )
            } else {
                // Fallback to calculating from raw data
                print("PolarSyncManager: No nightly recharge data, calculating from raw samples")
                hrv = hrvCalculator.calculateSleepHRV(from: fetchedData.ppIntervals, sleepData: sleepData)
                rhr = hrvCalculator.calculateSleepRestingHeartRate(from: fetchedData.heartRateSamples, sleepData: sleepData)
            }

            let temperatureResult = hrvCalculator.calculateSleepTemperature(from: fetchedData.temperatureSamples, sleepData: sleepData)

            // End sync session before writing to HealthKit
            await endSyncSession(deviceId: deviceId)

            // Ensure HealthKit authorization
            syncStatus = .writingToHealthKit
            try await healthKitWriter.requestAuthorization()

            // Write to HealthKit
            let measurementDate = Date()

            // Use estimated body temperature (skin temp + offset) for HealthKit
            let bodyTemperature: Double? = temperatureResult?.isValid == true ? temperatureResult?.estimatedBodyTemperature : nil

            let writeResult = await healthKitWriter.writeMetrics(
                hrv: hrv,
                rhr: rhr,
                temperature: bodyTemperature,
                measurementDate: measurementDate
            )

            // Create sync result
            let result = PolarSyncResult(
                hrvValue: hrv?.sdnn,
                rhrValue: rhr?.restingHeartRate,
                temperatureValue: bodyTemperature,
                syncDate: Date(),
                recordingsProcessed: fetchedData.ppIntervals.count + fetchedData.heartRateSamples.count + fetchedData.temperatureSamples.count,
                sleepDurationMinutes: sleepData.first?.sleepDurationMinutes
            )

            lastSyncResult = result
            lastSyncDate = Date()
            syncStatus = .completed(result)

            // Log results
            print("PolarSyncManager: Sync completed")
            print("  - Sleep: \(sleepData.first?.sleepDurationMinutes ?? 0) minutes")
            print("  - HRV: \(hrv?.sdnn ?? 0) ms (valid: \(hrv?.isReliable ?? false))")
            print("  - RHR: \(rhr?.restingHeartRate ?? 0) bpm")
            if let tempResult = temperatureResult {
                print("  - Skin temp: \(String(format: "%.1f", tempResult.skinTemperature))°C -> Body temp: \(String(format: "%.1f", tempResult.estimatedBodyTemperature))°C (valid: \(tempResult.isValid))")
            }
            print("  - HealthKit write success: \(writeResult.success)")

            if !writeResult.errors.isEmpty {
                print("  - Write errors: \(writeResult.errors.joined(separator: ", "))")
            }

            // Notify app to refresh Vigor score with new data
            NotificationCenter.default.post(name: .polarSyncCompleted, object: nil)

        } catch {
            // Try to end sync session even on error
            if case .connected(let deviceId) = bleService.connectionState {
                await endSyncSession(deviceId: deviceId)
            }
            syncStatus = .failed(error.localizedDescription)
            print("PolarSyncManager: Sync failed - \(error)")
        }
    }

    // MARK: - Quick Sync (if already connected)

    func quickSync() async {
        guard bleService.connectionState.isConnected else {
            syncStatus = .failed("Device not connected")
            return
        }

        await performSync()
    }

    // MARK: - Reset

    func reset() {
        syncStatus = .idle
    }

    // MARK: - Background Sync

    /// Perform sync optimized for background execution
    /// - Parameters:
    ///   - connectionTimeout: Maximum seconds to wait for device connection
    ///   - overallTimeout: Maximum seconds for entire sync operation
    /// - Returns: Result indicating success or specific failure type
    func performBackgroundSync(
        connectionTimeout: TimeInterval = 15,
        overallTimeout: TimeInterval = 90
    ) async -> Result<Void, BackgroundSyncError> {
        guard settingsManager.polarIntegrationEnabled else {
            return .failure(.notEnabled)
        }

        guard let deviceId = settingsManager.polarDeviceId else {
            return .failure(.syncFailed("No paired device"))
        }

        // Overall timeout task
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
            return true
        }

        // Sync task
        let syncTask = Task { () -> Result<Void, BackgroundSyncError> in
            // Connect if not already connected
            if !bleService.connectionState.isConnected {
                let connectionResult = await bleService.backgroundReconnect(
                    deviceId: deviceId,
                    timeout: connectionTimeout
                )

                guard connectionResult else {
                    return .failure(.connectionTimeout)
                }
            }

            // Verify connection
            guard case .connected(let connectedDeviceId) = bleService.connectionState else {
                return .failure(.connectionTimeout)
            }

            do {
                // Start sync session
                try await startSyncSession(deviceId: connectedDeviceId)

                // Fetch offline data
                let fetchedData = try await dataFetcher.fetchOfflineData()

                // Calculate metrics - prefer pre-computed nightly recharge data
                let sleepData = fetchedData.sleepData
                let nightlyRecharge = fetchedData.nightlyRecharge
                print("PolarSyncManager: Background sync using \(sleepData.count) sleep record(s), \(nightlyRecharge.count) nightly recharge record(s)")

                // Use nightly recharge for HRV/RHR if available
                var hrv: PolarHRVResult? = nil
                var rhr: PolarRHRResult? = nil

                if let latestNightly = nightlyRecharge.first {
                    print("PolarSyncManager: Using pre-computed nightly recharge data")

                    // SDNN is typically 1.5-2x RMSSD for nocturnal measurements
                    let estimatedSDNN = latestNightly.hrvRMSSD * 1.5
                    hrv = PolarHRVResult(
                        sdnn: estimatedSDNN,
                        rmssd: latestNightly.hrvRMSSD,
                        meanRR: latestNightly.meanRRI,
                        validIntervalCount: 1000,
                        totalIntervalCount: 1000,
                        calculationDate: Date()
                    )

                    rhr = PolarRHRResult(
                        restingHeartRate: latestNightly.restingHeartRate,
                        sampleCount: 1000,
                        measurementPeriod: DateInterval(start: Date().addingTimeInterval(-8*3600), end: Date())
                    )
                } else {
                    print("PolarSyncManager: No nightly recharge, calculating from raw samples")
                    hrv = hrvCalculator.calculateSleepHRV(from: fetchedData.ppIntervals, sleepData: sleepData)
                    rhr = hrvCalculator.calculateSleepRestingHeartRate(from: fetchedData.heartRateSamples, sleepData: sleepData)
                }

                let temperatureResult = hrvCalculator.calculateSleepTemperature(from: fetchedData.temperatureSamples, sleepData: sleepData)

                // End sync session
                await endSyncSession(deviceId: connectedDeviceId)

                // Write to HealthKit
                try await healthKitWriter.requestAuthorization()
                let measurementDate = Date()

                // Use estimated body temperature for HealthKit
                let bodyTemperature: Double? = temperatureResult?.isValid == true ? temperatureResult?.estimatedBodyTemperature : nil

                let writeResult = await healthKitWriter.writeMetrics(
                    hrv: hrv,
                    rhr: rhr,
                    temperature: bodyTemperature,
                    measurementDate: measurementDate
                )

                // Update state on main actor
                await MainActor.run {
                    let result = PolarSyncResult(
                        hrvValue: hrv?.sdnn,
                        rhrValue: rhr?.restingHeartRate,
                        temperatureValue: bodyTemperature,
                        syncDate: Date(),
                        recordingsProcessed: fetchedData.ppIntervals.count + fetchedData.heartRateSamples.count + fetchedData.temperatureSamples.count,
                        sleepDurationMinutes: sleepData.first?.sleepDurationMinutes
                    )
                    lastSyncResult = result
                    lastSyncDate = Date()
                }

                print("PolarSyncManager: Background sync completed")
                print("  - Sleep: \(sleepData.first?.sleepDurationMinutes ?? 0) minutes")
                print("  - HRV: \(hrv?.sdnn ?? 0) ms (valid: \(hrv?.isReliable ?? false))")
                print("  - RHR: \(rhr?.restingHeartRate ?? 0) bpm")
                if let tempResult = temperatureResult {
                    print("  - Skin temp: \(String(format: "%.1f", tempResult.skinTemperature))°C -> Body temp: \(String(format: "%.1f", tempResult.estimatedBodyTemperature))°C")
                }
                print("  - HealthKit write success: \(writeResult.success)")

                // Notify app to refresh Vigor score with new data
                await MainActor.run {
                    NotificationCenter.default.post(name: .polarSyncCompleted, object: nil)
                }

                return .success(())

            } catch {
                // Try to end sync session on error
                if case .connected(let connectedDeviceId) = bleService.connectionState {
                    await endSyncSession(deviceId: connectedDeviceId)
                }

                // Check for device busy error
                let errorString = error.localizedDescription.lowercased()
                if errorString.contains("busy") || errorString.contains("in use") {
                    return .failure(.deviceBusy)
                }

                return .failure(.syncFailed(error.localizedDescription))
            }
        }

        // Race between timeout and sync
        let result = await withTaskGroup(of: Result<Void, BackgroundSyncError>?.self) { group in
            group.addTask {
                return await syncTask.value
            }

            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
                    syncTask.cancel()
                    return .failure(.connectionTimeout)
                } catch {
                    return nil // Task was cancelled
                }
            }

            // Return first non-nil result
            for await result in group {
                if let result = result {
                    group.cancelAll()
                    return result
                }
            }

            return .failure(.syncFailed("Unknown error"))
        }

        timeoutTask.cancel()
        return result
    }
}
