import SwiftUI
import MapKit

struct WorkoutView: View {
    @StateObject private var workoutManager = PolarWorkoutManager.shared
    @ObservedObject private var polarService = PolarBLEService.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var locationTracker = LocationTracker.shared

    var healthKitManager: HealthKitManager

    @State private var showAllWorkouts = false
    @State private var showSettings = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var selectedWorkout: WorkoutType?
    @State private var showStopConfirmation = false

    private let backgroundColor = Color(red: 0.118, green: 0.129, blue: 0.165)

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    var body: some View {
        NavigationStack {
            Group {
                if workoutManager.workoutState.isActive || workoutManager.workoutState.isTransitioning {
                    // Active workout - no scroll, fixed layout
                    activeWorkoutView
                        .padding()
                } else {
                    // Idle/pre-workout - scrollable
                    ScrollView {
                        VStack(spacing: 24) {
                            if let workout = selectedWorkout {
                                preWorkoutView(workout: workout)
                            } else {
                                idleWorkoutView
                            }
                        }
                        .padding()
                        .padding(.top, 8)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(backgroundColor.ignoresSafeArea())
            .toolbar(workoutManager.workoutState.isActive ? .hidden : .visible, for: .tabBar)
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectedWorkout != nil && !workoutManager.workoutState.isActive {
                        Button {
                            selectedWorkout = nil
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                            .foregroundStyle(.white)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedWorkout == nil {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .sheet(isPresented: $showAllWorkouts) {
                AllWorkoutsSheet(onSelect: selectWorkout)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settingsManager: settingsManager)
            }
            .alert("Workout Error", isPresented: $showError) {
                Button("OK") {
                    workoutManager.resetError()
                }
            } message: {
                Text(errorMessage)
            }
            .confirmationDialog("End Workout?", isPresented: $showStopConfirmation, titleVisibility: .visible) {
                Button("Continue Workout") {
                    // Just dismiss, workout continues
                }
                Button("Save Workout", role: .destructive) {
                    saveWorkout()
                }
                Button("Discard Workout", role: .destructive) {
                    discardWorkout()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("What would you like to do with this workout?")
            }
            .onChange(of: workoutManager.workoutState) { _, newState in
                if case .error(let message) = newState {
                    errorMessage = message
                    showError = true
                }
            }
        }
    }

    // MARK: - Idle View

    private var idleWorkoutView: some View {
        VStack(spacing: 24) {
            // Connection status
            connectionStatusCard

            // Quick Start section
            VStack(alignment: .leading, spacing: 16) {
                Text("Quick Start")
                    .font(.headline)
                    .foregroundStyle(.white)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(settingsManager.favoriteWorkouts) { workout in
                        WorkoutQuickStartButton(workout: workout, isEnabled: canSelectWorkout) {
                            selectWorkout(workout)
                        }
                    }

                    // "More" button to browse all
                    Button {
                        showAllWorkouts = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(.blue)

                            Text("More")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Browse all button
            Button {
                showAllWorkouts = true
            } label: {
                HStack {
                    Image(systemName: "list.bullet")
                    Text("Browse All Workouts")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
        }
    }

    // MARK: - Pre-Workout View

    private func preWorkoutView(workout: WorkoutType) -> some View {
        VStack(spacing: 32) {
            Spacer()

            // Workout icon and name
            VStack(spacing: 16) {
                Image(systemName: workout.icon)
                    .font(.system(size: 80))
                    .foregroundStyle(.blue)

                Text(workout.name)
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Outdoor indicator
                if workout.isOutdoor {
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill")
                        Text("GPS tracking enabled")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            // Connection status
            if polarService.connectionState.isConnected {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Polar Connected")
                        .foregroundStyle(.secondary)
                    if let deviceName = settingsManager.polarDeviceName {
                        Text("(\(deviceName))")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.subheadline)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("Polar not connected")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            Spacer()

            // Start button
            Button {
                startWorkout(workout)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Start Workout")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(!polarService.connectionState.isConnected)
        }
    }

    // MARK: - Active Workout View

    private var activeWorkoutView: some View {
        VStack(spacing: 16) {
            Spacer()
                .frame(height: 8)
            // Header with workout type and recording indicator
            HStack {
                if let workoutType = workoutManager.currentWorkoutType {
                    Image(systemName: workoutType.icon)
                        .font(.title2)
                        .foregroundStyle(.blue)

                    Text(workoutType.name)
                        .font(.headline)
                }

                Spacer()

                if workoutManager.workoutState.isActive {
                    HStack(spacing: 6) {
                        PulsingDot()
                        Text("Recording")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Elapsed time
            Text(workoutManager.formattedElapsedTime)
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            // Stats grid
            HStack(spacing: 20) {
                // Heart rate
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                        Text("\(workoutManager.currentHeartRate)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                    }
                    Text("bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 40)

                // Average HR
                VStack(spacing: 4) {
                    Text("\(workoutManager.averageHeartRate)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("avg bpm")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Distance (for outdoor workouts)
                if workoutManager.isTrackingLocation {
                    Divider()
                        .frame(height: 40)

                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .foregroundStyle(.blue)
                            Text(workoutManager.formattedDistance)
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                        }
                        if let pace = workoutManager.formattedPace {
                            Text(pace)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Map for GPS workouts
            if workoutManager.isTrackingLocation {
                WorkoutMapView(locationTracker: locationTracker)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            Spacer()

            // Stop button
            stopWorkoutButton
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Connection Status Card

    private var connectionStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: polarService.connectionState.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(polarService.connectionState.isConnected ? .green : .yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(polarService.connectionState.isConnected ? "Polar Connected" : "Polar Not Connected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if !polarService.connectionState.isConnected {
                    Text("Connect your Polar device to start workouts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let deviceName = settingsManager.polarDeviceName {
                    Text(deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if polarService.connectionState.isConnected, let battery = polarService.batteryLevel {
                Label("\(battery)%", systemImage: batteryIcon(for: battery))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Stop Button

    private var stopWorkoutButton: some View {
        Button {
            showStopConfirmation = true
        } label: {
            HStack {
                Image(systemName: "stop.fill")
                Text("Stop Workout")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(workoutManager.workoutState == .stopping)
    }

    // MARK: - Helpers

    private var canSelectWorkout: Bool {
        polarService.connectionState.isConnected
    }

    private func selectWorkout(_ workout: WorkoutType) {
        selectedWorkout = workout
    }

    private func startWorkout(_ workout: WorkoutType) {
        Task {
            do {
                try await workoutManager.startWorkout(type: workout)
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func saveWorkout() {
        Task {
            do {
                try await workoutManager.stopWorkout(healthKitManager: healthKitManager)
                selectedWorkout = nil
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    private func discardWorkout() {
        Task {
            await workoutManager.discardWorkout()
            selectedWorkout = nil
        }
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 75...100: return "battery.100"
        case 50..<75: return "battery.75"
        case 25..<50: return "battery.50"
        default: return "battery.25"
        }
    }
}

// MARK: - Quick Start Button

struct WorkoutQuickStartButton: View {
    let workout: WorkoutType
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: workout.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(isEnabled ? .primary : .secondary)

                Text(workout.name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isEnabled ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 80)
            .background(Color.white.opacity(isEnabled ? 0.1 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - All Workouts Sheet

struct AllWorkoutsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (WorkoutType) -> Void

    @State private var searchText = ""

    private var filteredCategories: [WorkoutCategory] {
        if searchText.isEmpty {
            return WorkoutCategory.allCases
        }
        return WorkoutCategory.allCases.filter { category in
            WorkoutType.workouts(in: category).contains { workout in
                workout.name.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    private func filteredWorkouts(in category: WorkoutCategory) -> [WorkoutType] {
        let workouts = WorkoutType.workouts(in: category)
        if searchText.isEmpty {
            return workouts
        }
        return workouts.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredCategories) { category in
                    Section(header: Text(category.rawValue)) {
                        ForEach(filteredWorkouts(in: category)) { workout in
                            Button {
                                dismiss()
                                onSelect(workout)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: workout.icon)
                                        .font(.title3)
                                        .foregroundStyle(.blue)
                                        .frame(width: 32)

                                    Text(workout.name)
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if workout.isOutdoor {
                                        Image(systemName: "location.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search workouts")
            .navigationTitle("All Workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Workout Map View

struct WorkoutMapView: View {
    @ObservedObject var locationTracker: LocationTracker

    @State private var mapCameraPosition: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $mapCameraPosition) {
            // Route polyline
            if locationTracker.routeLocations.count > 1 {
                MapPolyline(coordinates: locationTracker.routeLocations.map { $0.coordinate })
                    .stroke(.blue, lineWidth: 4)
            }

            // Current location marker
            if let currentLocation = locationTracker.currentLocation {
                Annotation("", coordinate: currentLocation.coordinate) {
                    ZStack {
                        Circle()
                            .fill(.blue.opacity(0.3))
                            .frame(width: 32, height: 32)
                        Circle()
                            .fill(.blue)
                            .frame(width: 14, height: 14)
                        Circle()
                            .stroke(.white, lineWidth: 2)
                            .frame(width: 14, height: 14)
                    }
                }
            }

            // Start location marker
            if let startLocation = locationTracker.routeLocations.first {
                Annotation("Start", coordinate: startLocation.coordinate) {
                    Image(systemName: "flag.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onChange(of: locationTracker.currentLocation) { _, newLocation in
            // Follow user location
            if let location = newLocation {
                withAnimation(.easeInOut(duration: 0.5)) {
                    mapCameraPosition = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        latitudinalMeters: 500,
                        longitudinalMeters: 500
                    ))
                }
            }
        }
    }
}

#Preview {
    WorkoutView(healthKitManager: HealthKitManager())
}
