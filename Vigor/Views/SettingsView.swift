import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @ObservedObject var whoopService: WhoopStandService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
}

#Preview {
    SettingsView(
        settingsManager: SettingsManager.shared,
        whoopService: WhoopStandService.shared
    )
}
