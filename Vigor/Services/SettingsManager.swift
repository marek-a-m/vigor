import Foundation

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults: UserDefaults

    private enum Keys {
        static let whoopIntegrationEnabled = "whoopIntegrationEnabled"
    }

    @Published var whoopIntegrationEnabled: Bool {
        didSet {
            defaults.set(whoopIntegrationEnabled, forKey: Keys.whoopIntegrationEnabled)
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
    }
}
