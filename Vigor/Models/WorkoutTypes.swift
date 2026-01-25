import Foundation
import HealthKit

// MARK: - Workout Category

enum WorkoutCategory: String, CaseIterable, Identifiable, Codable {
    case running = "Running"
    case cycling = "Cycling"
    case swimming = "Swimming"
    case gym = "Gym & Fitness"
    case outdoor = "Outdoor Sports"
    case team = "Team Sports"
    case water = "Water Sports"
    case winter = "Winter Sports"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .swimming: return "figure.pool.swim"
        case .gym: return "dumbbell.fill"
        case .outdoor: return "figure.hiking"
        case .team: return "sportscourt.fill"
        case .water: return "water.waves"
        case .winter: return "snowflake"
        case .other: return "figure.mixed.cardio"
        }
    }
}

// MARK: - Workout Type

struct WorkoutType: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let icon: String
    let category: WorkoutCategory
    let isOutdoor: Bool
    let healthKitTypeRaw: UInt

    var healthKitType: HKWorkoutActivityType {
        HKWorkoutActivityType(rawValue: healthKitTypeRaw) ?? .other
    }

    init(id: String, name: String, icon: String, category: WorkoutCategory, isOutdoor: Bool, healthKitType: HKWorkoutActivityType) {
        self.id = id
        self.name = name
        self.icon = icon
        self.category = category
        self.isOutdoor = isOutdoor
        self.healthKitTypeRaw = healthKitType.rawValue
    }
}

// MARK: - Predefined Workout Types

extension WorkoutType {
    static let all: [WorkoutType] = [
        // Running
        WorkoutType(id: "running", name: "Running", icon: "figure.run", category: .running, isOutdoor: true, healthKitType: .running),
        WorkoutType(id: "treadmill", name: "Treadmill", icon: "figure.run.treadmill", category: .running, isOutdoor: false, healthKitType: .running),
        WorkoutType(id: "trail_running", name: "Trail Running", icon: "figure.run", category: .running, isOutdoor: true, healthKitType: .running),
        WorkoutType(id: "track_running", name: "Track Running", icon: "figure.run", category: .running, isOutdoor: true, healthKitType: .running),

        // Cycling
        WorkoutType(id: "cycling", name: "Cycling", icon: "figure.outdoor.cycle", category: .cycling, isOutdoor: true, healthKitType: .cycling),
        WorkoutType(id: "indoor_cycling", name: "Indoor Cycling", icon: "figure.indoor.cycle", category: .cycling, isOutdoor: false, healthKitType: .cycling),
        WorkoutType(id: "mountain_biking", name: "Mountain Biking", icon: "figure.outdoor.cycle", category: .cycling, isOutdoor: true, healthKitType: .cycling),
        WorkoutType(id: "road_cycling", name: "Road Cycling", icon: "figure.outdoor.cycle", category: .cycling, isOutdoor: true, healthKitType: .cycling),
        WorkoutType(id: "gravel_cycling", name: "Gravel Cycling", icon: "figure.outdoor.cycle", category: .cycling, isOutdoor: true, healthKitType: .cycling),

        // Swimming
        WorkoutType(id: "pool_swimming", name: "Pool Swimming", icon: "figure.pool.swim", category: .swimming, isOutdoor: false, healthKitType: .swimming),
        WorkoutType(id: "open_water", name: "Open Water", icon: "figure.open.water.swim", category: .swimming, isOutdoor: true, healthKitType: .swimming),

        // Gym & Fitness
        WorkoutType(id: "strength", name: "Strength Training", icon: "dumbbell.fill", category: .gym, isOutdoor: false, healthKitType: .traditionalStrengthTraining),
        WorkoutType(id: "functional_strength", name: "Functional Strength", icon: "figure.strengthtraining.functional", category: .gym, isOutdoor: false, healthKitType: .functionalStrengthTraining),
        WorkoutType(id: "hiit", name: "HIIT", icon: "bolt.heart.fill", category: .gym, isOutdoor: false, healthKitType: .highIntensityIntervalTraining),
        WorkoutType(id: "yoga", name: "Yoga", icon: "figure.yoga", category: .gym, isOutdoor: false, healthKitType: .yoga),
        WorkoutType(id: "pilates", name: "Pilates", icon: "figure.pilates", category: .gym, isOutdoor: false, healthKitType: .pilates),
        WorkoutType(id: "core_training", name: "Core Training", icon: "figure.core.training", category: .gym, isOutdoor: false, healthKitType: .coreTraining),
        WorkoutType(id: "flexibility", name: "Flexibility", icon: "figure.flexibility", category: .gym, isOutdoor: false, healthKitType: .flexibility),
        WorkoutType(id: "dance", name: "Dance", icon: "figure.dance", category: .gym, isOutdoor: false, healthKitType: .socialDance),
        WorkoutType(id: "elliptical", name: "Elliptical", icon: "figure.elliptical", category: .gym, isOutdoor: false, healthKitType: .elliptical),
        WorkoutType(id: "stair_stepper", name: "Stair Stepper", icon: "figure.stair.stepper", category: .gym, isOutdoor: false, healthKitType: .stairClimbing),
        WorkoutType(id: "rowing", name: "Rowing Machine", icon: "figure.rower", category: .gym, isOutdoor: false, healthKitType: .rowing),
        WorkoutType(id: "boxing", name: "Boxing", icon: "figure.boxing", category: .gym, isOutdoor: false, healthKitType: .boxing),
        WorkoutType(id: "kickboxing", name: "Kickboxing", icon: "figure.kickboxing", category: .gym, isOutdoor: false, healthKitType: .kickboxing),
        WorkoutType(id: "martial_arts", name: "Martial Arts", icon: "figure.martial.arts", category: .gym, isOutdoor: false, healthKitType: .martialArts),
        WorkoutType(id: "wrestling", name: "Wrestling", icon: "figure.wrestling", category: .gym, isOutdoor: false, healthKitType: .wrestling),
        WorkoutType(id: "taekwondo", name: "Taekwondo", icon: "figure.taekwondo", category: .gym, isOutdoor: false, healthKitType: .martialArts),
        WorkoutType(id: "mma", name: "MMA", icon: "figure.mma", category: .gym, isOutdoor: false, healthKitType: .mixedCardio),

        // Outdoor Sports
        WorkoutType(id: "hiking", name: "Hiking", icon: "figure.hiking", category: .outdoor, isOutdoor: true, healthKitType: .hiking),
        WorkoutType(id: "walking", name: "Walking", icon: "figure.walk", category: .outdoor, isOutdoor: true, healthKitType: .walking),
        WorkoutType(id: "climbing", name: "Climbing", icon: "figure.climbing", category: .outdoor, isOutdoor: true, healthKitType: .climbing),
        WorkoutType(id: "golf", name: "Golf", icon: "figure.golf", category: .outdoor, isOutdoor: true, healthKitType: .golf),

        // Team Sports
        WorkoutType(id: "soccer", name: "Soccer", icon: "figure.soccer", category: .team, isOutdoor: true, healthKitType: .soccer),
        WorkoutType(id: "basketball", name: "Basketball", icon: "figure.basketball", category: .team, isOutdoor: false, healthKitType: .basketball),
        WorkoutType(id: "tennis", name: "Tennis", icon: "figure.tennis", category: .team, isOutdoor: true, healthKitType: .tennis),
        WorkoutType(id: "volleyball", name: "Volleyball", icon: "figure.volleyball", category: .team, isOutdoor: true, healthKitType: .volleyball),
        WorkoutType(id: "badminton", name: "Badminton", icon: "figure.badminton", category: .team, isOutdoor: false, healthKitType: .badminton),
        WorkoutType(id: "table_tennis", name: "Table Tennis", icon: "figure.table.tennis", category: .team, isOutdoor: false, healthKitType: .tableTennis),
        WorkoutType(id: "squash", name: "Squash", icon: "figure.squash", category: .team, isOutdoor: false, healthKitType: .squash),
        WorkoutType(id: "hockey", name: "Hockey", icon: "figure.hockey", category: .team, isOutdoor: false, healthKitType: .hockey),

        // Water Sports
        WorkoutType(id: "kayaking", name: "Kayaking", icon: "oar.2.crossed", category: .water, isOutdoor: true, healthKitType: .paddleSports),
        WorkoutType(id: "sup", name: "Stand Up Paddling", icon: "figure.surfing", category: .water, isOutdoor: true, healthKitType: .paddleSports),
        WorkoutType(id: "surfing", name: "Surfing", icon: "figure.surfing", category: .water, isOutdoor: true, healthKitType: .surfingSports),
        WorkoutType(id: "water_polo", name: "Water Polo", icon: "figure.waterpolo", category: .water, isOutdoor: false, healthKitType: .waterPolo),

        // Winter Sports
        WorkoutType(id: "skiing", name: "Skiing", icon: "figure.skiing.downhill", category: .winter, isOutdoor: true, healthKitType: .downhillSkiing),
        WorkoutType(id: "cross_country_skiing", name: "Cross-Country Skiing", icon: "figure.skiing.crosscountry", category: .winter, isOutdoor: true, healthKitType: .crossCountrySkiing),
        WorkoutType(id: "snowboarding", name: "Snowboarding", icon: "figure.snowboarding", category: .winter, isOutdoor: true, healthKitType: .snowboarding),
        WorkoutType(id: "ice_skating", name: "Ice Skating", icon: "figure.skating", category: .winter, isOutdoor: true, healthKitType: .skatingSports),

        // Other
        WorkoutType(id: "other_indoor", name: "Other Indoor", icon: "figure.mixed.cardio", category: .other, isOutdoor: false, healthKitType: .other),
        WorkoutType(id: "other_outdoor", name: "Other Outdoor", icon: "figure.mixed.cardio", category: .other, isOutdoor: true, healthKitType: .other),
    ]

    static func find(by id: String) -> WorkoutType? {
        all.first { $0.id == id }
    }

    static func workouts(in category: WorkoutCategory) -> [WorkoutType] {
        all.filter { $0.category == category }
    }
}

// MARK: - Default Favorites

extension WorkoutType {
    static let defaultFavoriteIds = ["running", "cycling", "strength", "yoga"]
}
