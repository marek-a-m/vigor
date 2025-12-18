import SwiftUI
import WatchConnectivity

@main
struct VigorWatchApp: App {
    @StateObject private var healthManager = WatchHealthManager()
    @StateObject private var connectivityManager = WatchConnectivityManager.shared

    init() {
        // Initialize WatchConnectivity
        _ = WatchConnectivityManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(healthManager: healthManager)
                .task {
                    await healthManager.requestAuthorization()
                }
        }
    }
}
