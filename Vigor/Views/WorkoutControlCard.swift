import SwiftUI

struct WorkoutControlCard: View {
    @ObservedObject var workoutManager: PolarWorkoutManager
    @ObservedObject var polarService: PolarBLEService
    var healthKitManager: HealthKitManager

    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Workout")
                    .font(.headline)

                Spacer()

                if workoutManager.workoutState.isActive {
                    PulsingDot()
                }
            }

            // Sport profile picker (only when idle)
            if !workoutManager.workoutState.isActive && !workoutManager.workoutState.isTransitioning {
                sportProfilePicker
            }

            // Status and elapsed time
            if workoutManager.workoutState.isActive {
                activeWorkoutStatus
            }

            // Action button
            actionButton
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .alert("Workout Error", isPresented: $showError) {
            Button("OK") {
                workoutManager.resetError()
            }
        } message: {
            Text(errorMessage)
        }
        .onChange(of: workoutManager.workoutState) { _, newState in
            if case .error(let message) = newState {
                errorMessage = message
                showError = true
            }
        }
    }

    private var sportProfilePicker: some View {
        HStack(spacing: 0) {
            ForEach(WorkoutSportProfile.allCases) { profile in
                Button {
                    workoutManager.currentSportProfile = profile
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: profile.icon)
                            .font(.caption)
                        Text(profile.rawValue)
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        workoutManager.currentSportProfile == profile
                            ? Color.blue
                            : Color.clear
                    )
                    .foregroundStyle(
                        workoutManager.currentSportProfile == profile
                            ? .white
                            : .primary
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.gray.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var activeWorkoutStatus: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: workoutManager.currentSportProfile.icon)
                    .font(.title2)
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workoutManager.currentSportProfile.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(workoutManager.formattedElapsedTime)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                }

                Spacer()
            }

            // Heart rate display
            HStack(spacing: 24) {
                // Current HR
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                    Text("\(workoutManager.currentHeartRate)")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 24)

                // Average HR
                HStack(spacing: 6) {
                    Text("Avg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(workoutManager.averageHeartRate)")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                    Text("bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch workoutManager.workoutState {
        case .idle:
            startButton

        case .starting:
            loadingButton(text: "Starting...")

        case .active:
            stopButton

        case .stopping:
            loadingButton(text: "Stopping...")

        case .error:
            startButton
        }
    }

    private var startButton: some View {
        Button {
            Task {
                do {
                    try await workoutManager.startWorkout(profile: workoutManager.currentSportProfile)
                } catch {
                    // Error handled by state change observer
                }
            }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Start Workout")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.green)
        .disabled(!polarService.connectionState.isConnected)
    }

    private var stopButton: some View {
        Button {
            Task {
                do {
                    try await workoutManager.stopWorkout(healthKitManager: healthKitManager)
                } catch {
                    // Error handled by state change observer
                }
            }
        } label: {
            HStack {
                Image(systemName: "stop.fill")
                Text("Stop Workout")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }

    private func loadingButton(text: String) -> some View {
        HStack {
            ProgressView()
                .tint(.white)
            Text(text)
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.gray)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .scaleEffect(isPulsing ? 1.2 : 1.0)
            .opacity(isPulsing ? 0.7 : 1.0)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear {
                isPulsing = true
            }
    }
}

#Preview {
    WorkoutControlCard(
        workoutManager: PolarWorkoutManager.shared,
        polarService: PolarBLEService.shared,
        healthKitManager: HealthKitManager()
    )
    .padding()
    .background(Color(red: 0.118, green: 0.129, blue: 0.165))
}
