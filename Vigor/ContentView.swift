import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("Today", systemImage: "heart.circle.fill")
                }
                .tag(0)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "chart.line.uptrend.xyaxis")
                }
                .tag(1)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: VigorScore.self, inMemory: true)
}
