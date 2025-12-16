import Foundation
import WidgetKit

struct SharedVigorData: Codable {
    let score: Double
    let date: Date
    let sleepScore: Double?
    let hrvScore: Double?
    let rhrScore: Double?
    let temperatureScore: Double?
    let missingMetrics: [String]

    var scoreCategory: String {
        switch score {
        case 67...100: return "High"
        case 34..<67: return "Moderate"
        default: return "Low"
        }
    }

    var hasMissingData: Bool {
        !missingMetrics.isEmpty
    }
}

final class SharedDataManager {
    static let shared = SharedDataManager()
    private let appGroupID = "group.cloud.buggygames.vigor"
    private let dataKey = "latestVigorScore"

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    private init() {}

    func saveLatestScore(_ data: SharedVigorData) {
        if let encoded = try? JSONEncoder().encode(data) {
            sharedDefaults?.set(encoded, forKey: dataKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func loadLatestScore() -> SharedVigorData? {
        guard let data = sharedDefaults?.data(forKey: dataKey),
              let decoded = try? JSONDecoder().decode(SharedVigorData.self, from: data) else {
            return nil
        }
        return decoded
    }
}
