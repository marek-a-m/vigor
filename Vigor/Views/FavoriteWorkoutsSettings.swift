import SwiftUI

struct FavoriteWorkoutsSettings: View {
    @ObservedObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    private let maxFavorites = 8

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select up to \(maxFavorites) favorites for quick start on the Workout tab.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ForEach(WorkoutCategory.allCases) { category in
                    Section(header: Text(category.rawValue)) {
                        ForEach(WorkoutType.workouts(in: category)) { workout in
                            WorkoutToggleRow(
                                workout: workout,
                                isSelected: settingsManager.favoriteWorkoutIds.contains(workout.id),
                                canSelect: canSelectMore || settingsManager.favoriteWorkoutIds.contains(workout.id)
                            ) { isSelected in
                                toggleFavorite(workout: workout, isSelected: isSelected)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Favorite Workouts")
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

    private var canSelectMore: Bool {
        settingsManager.favoriteWorkoutIds.count < maxFavorites
    }

    private func toggleFavorite(workout: WorkoutType, isSelected: Bool) {
        if isSelected {
            if !settingsManager.favoriteWorkoutIds.contains(workout.id) && canSelectMore {
                settingsManager.favoriteWorkoutIds.append(workout.id)
            }
        } else {
            settingsManager.favoriteWorkoutIds.removeAll { $0 == workout.id }
        }
    }
}

struct WorkoutToggleRow: View {
    let workout: WorkoutType
    let isSelected: Bool
    let canSelect: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button {
            if canSelect || isSelected {
                onToggle(!isSelected)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: workout.icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 32)

                Text(workout.name)
                    .foregroundStyle(canSelect || isSelected ? .primary : .secondary)

                Spacer()

                if workout.isOutdoor {
                    Image(systemName: "location.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.5))
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.blue : (canSelect ? Color.secondary : Color.gray.opacity(0.5)))
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    FavoriteWorkoutsSettings(settingsManager: SettingsManager.shared)
}
