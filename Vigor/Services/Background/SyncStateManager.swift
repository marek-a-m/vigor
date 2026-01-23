import Foundation

/// Manages persistent state for background sync operations
final class SyncStateManager {
    static let shared = SyncStateManager()

    private let defaults: UserDefaults

    private enum Keys {
        static let lastSuccessfulSyncTime = "polar.lastSuccessfulSyncTime"
        static let consecutiveFailureCount = "polar.consecutiveFailureCount"
        static let lastFailureTime = "polar.lastFailureTime"
        static let lastMorningSyncDate = "polar.lastMorningSyncDate"
    }

    private init() {
        if let groupDefaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
    }

    // MARK: - Last Successful Sync

    var lastSuccessfulSyncTime: Date? {
        get { defaults.object(forKey: Keys.lastSuccessfulSyncTime) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastSuccessfulSyncTime) }
    }

    var timeSinceLastSuccessfulSync: TimeInterval? {
        guard let lastSync = lastSuccessfulSyncTime else { return nil }
        return Date().timeIntervalSince(lastSync)
    }

    // MARK: - Failure Tracking

    var consecutiveFailureCount: Int {
        get { defaults.integer(forKey: Keys.consecutiveFailureCount) }
        set { defaults.set(newValue, forKey: Keys.consecutiveFailureCount) }
    }

    var lastFailureTime: Date? {
        get { defaults.object(forKey: Keys.lastFailureTime) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastFailureTime) }
    }

    // MARK: - Morning Sync Tracking

    /// Calendar date (yyyy-MM-dd) of last morning sync to avoid duplicates
    var lastMorningSyncDate: String? {
        get { defaults.string(forKey: Keys.lastMorningSyncDate) }
        set { defaults.set(newValue, forKey: Keys.lastMorningSyncDate) }
    }

    var hasSyncedMorningToday: Bool {
        guard let lastDate = lastMorningSyncDate else { return false }
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        return lastDate == today
    }

    // MARK: - State Updates

    func recordSuccessfulSync() {
        lastSuccessfulSyncTime = Date()
        consecutiveFailureCount = 0
        lastFailureTime = nil
        print("SyncStateManager: Recorded successful sync at \(Date())")
    }

    func recordFailure() {
        consecutiveFailureCount += 1
        lastFailureTime = Date()
        print("SyncStateManager: Recorded failure #\(consecutiveFailureCount)")
    }

    func recordMorningSync() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .none
        lastMorningSyncDate = dateFormatter.string(from: Date())
        print("SyncStateManager: Recorded morning sync for \(lastMorningSyncDate ?? "unknown")")
    }

    /// Reset failure count after cooldown period (2 hours)
    func resetFailuresIfCooledDown() {
        guard let lastFailure = lastFailureTime else { return }
        let cooldownPeriod: TimeInterval = 2 * 60 * 60 // 2 hours
        if Date().timeIntervalSince(lastFailure) > cooldownPeriod {
            consecutiveFailureCount = 0
            lastFailureTime = nil
            print("SyncStateManager: Reset failure count after cooldown")
        }
    }

    // MARK: - Skip Conditions

    /// Check if we should skip hourly sync (synced < 45 min ago)
    func shouldSkipHourlySync() -> Bool {
        guard let timeSince = timeSinceLastSuccessfulSync else { return false }
        let minimumInterval: TimeInterval = 45 * 60 // 45 minutes
        return timeSince < minimumInterval
    }

    /// Check if we should skip morning sync (synced < 6 hours ago)
    func shouldSkipMorningSync() -> Bool {
        // Already synced morning today
        if hasSyncedMorningToday { return true }

        // Recently synced
        guard let timeSince = timeSinceLastSuccessfulSync else { return false }
        let minimumInterval: TimeInterval = 6 * 60 * 60 // 6 hours
        return timeSince < minimumInterval
    }

    /// Check if too many failures (3+ consecutive, not cooled down)
    func hasTooManyFailures() -> Bool {
        resetFailuresIfCooledDown()
        return consecutiveFailureCount >= 3
    }
}
