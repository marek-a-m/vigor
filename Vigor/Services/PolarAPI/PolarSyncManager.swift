import Foundation
import PolarBleSdk
import RxSwift

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

    var summary: String {
        var parts: [String] = []
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

            // Calculate metrics
            syncStatus = .calculatingMetrics
            let hrv = hrvCalculator.calculateNocturnalHRV(from: fetchedData.ppIntervals)
            let rhr = hrvCalculator.calculateRestingHeartRate(from: fetchedData.heartRateSamples)
            let temperature = hrvCalculator.calculateNocturnalTemperature(from: fetchedData.temperatureSamples)

            // End sync session before writing to HealthKit
            await endSyncSession(deviceId: deviceId)

            // Ensure HealthKit authorization
            syncStatus = .writingToHealthKit
            try await healthKitWriter.requestAuthorization()

            // Write to HealthKit
            let measurementDate = Date()
            let writeResult = await healthKitWriter.writeMetrics(
                hrv: hrv,
                rhr: rhr,
                temperature: temperature,
                measurementDate: measurementDate
            )

            // Create sync result
            let result = PolarSyncResult(
                hrvValue: hrv?.sdnn,
                rhrValue: rhr?.restingHeartRate,
                temperatureValue: temperature,
                syncDate: Date(),
                recordingsProcessed: fetchedData.ppIntervals.count + fetchedData.heartRateSamples.count + fetchedData.temperatureSamples.count
            )

            lastSyncResult = result
            lastSyncDate = Date()
            syncStatus = .completed(result)

            // Log results
            print("PolarSyncManager: Sync completed")
            print("  - HRV: \(hrv?.sdnn ?? 0) ms (valid: \(hrv?.isReliable ?? false))")
            print("  - RHR: \(rhr?.restingHeartRate ?? 0) bpm")
            print("  - Temperature: \(temperature ?? 0)°C")
            print("  - HealthKit write success: \(writeResult.success)")

            if !writeResult.errors.isEmpty {
                print("  - Write errors: \(writeResult.errors.joined(separator: ", "))")
            }

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
}
