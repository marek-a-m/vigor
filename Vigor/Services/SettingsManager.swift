import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults: UserDefaults

    private enum Keys {
        static let whoopIntegrationEnabled = "whoopIntegrationEnabled"
        static let polarIntegrationEnabled = "polarIntegrationEnabled"
        static let polarDeviceId = "polarPairedDeviceId"
        static let polarDeviceName = "polarPairedDeviceName"
    }

    @Published var whoopIntegrationEnabled: Bool {
        didSet {
            defaults.set(whoopIntegrationEnabled, forKey: Keys.whoopIntegrationEnabled)
        }
    }

    @Published var polarIntegrationEnabled: Bool {
        didSet {
            defaults.set(polarIntegrationEnabled, forKey: Keys.polarIntegrationEnabled)
        }
    }

    @Published var polarDeviceId: String? {
        didSet {
            defaults.set(polarDeviceId, forKey: Keys.polarDeviceId)
        }
    }

    @Published var polarDeviceName: String? {
        didSet {
            defaults.set(polarDeviceName, forKey: Keys.polarDeviceName)
        }
    }

    private init() {
        // Use App Group for sharing settings if needed
        if let groupDefaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }

        self.whoopIntegrationEnabled = defaults.bool(forKey: Keys.whoopIntegrationEnabled)
        self.polarIntegrationEnabled = defaults.bool(forKey: Keys.polarIntegrationEnabled)
        self.polarDeviceId = defaults.string(forKey: Keys.polarDeviceId)
        self.polarDeviceName = defaults.string(forKey: Keys.polarDeviceName)
    }

    func clearPolarDevice() {
        polarDeviceId = nil
        polarDeviceName = nil
        polarIntegrationEnabled = false
    }
}
