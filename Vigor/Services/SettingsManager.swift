import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults: UserDefaults
    private let iCloud = NSUbiquitousKeyValueStore.default

    private enum Keys {
        static let polarIntegrationEnabled = "polarIntegrationEnabled"
        static let polarDeviceId = "polarPairedDeviceId"
        static let polarDeviceName = "polarPairedDeviceName"
        static let polarBackgroundSyncEnabled = "polarBackgroundSyncEnabled"
        static let favoriteWorkoutIds = "favoriteWorkoutIds"
    }

    @Published var polarIntegrationEnabled: Bool {
        didSet {
            saveValue(polarIntegrationEnabled, forKey: Keys.polarIntegrationEnabled)
        }
    }

    @Published var polarDeviceId: String? {
        didSet {
            saveValue(polarDeviceId, forKey: Keys.polarDeviceId)
        }
    }

    @Published var polarDeviceName: String? {
        didSet {
            saveValue(polarDeviceName, forKey: Keys.polarDeviceName)
        }
    }

    @Published var polarBackgroundSyncEnabled: Bool {
        didSet {
            saveValue(polarBackgroundSyncEnabled, forKey: Keys.polarBackgroundSyncEnabled)
            // Update background task scheduling when setting changes
            if polarBackgroundSyncEnabled && polarIntegrationEnabled {
                PolarBackgroundSyncService.shared.scheduleInitialTasks()
            } else {
                PolarBackgroundSyncService.shared.cancelAllTasks()
            }
        }
    }

    @Published var favoriteWorkoutIds: [String] {
        didSet {
            saveValue(favoriteWorkoutIds, forKey: Keys.favoriteWorkoutIds)
        }
    }

    var favoriteWorkouts: [WorkoutType] {
        favoriteWorkoutIds.compactMap { id in
            WorkoutType.all.first { $0.id == id }
        }
    }

    private init() {
        // Use App Group for sharing settings with extensions
        if let groupDefaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }

        // Load settings: prefer iCloud, fall back to local
        self.polarIntegrationEnabled = loadBool(forKey: Keys.polarIntegrationEnabled)
        self.polarDeviceId = loadString(forKey: Keys.polarDeviceId)
        self.polarDeviceName = loadString(forKey: Keys.polarDeviceName)
        self.polarBackgroundSyncEnabled = loadBool(forKey: Keys.polarBackgroundSyncEnabled)

        // Load favorite workouts or use defaults
        if let savedFavorites = loadStringArray(forKey: Keys.favoriteWorkoutIds) {
            self.favoriteWorkoutIds = savedFavorites
        } else {
            self.favoriteWorkoutIds = WorkoutType.defaultFavoriteIds
        }

        // Listen for iCloud changes from other devices
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloud
        )

        // Sync iCloud store
        iCloud.synchronize()
    }

    // MARK: - iCloud Sync

    @objc private func iCloudDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let changeReason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        // Only update from server changes or initial sync
        if changeReason == NSUbiquitousKeyValueStoreServerChange ||
           changeReason == NSUbiquitousKeyValueStoreInitialSyncChange {

            if let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
                DispatchQueue.main.async { [weak self] in
                    self?.handleCloudChanges(for: changedKeys)
                }
            }
        }
    }

    private func handleCloudChanges(for keys: [String]) {
        for key in keys {
            switch key {
            case Keys.polarIntegrationEnabled:
                let value = iCloud.bool(forKey: key)
                if value != polarIntegrationEnabled {
                    polarIntegrationEnabled = value
                }
            case Keys.polarDeviceId:
                let value = iCloud.string(forKey: key)
                if value != polarDeviceId {
                    polarDeviceId = value
                }
            case Keys.polarDeviceName:
                let value = iCloud.string(forKey: key)
                if value != polarDeviceName {
                    polarDeviceName = value
                }
            case Keys.polarBackgroundSyncEnabled:
                let value = iCloud.bool(forKey: key)
                if value != polarBackgroundSyncEnabled {
                    polarBackgroundSyncEnabled = value
                }
            case Keys.favoriteWorkoutIds:
                if let value = iCloud.array(forKey: key) as? [String], value != favoriteWorkoutIds {
                    favoriteWorkoutIds = value
                }
            default:
                break
            }
        }
    }

    // MARK: - Storage Helpers

    private func saveValue(_ value: Any?, forKey key: String) {
        // Save to both local and iCloud
        defaults.set(value, forKey: key)
        defaults.synchronize()

        iCloud.set(value, forKey: key)
        iCloud.synchronize()
    }

    private func loadBool(forKey key: String) -> Bool {
        // Check iCloud first (source of truth), then local
        if iCloud.object(forKey: key) != nil {
            let value = iCloud.bool(forKey: key)
            // Sync to local
            defaults.set(value, forKey: key)
            return value
        }
        return defaults.bool(forKey: key)
    }

    private func loadString(forKey key: String) -> String? {
        // Check iCloud first, then local
        if let value = iCloud.string(forKey: key) {
            // Sync to local
            defaults.set(value, forKey: key)
            return value
        }
        return defaults.string(forKey: key)
    }

    private func loadStringArray(forKey key: String) -> [String]? {
        // Check iCloud first, then local
        if let value = iCloud.array(forKey: key) as? [String] {
            // Sync to local
            defaults.set(value, forKey: key)
            return value
        }
        return defaults.stringArray(forKey: key)
    }

    // MARK: - Actions

    func clearPolarDevice() {
        polarDeviceId = nil
        polarDeviceName = nil
        polarIntegrationEnabled = false
        polarBackgroundSyncEnabled = false
    }

    /// Force sync settings to iCloud
    func syncToCloud() {
        saveValue(polarIntegrationEnabled, forKey: Keys.polarIntegrationEnabled)
        saveValue(polarDeviceId, forKey: Keys.polarDeviceId)
        saveValue(polarDeviceName, forKey: Keys.polarDeviceName)
        saveValue(polarBackgroundSyncEnabled, forKey: Keys.polarBackgroundSyncEnabled)
        saveValue(favoriteWorkoutIds, forKey: Keys.favoriteWorkoutIds)
        iCloud.synchronize()
    }
}
