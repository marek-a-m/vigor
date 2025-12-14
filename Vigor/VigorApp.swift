import SwiftUI
import SwiftData

@main
struct VigorApp: App {
    let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema([VigorScore.self])
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .identifier("group.com.vigor.shared")
            )
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
