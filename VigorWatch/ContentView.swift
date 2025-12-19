import SwiftUI

struct ContentView: View {
    @ObservedObject var healthManager: WatchHealthManager
    @State private var vigorData: SharedVigorData?

    private let backgroundColor = Color(red: 0.118, green: 0.129, blue: 0.165)

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Vigor Score
                vigorScoreView

                // Health Metrics
                metricsGrid
            }
            .padding(.horizontal, 8)
        }
        .background(backgroundColor.ignoresSafeArea())
        .onAppear {
            loadVigorScore()
        }
        .refreshable {
            await refreshData()
        }
    }

    private var vigorScoreView: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 8)

                Circle()
                    .trim(from: 0, to: (vigorData?.score ?? 0) / 100)
                    .stroke(
                        scoreColor(vigorData?.score ?? 0),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(Int(vigorData?.score ?? 0))")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text("VIGOR")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 90, height: 90)
        }
    }

    private var metricsGrid: some View {
        VStack(spacing: 8) {
            // Heart Rate
            MetricRow(
                icon: "heart.fill",
                iconColor: .red,
                title: "Heart Rate",
                value: healthManager.currentHeartRate.map { "\(Int($0))" } ?? "--",
                unit: "BPM"
            )

            // Steps
            MetricRow(
                icon: "figure.walk",
                iconColor: .green,
                title: "Steps",
                value: healthManager.stepsToday.map { formatNumber($0) } ?? "--",
                unit: ""
            )

            // Floors
            if let floors = healthManager.floorsClimbed, floors > 0 {
                MetricRow(
                    icon: "stairs",
                    iconColor: .orange,
                    title: "Floors",
                    value: "\(floors)",
                    unit: ""
                )
            }

            // Live monitoring toggle
            Button {
                if healthManager.isMonitoring {
                    healthManager.stopMonitoring()
                } else {
                    healthManager.startMonitoring()
                }
            } label: {
                HStack {
                    Image(systemName: healthManager.isMonitoring ? "heart.circle.fill" : "heart.circle")
                        .foregroundColor(healthManager.isMonitoring ? .green : .gray)
                    Text(healthManager.isMonitoring ? "Live" : "Start Live HR")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(healthManager.isMonitoring ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 67...100: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }

    private func formatNumber(_ number: Int) -> String {
        if number >= 1000 {
            return String(format: "%.1fK", Double(number) / 1000)
        }
        return "\(number)"
    }

    private func loadVigorScore() {
        vigorData = SharedDataManager.shared.loadLatestScore()
    }

    private func refreshData() async {
        await healthManager.fetchAllData()
        loadVigorScore()
    }
}

struct MetricRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)

                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.1))
        .cornerRadius(10)
    }
}

#Preview {
    ContentView(healthManager: WatchHealthManager())
}
