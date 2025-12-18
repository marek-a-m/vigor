import SwiftUI
import SwiftData
import WatchConnectivity

@main
struct VigorApp: App {
    let modelContainer: ModelContainer

    init() {
        // Initialize WatchConnectivity
        _ = WatchConnectivityManager.shared

        let schema = Schema([VigorScore.self, DailyMetrics.self])

        // Try CloudKit first, fall back to local storage if it fails
        do {
            let cloudConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private("iCloud.cloud.buggygames.vigor")
            )
            modelContainer = try ModelContainer(for: schema, configurations: [cloudConfig])
        } catch {
            print("CloudKit initialization failed: \(error). Falling back to local storage.")
            do {
                let localConfig = ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: false,
                    cloudKitDatabase: .none
                )
                modelContainer = try ModelContainer(for: schema, configurations: [localConfig])
            } catch {
                fatalError("Could not initialize ModelContainer: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
