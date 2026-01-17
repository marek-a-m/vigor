import Foundation
import SwiftData

@Model
final class DailyMetrics {
    // CloudKit requires default values for non-optional properties
    /// Date normalized to start of day (midnight)
    var date: Date = Date()

    /// Total sleep hours for the night ending on this date
    var sleepHours: Double?

    /// Average HRV (SDNN in ms) for this day
    var hrvAverage: Double?

    /// Resting heart rate (bpm) for this day
    var restingHeartRate: Double?

    /// Wrist temperature deviation from baseline (Celsius)
    var wristTemperature: Double?

    /// When this record was last updated from HealthKit
    var lastUpdated: Date = Date()

    init(
        date: Date,
        sleepHours: Double? = nil,
        hrvAverage: Double? = nil,
        restingHeartRate: Double? = nil,
        wristTemperature: Double? = nil,
        lastUpdated: Date = Date()
    ) {
        // Normalize to start of day
        self.date = Calendar.current.startOfDay(for: date)
        self.sleepHours = sleepHours
        self.hrvAverage = hrvAverage
        self.restingHeartRate = restingHeartRate
        self.wristTemperature = wristTemperature
        self.lastUpdated = lastUpdated
    }

    /// Check if this day has any health data
    var hasData: Bool {
        sleepHours != nil || hrvAverage != nil || restingHeartRate != nil || wristTemperature != nil
    }

    /// Convert to HealthMetrics for score calculation
    func toHealthMetrics(hrvBaseline: Double?, rhrBaseline: Double?) -> HealthMetrics {
        HealthMetrics(
            sleepHours: sleepHours,
            hrv: hrvAverage,
            restingHeartRate: restingHeartRate,
            wristTemperatureDeviation: wristTemperature,
            hrvBaseline: hrvBaseline,
            rhrBaseline: rhrBaseline
        )
    }
}
