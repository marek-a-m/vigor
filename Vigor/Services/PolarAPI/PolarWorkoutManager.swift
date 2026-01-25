import Foundation
import HealthKit
import CoreLocation
import PolarBleSdk
import RxSwift

// MARK: - Workout State

enum WorkoutState: Equatable {
    case idle
    case starting
    case active(startTime: Date)
    case stopping
    case error(String)

    static func == (lhs: WorkoutState, rhs: WorkoutState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.starting, .starting), (.stopping, .stopping):
            return true
        case let (.active(lhsTime), .active(rhsTime)):
            return lhsTime == rhsTime
        case let (.error(lhsMsg), .error(rhsMsg)):
            return lhsMsg == rhsMsg
        default:
            return false
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var isTransitioning: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }
}

// MARK: - Sport Profile (Legacy - kept for backward compatibility)

enum WorkoutSportProfile: String, CaseIterable, Identifiable {
    case running = "Running"
    case cycling = "Cycling"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .running: return "figure.run"
        case .cycling: return "figure.outdoor.cycle"
        case .other: return "figure.mixed.cardio"
        }
    }

    var healthKitActivityType: HKWorkoutActivityType {
        switch self {
        case .running: return .running
        case .cycling: return .cycling
        case .other: return .other
        }
    }

    /// Convert to new WorkoutType
    var workoutType: WorkoutType? {
        switch self {
        case .running: return WorkoutType.find(by: "running")
        case .cycling: return WorkoutType.find(by: "cycling")
        case .other: return WorkoutType.find(by: "other_indoor")
        }
    }
}

// MARK: - Errors

enum PolarWorkoutError: LocalizedError {
    case notConnected
    case workoutAlreadyActive
    case noActiveWorkout
    case streamingFailed(String)
    case locationNotAuthorized

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Polar device is not connected"
        case .workoutAlreadyActive:
            return "A workout is already in progress"
        case .noActiveWorkout:
            return "No active workout to stop"
        case .streamingFailed(let message):
            return message
        case .locationNotAuthorized:
            return "Location permission required for outdoor workouts"
        }
    }
}

// MARK: - Polar Workout Manager

/// Manages workout tracking with Polar devices using HR streaming.
/// Note: The Polar Loop uses automatic training detection on-device.
/// This manager provides app-side workout tracking with live heart rate data.
@MainActor
final class PolarWorkoutManager: ObservableObject {
    static let shared = PolarWorkoutManager()

    @Published var workoutState: WorkoutState = .idle
    @Published var currentWorkoutType: WorkoutType?
    @Published var currentSportProfile: WorkoutSportProfile = .other  // Legacy, for backward compat
    @Published var elapsedSeconds: Int = 0
    @Published var currentHeartRate: Int = 0
    @Published var averageHeartRate: Int = 0

    // Location tracking
    @Published var isTrackingLocation: Bool = false
    @Published var totalDistance: Double = 0  // meters
    @Published var currentSpeed: Double = 0  // m/s

    private let polarService = PolarBLEService.shared
    private let locationTracker = LocationTracker.shared
    private let disposeBag = DisposeBag()
    private var timerTask: Task<Void, Never>?
    private var hrStreamDisposable: Disposable?
    private var heartRateSamples: [Int] = []
    private var timestampedHRSamples: [(date: Date, hr: Int)] = []
    private var workoutStartTime: Date?
    private var capturedRouteLocations: [CLLocation] = []

    private init() {}

    // MARK: - Workout Control (New WorkoutType API)

    func startWorkout(type: WorkoutType) async throws {
        guard polarService.connectionState.isConnected else {
            throw PolarWorkoutError.notConnected
        }

        guard !workoutState.isActive else {
            throw PolarWorkoutError.workoutAlreadyActive
        }

        guard let deviceId = SettingsManager.shared.polarDeviceId else {
            throw PolarWorkoutError.notConnected
        }

        workoutState = .starting
        currentWorkoutType = type
        heartRateSamples = []
        timestampedHRSamples = []
        currentHeartRate = 0
        averageHeartRate = 0
        totalDistance = 0
        currentSpeed = 0
        capturedRouteLocations = []

        // Start location tracking for outdoor workouts
        if type.isOutdoor {
            if locationTracker.isAuthorizedForTracking {
                locationTracker.startTracking()
                isTrackingLocation = true
            } else {
                locationTracker.requestAuthorization()
                // Continue without GPS if not authorized
                print("PolarWorkout: Location not authorized, continuing without GPS")
            }
        }

        // Start HR streaming for live heart rate during workout
        startHRStreaming(deviceId: deviceId)

        let startTime = Date()
        workoutStartTime = startTime
        workoutState = .active(startTime: startTime)
        elapsedSeconds = 0
        startTimer(from: startTime)

        print("PolarWorkout: Started \(type.name) workout with HR streaming" + (type.isOutdoor ? " and GPS" : ""))
    }

    func stopWorkout(healthKitManager: HealthKitManager) async throws {
        guard workoutState.isActive else {
            throw PolarWorkoutError.noActiveWorkout
        }

        guard let startTime = workoutStartTime else {
            throw PolarWorkoutError.noActiveWorkout
        }

        let endTime = Date()
        let workoutType = currentWorkoutType

        workoutState = .stopping
        stopTimer()
        stopHRStreaming()

        // Stop location tracking and capture route
        if isTrackingLocation {
            capturedRouteLocations = locationTracker.stopTracking()
            totalDistance = locationTracker.totalDistance
            isTrackingLocation = false
        }

        // Calculate final average
        if !heartRateSamples.isEmpty {
            averageHeartRate = heartRateSamples.reduce(0, +) / heartRateSamples.count
        }

        // Determine activity type
        let activityType = workoutType?.healthKitType ?? currentSportProfile.healthKitActivityType

        // Save workout to Apple Health
        let saved = await healthKitManager.saveWorkout(
            activityType: activityType,
            startDate: startTime,
            endDate: endTime,
            averageHeartRate: averageHeartRate > 0 ? averageHeartRate : nil,
            heartRateSamples: timestampedHRSamples,
            routeLocations: capturedRouteLocations.isEmpty ? nil : capturedRouteLocations,
            totalDistance: totalDistance > 0 ? totalDistance : nil
        )

        if saved {
            print("PolarWorkout: Saved workout to Apple Health. Duration: \(elapsedSeconds)s, Avg HR: \(averageHeartRate) bpm, Distance: \(String(format: "%.0f", totalDistance))m")
        } else {
            print("PolarWorkout: Failed to save workout to Apple Health")
        }

        workoutStartTime = nil
        currentWorkoutType = nil
        capturedRouteLocations = []
        workoutState = .idle
    }

    /// Discard the current workout without saving to Apple Health
    func discardWorkout() async {
        guard workoutState.isActive else { return }

        workoutState = .stopping
        stopTimer()
        stopHRStreaming()

        // Stop location tracking without saving route
        if isTrackingLocation {
            _ = locationTracker.stopTracking()
            isTrackingLocation = false
        }

        print("PolarWorkout: Discarded workout. Duration: \(elapsedSeconds)s")

        // Reset all state
        workoutStartTime = nil
        currentWorkoutType = nil
        capturedRouteLocations = []
        heartRateSamples = []
        timestampedHRSamples = []
        elapsedSeconds = 0
        currentHeartRate = 0
        averageHeartRate = 0
        totalDistance = 0
        currentSpeed = 0
        workoutState = .idle
    }

    // MARK: - Workout Control (Legacy API - for WorkoutControlCard compatibility)

    func startWorkout(profile: WorkoutSportProfile) async throws {
        // Convert legacy profile to WorkoutType
        if let workoutType = profile.workoutType {
            try await startWorkout(type: workoutType)
        } else {
            // Fallback: create a basic workout type
            let fallbackType = WorkoutType(
                id: profile.rawValue.lowercased(),
                name: profile.rawValue,
                icon: profile.icon,
                category: .other,
                isOutdoor: false,
                healthKitType: profile.healthKitActivityType
            )
            try await startWorkout(type: fallbackType)
        }
        currentSportProfile = profile
    }

    // MARK: - HR Streaming

    private func startHRStreaming(deviceId: String) {
        hrStreamDisposable = polarService.polarApi.startHrStreaming(deviceId)
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] hrData in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let now = Date()
                        // PolarHrData is an array of HR sample tuples
                        for sample in hrData {
                            self.currentHeartRate = Int(sample.hr)
                            if sample.hr > 0 {
                                self.heartRateSamples.append(Int(sample.hr))
                                self.timestampedHRSamples.append((date: now, hr: Int(sample.hr)))
                                // Update running average
                                self.averageHeartRate = self.heartRateSamples.reduce(0, +) / self.heartRateSamples.count
                            }
                        }

                        // Update location stats if tracking
                        if self.isTrackingLocation {
                            self.totalDistance = self.locationTracker.totalDistance
                            self.currentSpeed = self.locationTracker.currentSpeed
                        }
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        self?.workoutState = .error("HR streaming failed: \(error.localizedDescription)")
                    }
                }
            )
    }

    private func stopHRStreaming() {
        hrStreamDisposable?.dispose()
        hrStreamDisposable = nil
    }

    // MARK: - Timer

    private func startTimer(from startTime: Date) {
        stopTimer()

        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                let elapsed = Int(Date().timeIntervalSince(startTime))
                await MainActor.run {
                    self.elapsedSeconds = elapsed

                    // Update location stats periodically
                    if self.isTrackingLocation {
                        self.totalDistance = self.locationTracker.totalDistance
                        self.currentSpeed = self.locationTracker.currentSpeed
                    }
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Helpers

    func resetError() {
        if case .error = workoutState {
            workoutState = .idle
        }
    }

    var formattedElapsedTime: String {
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    var formattedDistance: String {
        if totalDistance >= 1000 {
            return String(format: "%.2f km", totalDistance / 1000)
        } else {
            return String(format: "%.0f m", totalDistance)
        }
    }

    var formattedPace: String? {
        guard currentSpeed > 0 else { return nil }

        // Pace in minutes per kilometer
        let paceSecondsPerKm = 1000 / currentSpeed
        let minutes = Int(paceSecondsPerKm) / 60
        let seconds = Int(paceSecondsPerKm) % 60

        return String(format: "%d:%02d /km", minutes, seconds)
    }
}
