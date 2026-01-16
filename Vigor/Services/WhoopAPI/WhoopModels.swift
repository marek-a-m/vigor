import Foundation

// MARK: - OAuth Models

struct WhoopTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

struct WhoopCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }
}

// MARK: - User Profile

struct WhoopUserProfile: Codable {
    let userId: Int
    let email: String
    let firstName: String
    let lastName: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email
        case firstName = "first_name"
        case lastName = "last_name"
    }
}

struct WhoopBodyMeasurement: Codable {
    let heightMeter: Double
    let weightKilogram: Double
    let maxHeartRate: Int

    enum CodingKeys: String, CodingKey {
        case heightMeter = "height_meter"
        case weightKilogram = "weight_kilogram"
        case maxHeartRate = "max_heart_rate"
    }
}

// MARK: - Heart Rate Data

struct WhoopHeartRateSample: Codable {
    let time: Date
    let bpm: Int
}

struct WhoopHeartRateData {
    let samples: [WhoopHeartRateSample]
    let date: Date

    /// Group samples by clock hour
    func samplesByHour() -> [Int: [WhoopHeartRateSample]] {
        let calendar = Calendar.current
        return Dictionary(grouping: samples) { sample in
            calendar.component(.hour, from: sample.time)
        }
    }

    /// Get average HR for a specific hour
    func averageHR(forHour hour: Int) -> Double? {
        let hourSamples = samplesByHour()[hour]
        guard let samples = hourSamples, !samples.isEmpty else { return nil }
        return Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
    }

    /// Get max HR for a specific hour
    func maxHR(forHour hour: Int) -> Int? {
        samplesByHour()[hour]?.map(\.bpm).max()
    }
}

// MARK: - Cycle (Recovery/Strain)

struct WhoopCycle: Codable {
    let id: Int
    let userId: Int
    let start: Date
    let end: Date?
    let timezoneOffset: String
    let score: WhoopCycleScore?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case start
        case end
        case timezoneOffset = "timezone_offset"
        case score
    }
}

struct WhoopCycleScore: Codable {
    let strain: Double
    let kilojoule: Double
    let averageHeartRate: Int
    let maxHeartRate: Int

    enum CodingKeys: String, CodingKey {
        case strain
        case kilojoule
        case averageHeartRate = "average_heart_rate"
        case maxHeartRate = "max_heart_rate"
    }

    /// Convert kilojoules to kilocalories
    var calories: Double {
        kilojoule / 4.184
    }
}

// MARK: - Workout

struct WhoopWorkout: Codable {
    let id: Int
    let userId: Int
    let start: Date
    let end: Date
    let timezoneOffset: String
    let sportId: Int
    let score: WhoopWorkoutScore?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case start
        case end
        case timezoneOffset = "timezone_offset"
        case sportId = "sport_id"
        case score
    }

    var durationMinutes: Double {
        end.timeIntervalSince(start) / 60.0
    }
}

struct WhoopWorkoutScore: Codable {
    let strain: Double
    let averageHeartRate: Int
    let maxHeartRate: Int
    let kilojoule: Double
    let percentRecorded: Double
    let zoneZeroMillis: Int?
    let zoneOneMillis: Int?
    let zoneTwoMillis: Int?
    let zoneThreeMillis: Int?
    let zoneFourMillis: Int?
    let zoneFiveMillis: Int?

    enum CodingKeys: String, CodingKey {
        case strain
        case averageHeartRate = "average_heart_rate"
        case maxHeartRate = "max_heart_rate"
        case kilojoule
        case percentRecorded = "percent_recorded"
        case zoneZeroMillis = "zone_zero_milli"
        case zoneOneMillis = "zone_one_milli"
        case zoneTwoMillis = "zone_two_milli"
        case zoneThreeMillis = "zone_three_milli"
        case zoneFourMillis = "zone_four_milli"
        case zoneFiveMillis = "zone_five_milli"
    }

    var calories: Double {
        kilojoule / 4.184
    }

    /// Total time in zones 2+ (moderate to high intensity) in minutes
    var moderateToHighIntensityMinutes: Double {
        let millis = (zoneTwoMillis ?? 0) + (zoneThreeMillis ?? 0) +
                     (zoneFourMillis ?? 0) + (zoneFiveMillis ?? 0)
        return Double(millis) / 60000.0
    }
}

// MARK: - Sleep

struct WhoopSleep: Codable {
    let id: Int
    let userId: Int
    let start: Date
    let end: Date
    let timezoneOffset: String
    let nap: Bool
    let score: WhoopSleepScore?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case start
        case end
        case timezoneOffset = "timezone_offset"
        case nap
        case score
    }

    var durationHours: Double {
        end.timeIntervalSince(start) / 3600.0
    }
}

struct WhoopSleepScore: Codable {
    let stageSummary: WhoopSleepStageSummary
    let sleepNeeded: WhoopSleepNeeded
    let respiratoryRate: Double?
    let sleepPerformancePercentage: Double?
    let sleepConsistencyPercentage: Double?
    let sleepEfficiencyPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case stageSummary = "stage_summary"
        case sleepNeeded = "sleep_needed"
        case respiratoryRate = "respiratory_rate"
        case sleepPerformancePercentage = "sleep_performance_percentage"
        case sleepConsistencyPercentage = "sleep_consistency_percentage"
        case sleepEfficiencyPercentage = "sleep_efficiency_percentage"
    }
}

struct WhoopSleepStageSummary: Codable {
    let totalInBedTimeMilli: Int
    let totalAwakeTimeMilli: Int
    let totalNoDataTimeMilli: Int
    let totalLightSleepTimeMilli: Int
    let totalSlowWaveSleepTimeMilli: Int
    let totalRemSleepTimeMilli: Int
    let sleepCycleCount: Int
    let disturbanceCount: Int

    enum CodingKeys: String, CodingKey {
        case totalInBedTimeMilli = "total_in_bed_time_milli"
        case totalAwakeTimeMilli = "total_awake_time_milli"
        case totalNoDataTimeMilli = "total_no_data_time_milli"
        case totalLightSleepTimeMilli = "total_light_sleep_time_milli"
        case totalSlowWaveSleepTimeMilli = "total_slow_wave_sleep_time_milli"
        case totalRemSleepTimeMilli = "total_rem_sleep_time_milli"
        case sleepCycleCount = "sleep_cycle_count"
        case disturbanceCount = "disturbance_count"
    }

    var totalSleepMinutes: Double {
        Double(totalLightSleepTimeMilli + totalSlowWaveSleepTimeMilli + totalRemSleepTimeMilli) / 60000.0
    }
}

struct WhoopSleepNeeded: Codable {
    let baselineMilli: Int
    let needFromSleepDebtMilli: Int
    let needFromRecentStrainMilli: Int
    let needFromRecentNapMilli: Int

    enum CodingKeys: String, CodingKey {
        case baselineMilli = "baseline_milli"
        case needFromSleepDebtMilli = "need_from_sleep_debt_milli"
        case needFromRecentStrainMilli = "need_from_recent_strain_milli"
        case needFromRecentNapMilli = "need_from_recent_nap_milli"
    }
}

// MARK: - Recovery

struct WhoopRecovery: Codable {
    let cycleId: Int
    let sleepId: Int
    let userId: Int
    let score: WhoopRecoveryScore

    enum CodingKeys: String, CodingKey {
        case cycleId = "cycle_id"
        case sleepId = "sleep_id"
        case userId = "user_id"
        case score
    }
}

struct WhoopRecoveryScore: Codable {
    let userCalibrating: Bool
    let recoveryScore: Double
    let restingHeartRate: Double
    let hrvRmssdMilli: Double
    let spo2Percentage: Double?
    let skinTempCelsius: Double?

    enum CodingKeys: String, CodingKey {
        case userCalibrating = "user_calibrating"
        case recoveryScore = "recovery_score"
        case restingHeartRate = "resting_heart_rate"
        case hrvRmssdMilli = "hrv_rmssd_milli"
        case spo2Percentage = "spo2_percentage"
        case skinTempCelsius = "skin_temp_celsius"
    }
}

// MARK: - API Response Wrappers

struct WhoopPaginatedResponse<T: Codable>: Codable {
    let records: [T]
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case records
        case nextToken = "next_token"
    }
}

// MARK: - Aggregated Daily Data

/// All WHOOP data for a single day, used as input to the Generosity Algorithm
struct WhoopDailyPayload {
    let date: Date
    let restingHeartRate: Double
    let maxHeartRate: Int
    let heartRateSamples: [WhoopHeartRateSample]
    let cycles: [WhoopCycle]
    let workouts: [WhoopWorkout]
    let sleep: [WhoopSleep]
    let recovery: WhoopRecovery?

    /// Calculate total active calories from cycles and workouts
    var totalActiveCalories: Double {
        let cycleCalories = cycles.compactMap { $0.score?.calories }.reduce(0, +)
        let workoutCalories = workouts.compactMap { $0.score?.calories }.reduce(0, +)
        // Avoid double-counting: workouts are part of cycles
        return max(cycleCalories, workoutCalories)
    }

    /// Group heart rate samples by hour
    func heartRateSamplesByHour() -> [Int: [WhoopHeartRateSample]] {
        let calendar = Calendar.current
        return Dictionary(grouping: heartRateSamples) { sample in
            calendar.component(.hour, from: sample.time)
        }
    }
}
