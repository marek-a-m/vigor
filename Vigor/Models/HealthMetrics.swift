import Foundation

struct SleepStages {
    var lightHours: Double = 0
    var deepHours: Double = 0
    var remHours: Double = 0
    var awakeHours: Double = 0

    var totalAsleepHours: Double {
        lightHours + deepHours + remHours
    }

    var totalInBedHours: Double {
        totalAsleepHours + awakeHours
    }

    /// Deep sleep percentage (healthy: 15-25%)
    var deepPercentage: Double {
        guard totalAsleepHours > 0 else { return 0 }
        return (deepHours / totalAsleepHours) * 100
    }

    /// REM percentage (healthy: 20-25%)
    var remPercentage: Double {
        guard totalAsleepHours > 0 else { return 0 }
        return (remHours / totalAsleepHours) * 100
    }

    /// Sleep efficiency (time asleep vs time in bed)
    var efficiency: Double {
        guard totalInBedHours > 0 else { return 0 }
        return (totalAsleepHours / totalInBedHours) * 100
    }
}

struct HealthMetrics {
    var sleepHours: Double?
    var sleepStages: SleepStages?
    var hrv: Double?
    var restingHeartRate: Double?
    var wristTemperatureDeviation: Double?

    var hrvBaseline: Double?
    var rhrBaseline: Double?
    var temperatureBaseline: Double?

    var availableMetrics: [MetricType] {
        var metrics: [MetricType] = []
        if sleepHours != nil { metrics.append(.sleep) }
        if hrv != nil && hrvBaseline != nil { metrics.append(.hrv) }
        if restingHeartRate != nil && rhrBaseline != nil { metrics.append(.rhr) }
        if wristTemperatureDeviation != nil { metrics.append(.temperature) }
        return metrics
    }

    var missingMetrics: [MetricType] {
        MetricType.allCases.filter { !availableMetrics.contains($0) }
    }
}

enum MetricType: String, CaseIterable {
    case sleep = "Sleep"
    case hrv = "HRV"
    case rhr = "Resting HR"
    case temperature = "Temperature"

    var icon: String {
        switch self {
        case .sleep: return "bed.double.fill"
        case .hrv: return "waveform.path.ecg"
        case .rhr: return "heart.fill"
        case .temperature: return "thermometer.medium"
        }
    }

    var weight: Double {
        switch self {
        case .sleep: return 0.30
        case .hrv: return 0.30
        case .rhr: return 0.25
        case .temperature: return 0.15
        }
    }
}
