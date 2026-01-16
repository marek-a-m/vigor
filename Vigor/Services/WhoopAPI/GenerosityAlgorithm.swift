import Foundation

// MARK: - Apple-Style Metrics Output

/// Transformed metrics ready for writing to Apple HealthKit Activity Rings
struct AppleStyleMetrics {
    let date: Date

    /// Active energy burned (calories) for Move Ring
    let activeEnergyBurned: Double

    /// Exercise minutes for Exercise Ring
    let exerciseMinutes: Double

    /// Hours that count as "stood" for Stand Ring (0-24)
    let standHours: Set<Int>

    /// Breakdown for debugging/transparency
    let breakdown: MetricsBreakdown
}

/// Detailed breakdown of how metrics were calculated
struct MetricsBreakdown {
    // Move Ring
    let whoopRawCalories: Double
    let calorieMultiplier: Double
    let motionBonusCalories: Double
    let finalCalories: Double

    // Exercise Ring
    let whoopWorkoutMinutes: Double
    let lowIntensityMinutes: Double
    let moderateIntensityMinutes: Double
    let highIntensityMinutes: Double
    let finalExerciseMinutes: Double

    // Stand Ring
    let hoursWithHRSpike: Set<Int>
    let hoursWithActivity: Set<Int>
    let hoursWithInferredMovement: Set<Int>
    let finalStandHours: Set<Int>
}

// MARK: - Generosity Algorithm Configuration

/// Tunable parameters for the Generosity Algorithm
struct GenerosityConfig {
    // MARK: Move Ring (Calorie) Configuration

    /// Base multiplier applied to all WHOOP calories
    /// WHOOP is cardiovascular-focused; Apple includes motion-based calories
    let baseCalorieMultiplier: Double

    /// Additional multiplier when HR is elevated (> threshold above resting)
    let elevatedHRMultiplier: Double

    /// HR threshold above resting to apply elevated multiplier (percentage)
    let elevatedHRThreshold: Double

    /// Bonus calories per hour of waking time (simulates fidgeting/NEAT)
    let hourlyMotionBonusCalories: Double

    // MARK: Exercise Ring Configuration

    /// Minimum HR as percentage of max HR to count as exercise
    /// Apple uses ~55-60% for "brisk walk" equivalent
    let exerciseHRThreshold: Double

    /// Lower threshold for "light activity" that still counts partially
    let lightActivityHRThreshold: Double

    /// Multiplier for light activity minutes (< 1.0)
    let lightActivityMultiplier: Double

    /// Bonus minutes added per workout (Apple is more generous with workout detection)
    let workoutBonusMinutes: Double

    // MARK: Stand Ring Configuration

    /// HR spike above resting (in BPM) to infer standing/movement
    let standHRSpikeThreshold: Double

    /// Minimum duration (seconds) of elevated HR to count as "stood"
    let standMinDuration: TimeInterval

    /// If no HR data, assume standing during these hours (default waking hours)
    let defaultStandHours: Set<Int>

    // MARK: Presets

    /// Balanced preset - moderate generosity
    static let balanced = GenerosityConfig(
        baseCalorieMultiplier: 1.15,
        elevatedHRMultiplier: 1.3,
        elevatedHRThreshold: 0.10, // 10% above resting
        hourlyMotionBonusCalories: 8.0, // ~128 cal/day for 16 waking hours
        exerciseHRThreshold: 0.55, // 55% of max HR
        lightActivityHRThreshold: 0.45, // 45% of max HR
        lightActivityMultiplier: 0.5,
        workoutBonusMinutes: 5.0,
        standHRSpikeThreshold: 10.0, // 10 BPM above resting
        standMinDuration: 60.0, // 1 minute
        defaultStandHours: Set(8..<22) // 8 AM - 10 PM
    )

    /// Generous preset - closer to Apple Watch behavior
    static let generous = GenerosityConfig(
        baseCalorieMultiplier: 1.25,
        elevatedHRMultiplier: 1.5,
        elevatedHRThreshold: 0.08,
        hourlyMotionBonusCalories: 12.0,
        exerciseHRThreshold: 0.50,
        lightActivityHRThreshold: 0.40,
        lightActivityMultiplier: 0.7,
        workoutBonusMinutes: 8.0,
        standHRSpikeThreshold: 8.0,
        standMinDuration: 45.0,
        defaultStandHours: Set(7..<23)
    )

    /// Conservative preset - minimal inflation
    static let conservative = GenerosityConfig(
        baseCalorieMultiplier: 1.05,
        elevatedHRMultiplier: 1.15,
        elevatedHRThreshold: 0.15,
        hourlyMotionBonusCalories: 5.0,
        exerciseHRThreshold: 0.60,
        lightActivityHRThreshold: 0.50,
        lightActivityMultiplier: 0.3,
        workoutBonusMinutes: 2.0,
        standHRSpikeThreshold: 12.0,
        standMinDuration: 90.0,
        defaultStandHours: Set(9..<21)
    )
}

// MARK: - Generosity Algorithm

final class GenerosityAlgorithm {

    private let config: GenerosityConfig

    init(config: GenerosityConfig = .balanced) {
        self.config = config
    }

    // MARK: - Main Calculation

    /// Transform WHOOP data into Apple-style metrics using the Generosity Algorithm
    /// - Parameter whoopData: Raw WHOOP data for a single day
    /// - Returns: Transformed metrics suitable for Apple HealthKit Activity Rings
    func calculateAppleStyleMetrics(from whoopData: WhoopDailyPayload) -> AppleStyleMetrics {
        let moveMetrics = calculateMoveRingMetrics(from: whoopData)
        let exerciseMetrics = calculateExerciseRingMetrics(from: whoopData)
        let standMetrics = calculateStandRingMetrics(from: whoopData)

        let breakdown = MetricsBreakdown(
            whoopRawCalories: whoopData.totalActiveCalories,
            calorieMultiplier: moveMetrics.multiplier,
            motionBonusCalories: moveMetrics.motionBonus,
            finalCalories: moveMetrics.totalCalories,
            whoopWorkoutMinutes: exerciseMetrics.rawWorkoutMinutes,
            lowIntensityMinutes: exerciseMetrics.lowIntensityMinutes,
            moderateIntensityMinutes: exerciseMetrics.moderateIntensityMinutes,
            highIntensityMinutes: exerciseMetrics.highIntensityMinutes,
            finalExerciseMinutes: exerciseMetrics.totalMinutes,
            hoursWithHRSpike: standMetrics.hrSpikeHours,
            hoursWithActivity: standMetrics.activityHours,
            hoursWithInferredMovement: standMetrics.inferredHours,
            finalStandHours: standMetrics.totalStandHours
        )

        return AppleStyleMetrics(
            date: whoopData.date,
            activeEnergyBurned: moveMetrics.totalCalories,
            exerciseMinutes: exerciseMetrics.totalMinutes,
            standHours: standMetrics.totalStandHours,
            breakdown: breakdown
        )
    }

    // MARK: - Move Ring Calculation

    private struct MoveRingResult {
        let totalCalories: Double
        let multiplier: Double
        let motionBonus: Double
    }

    private func calculateMoveRingMetrics(from whoopData: WhoopDailyPayload) -> MoveRingResult {
        let rawCalories = whoopData.totalActiveCalories

        // Calculate dynamic multiplier based on HR patterns
        let multiplier = calculateCalorieMultiplier(
            hrSamples: whoopData.heartRateSamples,
            restingHR: whoopData.restingHeartRate
        )

        // Apply multiplier to WHOOP calories
        let adjustedCalories = rawCalories * multiplier

        // Add motion bonus (NEAT - non-exercise activity thermogenesis)
        // Apple Watch captures fidgeting, walking around house, etc.
        let wakingHours = calculateWakingHours(from: whoopData)
        let motionBonus = Double(wakingHours) * config.hourlyMotionBonusCalories

        let totalCalories = adjustedCalories + motionBonus

        return MoveRingResult(
            totalCalories: totalCalories,
            multiplier: multiplier,
            motionBonus: motionBonus
        )
    }

    /// Calculate calorie multiplier based on HR elevation throughout the day
    private func calculateCalorieMultiplier(
        hrSamples: [WhoopHeartRateSample],
        restingHR: Double
    ) -> Double {
        guard !hrSamples.isEmpty else {
            return config.baseCalorieMultiplier
        }

        let elevatedThreshold = restingHR * (1 + config.elevatedHRThreshold)

        // Calculate percentage of samples with elevated HR
        let elevatedCount = hrSamples.filter { Double($0.bpm) > elevatedThreshold }.count
        let elevatedRatio = Double(elevatedCount) / Double(hrSamples.count)

        // Blend between base and elevated multiplier based on activity level
        let multiplier = config.baseCalorieMultiplier +
            (config.elevatedHRMultiplier - config.baseCalorieMultiplier) * elevatedRatio

        return multiplier
    }

    /// Estimate waking hours from sleep data
    private func calculateWakingHours(from whoopData: WhoopDailyPayload) -> Int {
        let totalSleepHours = whoopData.sleep
            .filter { !$0.nap }
            .reduce(0.0) { $0 + $1.durationHours }

        let wakingHours = max(0, 24 - Int(totalSleepHours))
        return min(wakingHours, 18) // Cap at 18 hours
    }

    // MARK: - Exercise Ring Calculation

    private struct ExerciseRingResult {
        let totalMinutes: Double
        let rawWorkoutMinutes: Double
        let lowIntensityMinutes: Double
        let moderateIntensityMinutes: Double
        let highIntensityMinutes: Double
    }

    private func calculateExerciseRingMetrics(from whoopData: WhoopDailyPayload) -> ExerciseRingResult {
        var lowIntensityMinutes: Double = 0
        var moderateIntensityMinutes: Double = 0
        var highIntensityMinutes: Double = 0

        let maxHR = Double(whoopData.maxHeartRate)
        let lightThreshold = maxHR * config.lightActivityHRThreshold
        let exerciseThreshold = maxHR * config.exerciseHRThreshold
        let highThreshold = maxHR * 0.75 // 75%+ is high intensity

        // Analyze HR samples minute by minute
        let samplesByMinute = groupSamplesByMinute(whoopData.heartRateSamples)

        for (_, samples) in samplesByMinute {
            guard let maxBPM = samples.map(\.bpm).max() else { continue }
            let hr = Double(maxBPM)

            if hr >= highThreshold {
                highIntensityMinutes += 1.0
            } else if hr >= exerciseThreshold {
                moderateIntensityMinutes += 1.0
            } else if hr >= lightThreshold {
                lowIntensityMinutes += 1.0
            }
        }

        // Calculate raw workout minutes from WHOOP workouts
        let rawWorkoutMinutes = whoopData.workouts.reduce(0.0) { $0 + $1.durationMinutes }

        // Apply light activity multiplier
        let adjustedLowMinutes = lowIntensityMinutes * config.lightActivityMultiplier

        // Full credit for moderate and high intensity
        var totalMinutes = adjustedLowMinutes + moderateIntensityMinutes + highIntensityMinutes

        // Add workout bonus (Apple is generous with workout start/end detection)
        totalMinutes += Double(whoopData.workouts.count) * config.workoutBonusMinutes

        // Ensure we're at least capturing workout duration
        totalMinutes = max(totalMinutes, rawWorkoutMinutes)

        return ExerciseRingResult(
            totalMinutes: totalMinutes,
            rawWorkoutMinutes: rawWorkoutMinutes,
            lowIntensityMinutes: lowIntensityMinutes,
            moderateIntensityMinutes: moderateIntensityMinutes,
            highIntensityMinutes: highIntensityMinutes
        )
    }

    /// Group HR samples by minute for minute-by-minute analysis
    private func groupSamplesByMinute(_ samples: [WhoopHeartRateSample]) -> [Date: [WhoopHeartRateSample]] {
        let calendar = Calendar.current
        return Dictionary(grouping: samples) { sample in
            calendar.date(bySetting: .second, value: 0, of: sample.time)!
        }
    }

    // MARK: - Stand Ring Calculation

    private struct StandRingResult {
        let totalStandHours: Set<Int>
        let hrSpikeHours: Set<Int>
        let activityHours: Set<Int>
        let inferredHours: Set<Int>
    }

    private func calculateStandRingMetrics(from whoopData: WhoopDailyPayload) -> StandRingResult {
        var hrSpikeHours = Set<Int>()
        var activityHours = Set<Int>()
        var inferredHours = Set<Int>()

        let calendar = Calendar.current
        let restingHR = whoopData.restingHeartRate
        let spikeThreshold = restingHR + config.standHRSpikeThreshold

        // Analyze HR spikes by hour
        let samplesByHour = whoopData.heartRateSamplesByHour()

        for hour in 0..<24 {
            if let samples = samplesByHour[hour] {
                // Check for HR spikes lasting > standMinDuration
                let spikedSamples = samples.filter { Double($0.bpm) > spikeThreshold }

                if !spikedSamples.isEmpty {
                    // Check if spikes span at least standMinDuration
                    let sortedSpikes = spikedSamples.sorted { $0.time < $1.time }
                    if let first = sortedSpikes.first, let last = sortedSpikes.last {
                        let duration = last.time.timeIntervalSince(first.time)
                        if duration >= config.standMinDuration || sortedSpikes.count >= 2 {
                            hrSpikeHours.insert(hour)
                        }
                    } else if sortedSpikes.count >= 1 {
                        // Single spike still counts
                        hrSpikeHours.insert(hour)
                    }
                }
            }
        }

        // Check workout hours - if there's a workout, you were definitely moving
        for workout in whoopData.workouts {
            let startHour = calendar.component(.hour, from: workout.start)
            let endHour = calendar.component(.hour, from: workout.end)

            for hour in startHour...endHour {
                activityHours.insert(hour)
            }
        }

        // Infer standing for hours where we have no data but expect movement
        let knownHours = hrSpikeHours.union(activityHours)
        let currentHour = calendar.component(.hour, from: Date())

        for hour in config.defaultStandHours {
            // Only infer for past hours on the same day
            if hour <= currentHour && !knownHours.contains(hour) {
                // Check if adjacent hours have activity (suggests continuity)
                let hasAdjacentActivity = knownHours.contains(hour - 1) || knownHours.contains(hour + 1)

                if hasAdjacentActivity {
                    inferredHours.insert(hour)
                }
            }
        }

        // Combine all sources
        let totalStandHours = hrSpikeHours.union(activityHours).union(inferredHours)

        return StandRingResult(
            totalStandHours: totalStandHours,
            hrSpikeHours: hrSpikeHours,
            activityHours: activityHours,
            inferredHours: inferredHours
        )
    }
}

// MARK: - Convenience Extension

extension GenerosityAlgorithm {

    /// Quick calculation using default balanced config
    static func calculate(from whoopData: WhoopDailyPayload) -> AppleStyleMetrics {
        GenerosityAlgorithm(config: .balanced).calculateAppleStyleMetrics(from: whoopData)
    }

    /// Print detailed breakdown for debugging
    func printBreakdown(_ metrics: AppleStyleMetrics) {
        let b = metrics.breakdown

        print("""
        ═══════════════════════════════════════════════════════════════
        GENEROSITY ALGORITHM BREAKDOWN - \(metrics.date)
        ═══════════════════════════════════════════════════════════════

        🔴 MOVE RING (Active Calories)
        ───────────────────────────────────────────────────────────────
        WHOOP Raw Calories:     \(String(format: "%.0f", b.whoopRawCalories)) kcal
        Applied Multiplier:     \(String(format: "%.2fx", b.calorieMultiplier))
        Motion Bonus (NEAT):    +\(String(format: "%.0f", b.motionBonusCalories)) kcal
        ───────────────────────────────────────────────────────────────
        FINAL MOVE CALORIES:    \(String(format: "%.0f", b.finalCalories)) kcal

        🟢 EXERCISE RING (Minutes)
        ───────────────────────────────────────────────────────────────
        WHOOP Workout Minutes:  \(String(format: "%.0f", b.whoopWorkoutMinutes)) min
        Low Intensity:          \(String(format: "%.0f", b.lowIntensityMinutes)) min (weighted)
        Moderate Intensity:     \(String(format: "%.0f", b.moderateIntensityMinutes)) min
        High Intensity:         \(String(format: "%.0f", b.highIntensityMinutes)) min
        ───────────────────────────────────────────────────────────────
        FINAL EXERCISE MINUTES: \(String(format: "%.0f", b.finalExerciseMinutes)) min

        🔵 STAND RING (Hours)
        ───────────────────────────────────────────────────────────────
        Hours with HR Spike:    \(b.hoursWithHRSpike.sorted())
        Hours with Activity:    \(b.hoursWithActivity.sorted())
        Inferred Movement:      \(b.hoursWithInferredMovement.sorted())
        ───────────────────────────────────────────────────────────────
        FINAL STAND HOURS:      \(b.finalStandHours.count)/12 - \(b.finalStandHours.sorted())

        ═══════════════════════════════════════════════════════════════
        """)
    }
}
