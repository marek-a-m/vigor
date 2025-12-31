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
