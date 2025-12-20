import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct VigorWatchApp: App {
    @WKApplicationDelegateAdaptor(ExtensionDelegate.self) var delegate

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
