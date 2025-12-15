import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VigorScore.date, order: .reverse) private var allScores: [VigorScore]
    @State private var selectedTimeRange: TimeRange = .week

    private var filteredScores: [VigorScore] {
        let calendar = Calendar.current
        let now = Date()

        let startDate: Date
        switch selectedTimeRange {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -7, to: now)!
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: now)!
        case .threeMonths:
            startDate = calendar.date(byAdding: .month, value: -3, to: now)!
        }

        return allScores.filter { $0.date >= startDate }
    }

    private var chartData: [VigorScore] {
        filteredScores.reversed()
    }

    private var averageScore: Double {
        guard !filteredScores.isEmpty else { return 0 }
        return filteredScores.reduce(0) { $0 + $1.score } / Double(filteredScores.count)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Time Range", selection: $selectedTimeRange) {
                        ForEach(TimeRange.allCases, id: \.self) { range in
                            Text(range.rawValue).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if !filteredScores.isEmpty {
                    Section("Trend") {
                        chartView
                            .frame(height: 200)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    }

                    Section("Statistics") {
                        statisticsView
                    }

                    Section("History") {
                        ForEach(filteredScores) { score in
                            HistoryRow(score: score)
                        }
                        .onDelete(perform: deleteScores)
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "No History",
                            systemImage: "chart.line.uptrend.xyaxis",
                            description: Text("Your vigor scores will appear here once calculated.")
                        )
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private var chartView: some View {
        Chart(chartData) { score in
            LineMark(
                x: .value("Date", score.date),
                y: .value("Score", score.score)
            )
            .foregroundStyle(Color.blue.gradient)
            .interpolationMethod(.catmullRom)

            AreaMark(
                x: .value("Date", score.date),
                y: .value("Score", score.score)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .interpolationMethod(.catmullRom)

            PointMark(
                x: .value("Date", score.date),
                y: .value("Score", score.score)
            )
            .foregroundStyle(scoreColor(score.score))
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 33, 67, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let intValue = value.as(Int.self) {
                        Text("\(intValue)")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
    }

    private var statisticsView: some View {
        VStack(spacing: 12) {
            HStack {
                StatBox(title: "Average", value: String(format: "%.0f", averageScore), color: scoreColor(averageScore))
                StatBox(title: "Highest", value: String(format: "%.0f", filteredScores.map(\.score).max() ?? 0), color: .green)
                StatBox(title: "Lowest", value: String(format: "%.0f", filteredScores.map(\.score).min() ?? 0), color: .red)
                StatBox(title: "Entries", value: "\(filteredScores.count)", color: .blue)
            }
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 67...100: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }

    private func deleteScores(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredScores[index])
        }
    }
}

struct StatBox: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct HistoryRow: View {
    let score: VigorScore

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(score.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)

                if score.hasMissingData {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text("Partial data")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text("\(Int(score.score))")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(scoreColor(score.score))
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 67...100: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }
}

enum TimeRange: String, CaseIterable {
    case week = "Week"
    case month = "Month"
    case threeMonths = "3 Months"
}

#Preview {
    HistoryView()
        .modelContainer(for: [VigorScore.self, DailyMetrics.self], inMemory: true)
}
