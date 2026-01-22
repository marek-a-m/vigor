import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var whoopService: WhoopStandService
    @ObservedObject var polarBLEService = PolarBLEService.shared
    @ObservedObject var polarSyncManager = PolarSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPolarPairing = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - WHOOP Integration
                Section {
                    Toggle(isOn: $settingsManager.whoopIntegrationEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "figure.walk")
                                .font(.title2)
                                .foregroundStyle(.blue)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("WHOOP Activity")
                                    .font(.body)
                                Text("Track hours with 100+ steps from WHOOP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onChange(of: settingsManager.whoopIntegrationEnabled) { _, enabled in
                        handleWhoopToggle(enabled: enabled)
                    }
                } header: {
                    Text("Integrations")
                } footer: {
                    if whoopService.isMonitoring {
                        Label("Monitoring WHOOP steps", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                // MARK: - Polar Integration
                Section {
                    Toggle(isOn: $settingsManager.polarIntegrationEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.title2)
                                .foregroundStyle(.red)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Polar Loop")
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
                    }
                } footer: {
                    if settingsManager.polarIntegrationEnabled {
                        polarStatusFooter
                    }
                }

                #if DEBUG
                Section {
                    if let available = whoopService.whoopStepsAvailable {
                        HStack {
                            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(available ? .green : .red)
                            Text(available ? "WHOOP steps found" : "No WHOOP steps")
                        }

                        if !whoopService.whoopStepsInfo.isEmpty {
                            Text(whoopService.whoopStepsInfo)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Checking for WHOOP step data...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let syncDate = whoopService.lastSyncedDate {
                        HStack {
                            Text("Last synced data")
                            Spacer()
                            Text(syncDate, style: .date)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Active hours")
                            Spacer()
                            Text("\(whoopService.lastSyncedActiveHours)")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No recent WHOOP step data")
                            .foregroundStyle(.secondary)
                    }

                    Button("Re-check WHOOP Steps") {
                        Task {
                            let (hasData, sources, totalSteps) = await whoopService.checkForWhoopStepData()
                            await MainActor.run {
                                whoopService.whoopStepsAvailable = hasData
                                if hasData {
                                    whoopService.whoopStepsInfo = "WHOOP steps found: \(Int(totalSteps)) from \(sources.joined(separator: ", "))"
                                } else {
                                    whoopService.whoopStepsInfo = "No WHOOP step data in Apple Health (last 30 days)"
                                }
                            }
                            await whoopService.refreshLastSyncedActiveHours()
                        }
                    }
                } header: {
                    Text("Steps Debug")
                } footer: {
                    Text("WHOOP syncs steps with ~2 day delay.")
                        .font(.caption)
                }

                Section {
                    HStack {
                        Text("HRV Source")
                        Spacer()
                        Text(WhoopHRVService.shared.lastHRVSource.rawValue)
                            .foregroundStyle(.secondary)
                    }

                    if let hrv = WhoopHRVService.shared.lastHRVValue {
                        HStack {
                            Text("HRV Value")
                            Spacer()
                            Text("\(Int(hrv)) ms (SDNN)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !WhoopHRVService.shared.conversionInfo.isEmpty {
                        Text(WhoopHRVService.shared.conversionInfo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Test HRV Fallback") {
                        Task {
                            let hrv = await WhoopHRVService.shared.fetchHRVWithWhoopFallback()
                            print("HRV Fallback result: \(hrv ?? -1) ms")
                        }
                    }
                } header: {
                    Text("HRV Debug")
                } footer: {
                    Text("If no Apple Watch HRV, converts WHOOP RMSSD → SDNN (×0.7)")
                        .font(.caption)
                }
                #endif
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

    private func handleWhoopToggle(enabled: Bool) {
        if enabled {
            Task {
                let authorized = await whoopService.requestAuthorization()
                if authorized {
                    whoopService.startMonitoring()
                }
            }
        } else {
            whoopService.stopMonitoring()
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
    private var polarStatusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let result = polarSyncManager.lastSyncResult {
                Label("Last sync: \(result.summary)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if case .failed(let error) = polarSyncManager.syncStatus {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
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
    SettingsView(
        settingsManager: SettingsManager.shared,
        whoopService: WhoopStandService.shared
    )
}
