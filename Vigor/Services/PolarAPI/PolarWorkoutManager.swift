import Foundation
import HealthKit
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

// MARK: - Sport Profile

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
}

// MARK: - Errors

enum PolarWorkoutError: LocalizedError {
    case notConnected
    case workoutAlreadyActive
    case noActiveWorkout
    case streamingFailed(String)

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
    @Published var currentSportProfile: WorkoutSportProfile = .other
    @Published var elapsedSeconds: Int = 0
    @Published var currentHeartRate: Int = 0
    @Published var averageHeartRate: Int = 0

    private let polarService = PolarBLEService.shared
    private let disposeBag = DisposeBag()
    private var timerTask: Task<Void, Never>?
    private var hrStreamDisposable: Disposable?
    private var heartRateSamples: [Int] = []
    private var timestampedHRSamples: [(date: Date, hr: Int)] = []
    private var workoutStartTime: Date?

    private init() {}

    // MARK: - Workout Control

    func startWorkout(profile: WorkoutSportProfile) async throws {
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
        currentSportProfile = profile
        heartRateSamples = []
        timestampedHRSamples = []
        currentHeartRate = 0
        averageHeartRate = 0

        // Start HR streaming for live heart rate during workout
        startHRStreaming(deviceId: deviceId)

        let startTime = Date()
        workoutStartTime = startTime
        workoutState = .active(startTime: startTime)
        elapsedSeconds = 0
        startTimer(from: startTime)

        print("PolarWorkout: Started \(profile.rawValue) workout with HR streaming")
    }

    func stopWorkout(healthKitManager: HealthKitManager) async throws {
        guard workoutState.isActive else {
            throw PolarWorkoutError.noActiveWorkout
        }

        guard let startTime = workoutStartTime else {
            throw PolarWorkoutError.noActiveWorkout
        }

        let endTime = Date()
        let sportProfile = currentSportProfile

        workoutState = .stopping
        stopTimer()
        stopHRStreaming()

        // Calculate final average
        if !heartRateSamples.isEmpty {
            averageHeartRate = heartRateSamples.reduce(0, +) / heartRateSamples.count
        }

        // Save workout to Apple Health
        let saved = await healthKitManager.saveWorkout(
            activityType: sportProfile.healthKitActivityType,
            startDate: startTime,
            endDate: endTime,
            averageHeartRate: averageHeartRate > 0 ? averageHeartRate : nil,
            heartRateSamples: timestampedHRSamples
        )

        if saved {
            print("PolarWorkout: Saved workout to Apple Health. Duration: \(elapsedSeconds)s, Avg HR: \(averageHeartRate) bpm")
        } else {
            print("PolarWorkout: Failed to save workout to Apple Health")
        }

        workoutStartTime = nil
        workoutState = .idle
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
}
