import Foundation

struct VigorCalculator {

    func calculate(from metrics: HealthMetrics, date: Date = Date()) -> VigorScore {
        var scores: [(MetricType, Double)] = []
        var totalWeight: Double = 0

        if let sleepScore = calculateSleepScore(hours: metrics.sleepHours, stages: metrics.sleepStages) {
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

    private func calculateSleepScore(hours: Double?, stages: SleepStages?) -> Double? {
        guard let hours = hours else { return nil }

        // Duration score (60% of sleep score)
        let durationScore = calculateDurationScore(hours: hours)

        // Quality score (40% of sleep score) - if stages available
        let qualityScore: Double
        if let stages = stages, stages.totalAsleepHours > 0 {
            qualityScore = calculateQualityScore(stages: stages)
        } else {
            // No stage data - use duration score only
            return durationScore
        }

        // Combine: 60% duration + 40% quality
        return (durationScore * 0.6) + (qualityScore * 0.4)
    }

    private func calculateDurationScore(hours: Double) -> Double {
        let optimalMin = 7.0
        let optimalMax = 9.0

        if hours >= optimalMin && hours <= optimalMax {
            return 1.0
        } else if hours < optimalMin {
            let deficit = optimalMin - hours
            // Steeper penalty for severe sleep deprivation
            if hours < 5 {
                return max(0, 0.4 - (5 - hours) * 0.15)
            }
            return max(0, 1.0 - (deficit * 0.2))
        } else {
            let excess = hours - optimalMax
            return max(0.7, 1.0 - (excess * 0.05))
        }
    }

    private func calculateQualityScore(stages: SleepStages) -> Double {
        var score = 0.0

        // Deep sleep score (target: 15-25% of total sleep)
        // Deep sleep is crucial for physical recovery
        let deepPct = stages.deepPercentage
        if deepPct >= 15 && deepPct <= 25 {
            score += 0.4  // Full points
        } else if deepPct >= 10 && deepPct < 15 {
            score += 0.3  // Slightly low
        } else if deepPct > 25 && deepPct <= 30 {
            score += 0.35 // Slightly high (still good)
        } else if deepPct >= 5 {
            score += 0.2  // Low deep sleep
        } else {
            score += 0.1  // Very low deep sleep
        }

        // REM score (target: 20-25% of total sleep)
        // REM is crucial for mental recovery and memory
        let remPct = stages.remPercentage
        if remPct >= 20 && remPct <= 25 {
            score += 0.4  // Full points
        } else if remPct >= 15 && remPct < 20 {
            score += 0.3  // Slightly low
        } else if remPct > 25 && remPct <= 30 {
            score += 0.35 // Slightly high (still good)
        } else if remPct >= 10 {
            score += 0.2  // Low REM
        } else {
            score += 0.1  // Very low REM
        }

        // Sleep efficiency bonus (target: > 85%)
        let efficiency = stages.efficiency
        if efficiency >= 90 {
            score += 0.2  // Excellent efficiency
        } else if efficiency >= 85 {
            score += 0.15 // Good efficiency
        } else if efficiency >= 75 {
            score += 0.1  // Okay efficiency
        }
        // No bonus for poor efficiency

        return min(1.0, score)
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
