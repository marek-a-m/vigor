import Foundation
import BackgroundTasks
import UIKit

/// Main orchestrator for Polar background sync operations
final class PolarBackgroundSyncService {
    static let shared = PolarBackgroundSyncService()

    // Task identifiers
    static let morningSyncTaskId = "cloud.buggygames.vigor.polar.morning-sync"
    static let hourlySyncTaskId = "cloud.buggygames.vigor.polar.hourly-sync"

    private let stateManager = SyncStateManager.shared
    private let scheduler = BackgroundSyncScheduler.shared
    private let settingsManager = SettingsManager.shared

    private init() {}

    // MARK: - Task Registration

    /// Register background tasks - call from AppDelegate/App init
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.morningSyncTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleMorningSync(task: task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.hourlySyncTaskId,
            using: nil
        ) { [weak self] task in
            self?.handleHourlySync(task: task as! BGAppRefreshTask)
        }

        print("PolarBackgroundSync: Registered background tasks")
    }

    /// Schedule initial tasks - call after registration
    func scheduleInitialTasks() {
        guard settingsManager.polarIntegrationEnabled,
              settingsManager.polarBackgroundSyncEnabled else {
            print("PolarBackgroundSync: Background sync not enabled, skipping initial scheduling")
            return
        }

        scheduleMorningSyncTask()
        scheduleHourlySyncTask()
    }

    // MARK: - Task Scheduling

    func scheduleMorningSyncTask() {
        guard settingsManager.polarBackgroundSyncEnabled else { return }

        Task {
            let request = BGProcessingTaskRequest(identifier: Self.morningSyncTaskId)
            request.requiresNetworkConnectivity = false
            request.requiresExternalPower = false

            let targetTime = await scheduler.nextMorningSyncTime()
            request.earliestBeginDate = targetTime

            do {
                try BGTaskScheduler.shared.submit(request)
                print("PolarBackgroundSync: Scheduled morning sync for \(targetTime)")
            } catch {
                print("PolarBackgroundSync: Failed to schedule morning sync - \(error)")
            }
        }
    }

    func scheduleHourlySyncTask() {
        guard settingsManager.polarBackgroundSyncEnabled else { return }

        let request = BGAppRefreshTaskRequest(identifier: Self.hourlySyncTaskId)
        request.earliestBeginDate = scheduler.nextHourlySyncTime()

        do {
            try BGTaskScheduler.shared.submit(request)
            print("PolarBackgroundSync: Scheduled hourly sync for \(request.earliestBeginDate ?? Date())")
        } catch {
            print("PolarBackgroundSync: Failed to schedule hourly sync - \(error)")
        }
    }

    private func scheduleRetryTask(for failureType: SyncFailureType) {
        let request = BGAppRefreshTaskRequest(identifier: Self.hourlySyncTaskId)
        request.earliestBeginDate = scheduler.retryTime(for: failureType)

        do {
            try BGTaskScheduler.shared.submit(request)
            print("PolarBackgroundSync: Scheduled retry for \(request.earliestBeginDate ?? Date())")
        } catch {
            print("PolarBackgroundSync: Failed to schedule retry - \(error)")
        }
    }

    /// Cancel all scheduled background tasks
    func cancelAllTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.morningSyncTaskId)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.hourlySyncTaskId)
        print("PolarBackgroundSync: Cancelled all scheduled tasks")
    }

    // MARK: - Task Handlers

    private func handleMorningSync(task: BGProcessingTask) {
        print("PolarBackgroundSync: Morning sync task started")

        // Schedule next morning sync
        scheduleMorningSyncTask()

        // Check skip conditions
        if shouldSkipSync(isMorning: true) {
            print("PolarBackgroundSync: Skipping morning sync (conditions not met)")
            task.setTaskCompleted(success: true)
            return
        }

        // Create sync task
        let syncTask = Task {
            await performBackgroundSync()
        }

        // Handle expiration
        task.expirationHandler = {
            print("PolarBackgroundSync: Morning sync task expired")
            syncTask.cancel()
        }

        // Wait for completion
        Task {
            let result = await syncTask.value
            stateManager.recordMorningSync()
            task.setTaskCompleted(success: result)
        }
    }

    private func handleHourlySync(task: BGAppRefreshTask) {
        print("PolarBackgroundSync: Hourly sync task started")

        // Schedule next hourly sync
        scheduleHourlySyncTask()

        // Check skip conditions
        if shouldSkipSync(isMorning: false) {
            print("PolarBackgroundSync: Skipping hourly sync (conditions not met)")
            task.setTaskCompleted(success: true)
            return
        }

        // Create sync task
        let syncTask = Task {
            await performBackgroundSync()
        }

        // Handle expiration
        task.expirationHandler = {
            print("PolarBackgroundSync: Hourly sync task expired")
            syncTask.cancel()
        }

        // Wait for completion
        Task {
            let result = await syncTask.value
            task.setTaskCompleted(success: result)
        }
    }

    // MARK: - Skip Conditions

    private func shouldSkipSync(isMorning: Bool) -> Bool {
        // Check if Polar integration is enabled
        guard settingsManager.polarIntegrationEnabled else {
            print("PolarBackgroundSync: Skip - Polar integration disabled")
            return true
        }

        // Check if background sync is enabled
        guard settingsManager.polarBackgroundSyncEnabled else {
            print("PolarBackgroundSync: Skip - Background sync disabled")
            return true
        }

        // Check for low power mode
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            print("PolarBackgroundSync: Skip - Low power mode enabled")
            return true
        }

        // Check for too many failures
        if stateManager.hasTooManyFailures() {
            print("PolarBackgroundSync: Skip - Too many consecutive failures")
            return true
        }

        // Check recent sync
        if isMorning {
            if stateManager.shouldSkipMorningSync() {
                print("PolarBackgroundSync: Skip - Already synced morning or recently")
                return true
            }
        } else {
            if stateManager.shouldSkipHourlySync() {
                print("PolarBackgroundSync: Skip - Recently synced (< 45 min)")
                return true
            }
        }

        // Check active hours for hourly sync
        if !isMorning && !scheduler.isWithinActiveHours() {
            print("PolarBackgroundSync: Skip - Outside active hours")
            return true
        }

        return false
    }

    // MARK: - Background Sync Execution

    private func performBackgroundSync() async -> Bool {
        print("PolarBackgroundSync: Starting background sync...")

        // Perform sync using PolarSyncManager
        let result = await PolarSyncManager.shared.performBackgroundSync(
            connectionTimeout: 15,
            overallTimeout: 90
        )

        switch result {
        case .success:
            stateManager.recordSuccessfulSync()
            print("PolarBackgroundSync: Sync completed successfully")
            return true

        case .failure(let error):
            stateManager.recordFailure()

            // Determine failure type for retry scheduling
            let failureType: SyncFailureType
            switch error {
            case .connectionTimeout:
                failureType = .connectionTimeout
            case .deviceBusy:
                failureType = .deviceBusy
            default:
                failureType = .other
            }

            scheduleRetryTask(for: failureType)
            print("PolarBackgroundSync: Sync failed - \(error)")
            return false
        }
    }
}

// MARK: - Background Sync Error

enum BackgroundSyncError: Error {
    case connectionTimeout
    case deviceBusy
    case syncFailed(String)
    case notEnabled

    var localizedDescription: String {
        switch self {
        case .connectionTimeout:
            return "Connection timed out"
        case .deviceBusy:
            return "Device is busy"
        case .syncFailed(let reason):
            return "Sync failed: \(reason)"
        case .notEnabled:
            return "Background sync not enabled"
        }
    }
}
