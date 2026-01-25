import Foundation

struct VigorCalculator {

    func calculate(from metrics: HealthMetrics, date: Date = Date()) -> VigorScore {
        var scores: [(MetricType, Double)] = []
        var totalWeight: Double = 0

        if let sleepScore = calculateSleepScore(hours: metrics.sleepHours) {
            scores.append((.sleep, sleepScore))
            totalWeight += MetricType.sleep.weight
        }

        if let hrvScore = calculateHRVScore(current: metrics.hrv, baseline: metrics.hrvBaseline) {
            scores.append((.hrv, hrvScore))
            totalWeight += MetricType.hrv.weight
        }

        if let rhrScore = calculateRHRScore(current: metrics.restingHeartRate, baseline: metrics.rhrBaseline) {
            scores.append((.rhr, rhrScore))
            totalWeight += MetricType.rhr.weight
        }

        if let tempScore = calculateTemperatureScore(deviation: metrics.wristTemperatureDeviation) {
            scores.append((.temperature, tempScore))
            totalWeight += MetricType.temperature.weight
        }

        let weightedSum = scores.reduce(0.0) { sum, item in
            let (metricType, score) = item
            return sum + (score * metricType.weight)
        }

        let finalScore: Double
        if totalWeight > 0 {
            finalScore = (weightedSum / totalWeight) * 100
        } else {
            finalScore = 0
        }

        let missingMetrics = metrics.missingMetrics.map { $0.rawValue }

        let sleepScoreValue = scores.first { $0.0 == .sleep }.map { $0.1 * 100 }
        let hrvScoreValue = scores.first { $0.0 == .hrv }.map { $0.1 * 100 }
        let rhrScoreValue = scores.first { $0.0 == .rhr }.map { $0.1 * 100 }
        let tempScoreValue = scores.first { $0.0 == .temperature }.map { $0.1 * 100 }

        return VigorScore(
            date: date,
            score: min(100, max(0, finalScore)),
            sleepScore: sleepScoreValue,
            hrvScore: hrvScoreValue,
            rhrScore: rhrScoreValue,
            temperatureScore: tempScoreValue,
            sleepHours: metrics.sleepHours,
            hrvValue: metrics.hrv,
            rhrValue: metrics.restingHeartRate,
            temperatureDeviation: metrics.wristTemperatureDeviation,
            hrvBaseline: metrics.hrvBaseline,
            rhrBaseline: metrics.rhrBaseline,
            missingMetrics: missingMetrics
        )
    }

    private func calculateSleepScore(hours: Double?) -> Double? {
        guard let hours = hours else { return nil }

        let optimalMin = 7.0
        let optimalMax = 9.0

        if hours >= optimalMin && hours <= optimalMax {
            return 1.0
        } else if hours < optimalMin {
            let deficit = optimalMin - hours
            return max(0, 1.0 - (deficit * 0.15))
        } else {
            let excess = hours - optimalMax
            return max(0.7, 1.0 - (excess * 0.05))
        }
    }

    private func calculateHRVScore(current: Double?, baseline: Double?) -> Double? {
        guard let current = current, let baseline = baseline, baseline > 0 else {
            return nil
        }

        let ratio = current / baseline

        if ratio >= 1.0 {
            let bonus = min(0.3, (ratio - 1.0) * 0.5)
            return min(1.0, 0.7 + bonus)
        } else {
            let percentBelow = 1.0 - ratio
            return max(0, 0.7 - (percentBelow * 1.5))
        }
    }

    private func calculateRHRScore(current: Double?, baseline: Double?) -> Double? {
        guard let current = current, let baseline = baseline, baseline > 0 else {
            return nil
        }

        let deviation = current - baseline

        if deviation <= 0 {
            let bonus = min(0.2, abs(deviation) * 0.02)
            return min(1.0, 0.8 + bonus)
        } else {
            let penalty = deviation * 0.08
            return max(0, 0.8 - penalty)
        }
    }

    private func calculateTemperatureScore(deviation: Double?) -> Double? {
        guard let deviation = deviation else { return nil }

        let absDeviation = abs(deviation)

        // Wrist temperature deviations are typically small (-1 to +1°C)
        // More lenient thresholds for better scoring
        if absDeviation <= 0.5 {
            return 1.0  // 100 → green
        } else if absDeviation <= 1.0 {
            return 0.85 // 85 → green
        } else if absDeviation <= 1.5 {
            return 0.7  // 70 → green
        } else if absDeviation <= 2.0 {
            return 0.5  // 50 → yellow
        } else {
            return max(0.3, 0.5 - (absDeviation - 2.0) * 0.1)
        }
    }
}
