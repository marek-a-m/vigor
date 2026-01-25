import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var healthKitManager = HealthKitManager()
    @ObservedObject private var polarBLEService = PolarBLEService.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var workoutManager = PolarWorkoutManager.shared
    @State private var syncManager: SyncManager?
    @State private var selectedTab = 0
    @State private var showSyncOverlay = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView(syncManager: syncManager, healthKitManager: healthKitManager)
                .tabItem {
                    Label("Today", systemImage: "heart.circle.fill")
                }
                .tag(0)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(1)

            if settingsManager.polarIntegrationEnabled {
                WorkoutView(healthKitManager: healthKitManager)
                    .tabItem {
                        Label("Workout", systemImage: "figure.run")
                    }
                    .tag(2)
            }
        }
        .toolbar(workoutManager.workoutState.isActive ? .hidden : .visible, for: .tabBar)
        .overlay {
            if showSyncOverlay, let syncManager {
                SyncOverlay(progress: syncManager.syncProgress)
            }
        }
        .task {
            // Initialize sync manager
            if syncManager == nil {
                syncManager = SyncManager(healthKitManager: healthKitManager, modelContext: modelContext)
            }

            // Request authorization
            await healthKitManager.requestAuthorization()

            guard healthKitManager.isAuthorized, let syncManager else { return }

            // Only show overlay for initial sync (not incremental)
            let isInitialSync = !syncManager.isInitialSyncCompleted
            if isInitialSync {
                showSyncOverlay = true
            }

            // Perform sync with timeout
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await syncManager.performSync()
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 60 second timeout
                }
                // Wait for first to complete
                await group.next()
                group.cancelAll()
            }

            showSyncOverlay = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .polarSyncCompleted)) { _ in
            // Refresh Vigor score when Polar sync completes with new data
            Task {
                print("ContentView: Polar sync completed, refreshing Vigor score...")
                await syncManager?.performSync()
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .active {
                // Auto-reconnect to Polar when app becomes active
                if SettingsManager.shared.polarIntegrationEnabled {
                    polarBLEService.autoReconnect()

                    // Check if we should sync (never synced or last sync > 30 min ago)
                    let lastSync = SyncStateManager.shared.lastSuccessfulSyncTime
                    let shouldSync = lastSync == nil || Date().timeIntervalSince(lastSync!) > 30 * 60

                    if shouldSync {
                        Task {
                            // Wait a moment for BLE connection to establish
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            print("ContentView: Auto-syncing Polar data on foreground")
                            await PolarSyncManager.shared.performSync()
                        }
                    }
                }
            }
        }
    }
}

struct SyncOverlay: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress) {
                Text("Syncing Health Data...")
                    .font(.headline)
            }
            .progressViewStyle(.linear)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(40)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [VigorScore.self, DailyMetrics.self], inMemory: true)
}
