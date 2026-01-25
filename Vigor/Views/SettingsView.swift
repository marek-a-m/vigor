import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var polarBLEService = PolarBLEService.shared
    @ObservedObject var polarSyncManager = PolarSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPolarPairing = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Polar Integration
                Section {
                    Toggle(isOn: $settingsManager.polarIntegrationEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Polar Device")
                                    .font(.body)
                                Text("Sync HRV, HR, and temperature via BLE")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onChange(of: settingsManager.polarIntegrationEnabled) { _, enabled in
                        handlePolarToggle(enabled: enabled)
                    }

                    // Device status
                    if settingsManager.polarIntegrationEnabled {
                        polarDeviceRow

                        // Background sync toggle
                        Toggle(isOn: $settingsManager.polarBackgroundSyncEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic Sync")
                                    .font(.body)
                                Text("Sync data automatically in background")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(settingsManager.polarDeviceId == nil)
                    }
                } header: {
                    Text("Integrations")
                } footer: {
                    if settingsManager.polarIntegrationEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            if settingsManager.polarBackgroundSyncEnabled {
                                Label("Morning sync (6-9 AM) + hourly updates", systemImage: "clock.arrow.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            polarStatusFooterContent
                        }
                    }
                }

                // MARK: - Workout Settings
                Section {
                    NavigationLink {
                        FavoriteWorkoutsSettings(settingsManager: settingsManager)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "star.fill")
                                .font(.title2)
                                .foregroundStyle(.yellow)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Favorite Workouts")
                                    .font(.body)
                                Text("\(settingsManager.favoriteWorkoutIds.count) selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Workouts")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPolarPairing) {
                PolarPairingView()
            }
        }
    }

    private func handlePolarToggle(enabled: Bool) {
        if enabled {
            // Show pairing view if no device paired
            if settingsManager.polarDeviceId == nil {
                showPolarPairing = true
            } else {
                // Auto-reconnect to existing device
                polarBLEService.autoReconnect()
            }
        } else {
            polarBLEService.disconnect()
        }
    }

    // MARK: - Polar Views

    @ViewBuilder
    private var polarDeviceRow: some View {
        if let deviceName = settingsManager.polarDeviceName {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceName)
                        .font(.body)
                    Text(polarConnectionStatusText)
                        .font(.caption)
                        .foregroundStyle(polarConnectionStatusColor)
                }

                Spacer()

                if polarBLEService.connectionState.isConnected {
                    if let battery = polarBLEService.batteryLevel {
                        Label("\(battery)%", systemImage: batteryIcon(for: battery))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(action: { showPolarPairing = true }) {
                    Text("Change")
                        .font(.caption)
                }
            }

            // Sync button
            Button(action: {
                Task {
                    await polarSyncManager.performSync()
                }
            }) {
                HStack {
                    if polarSyncManager.syncStatus.isInProgress {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(polarSyncManager.syncStatus.description)
                            .font(.subheadline)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Sync Now")
                    }
                }
            }
            .disabled(!polarBLEService.connectionState.isConnected || polarSyncManager.syncStatus.isInProgress)
        } else {
            Button(action: { showPolarPairing = true }) {
                HStack {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.blue)
                    Text("Pair Polar Device")
                }
            }
        }
    }

    @ViewBuilder
    private var polarStatusFooterContent: some View {
        if let syncDate = polarSyncManager.lastSyncDate {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Last sync: \(syncDate, format: .relative(presentation: .named))")
                if let result = polarSyncManager.lastSyncResult {
                    Text("(\(result.summary))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }

        if case .failed(let error) = polarSyncManager.syncStatus {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var polarConnectionStatusText: String {
        switch polarBLEService.connectionState {
        case .disconnected:
            return "Disconnected"
        case .searching:
            return "Searching..."
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private var polarConnectionStatusColor: Color {
        switch polarBLEService.connectionState {
        case .connected:
            return .green
        case .connecting, .searching:
            return .orange
        case .error:
            return .red
        default:
            return .secondary
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

#Preview {
    SettingsView(settingsManager: SettingsManager.shared)
}
