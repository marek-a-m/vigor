import Foundation
import SwiftData

@Model
final class VigorScore {
    // CloudKit requires default values for non-optional properties
    var date: Date = Date()
    var score: Double = 0
    var sleepScore: Double?
    var hrvScore: Double?
    var rhrScore: Double?
    var temperatureScore: Double?

    var sleepHours: Double?
    var hrvValue: Double?
    var rhrValue: Double?
    var temperatureDeviation: Double?

    var hrvBaseline: Double?
    var rhrBaseline: Double?

    var missingMetrics: [String] = []

    init(
        date: Date = Date(),
        score: Double,
        sleepScore: Double? = nil,
        hrvScore: Double? = nil,
        rhrScore: Double? = nil,
        temperatureScore: Double? = nil,
        sleepHours: Double? = nil,
        hrvValue: Double? = nil,
        rhrValue: Double? = nil,
        temperatureDeviation: Double? = nil,
        hrvBaseline: Double? = nil,
        rhrBaseline: Double? = nil,
        missingMetrics: [String] = []
    ) {
        self.date = date
        self.score = score
        self.sleepScore = sleepScore
        self.hrvScore = hrvScore
        self.rhrScore = rhrScore
        self.temperatureScore = temperatureScore
        self.sleepHours = sleepHours
        self.hrvValue = hrvValue
        self.rhrValue = rhrValue
        self.temperatureDeviation = temperatureDeviation
        self.hrvBaseline = hrvBaseline
        self.rhrBaseline = rhrBaseline
        self.missingMetrics = missingMetrics
    }

    var scoreCategory: ScoreCategory {
        switch score {
        case 67...100: return .high
        case 34..<67: return .moderate
        default: return .low
        }
    }

    var hasMissingData: Bool {
        !missingMetrics.isEmpty
    }
}

enum ScoreCategory: String {
    case high = "High"
    case moderate = "Moderate"
    case low = "Low"

    var color: String {
        switch self {
        case .high: return "green"
        case .moderate: return "yellow"
        case .low: return "red"
        }
    }

    var description: String {
        switch self {
        case .high: return "Ready for high intensity"
        case .moderate: return "Moderate activity recommended"
        case .low: return "Focus on recovery"
        }
    }
}
