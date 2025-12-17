import SwiftUI

@main
struct VigorWatchApp: App {
    @StateObject private var healthManager = WatchHealthManager()

    var body: some Scene {
        WindowGroup {
            ContentView(healthManager: healthManager)
                .task {
                    await healthManager.requestAuthorization()
                }
        }
    }
}
