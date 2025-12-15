import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var healthManager = HealthKitManager()
    @State private var currentScore: VigorScore?
    @State private var isCalculating = false

    private let calculator = VigorCalculator()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if !healthManager.isAuthorized {
                        authorizationCard
                    } else if healthManager.isLoading || isCalculating {
                        loadingView
                    } else if let score = currentScore {
                        scoreCard(score)
                        metricsBreakdown(score)
                        if score.hasMissingData {
                            missingDataWarning(score)
                        }
                    } else {
                        noDataView
                    }
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Image("Banner")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 32)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshData() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(!healthManager.isAuthorized || healthManager.isLoading)
                }
            }
        }
        .task {
            await healthManager.requestAuthorization()
            await calculateScore()
        }
    }

    private var authorizationCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 60))
                .foregroundStyle(.red)

            Text("Health Access Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Vigor needs access to your health data to calculate your recovery score.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Grant Access") {
                Task { await healthManager.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Calculating your Vigor Index...")
                .foregroundStyle(.secondary)
        }
        .frame(height: 300)
    }

    private var noDataView: some View {
        VStack(spacing: 16) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("No Data Available")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Make sure you have sleep and health data recorded in Apple Health.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func scoreCard(_ score: VigorScore) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(
                        Color.gray.opacity(0.2),
                        lineWidth: 20
                    )

                Circle()
                    .trim(from: 0, to: score.score / 100)
                    .stroke(
                        scoreColor(score.score),
                        style: StrokeStyle(lineWidth: 20, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 1), value: score.score)

                VStack(spacing: 4) {
                    Text("\(Int(score.score))")
                        .font(.system(size: 64, weight: .bold, design: .rounded))

                    Text(score.scoreCategory.rawValue)
                        .font(.headline)
                        .foregroundStyle(scoreColor(score.score))
                }
            }
            .frame(width: 200, height: 200)

            Text(score.scoreCategory.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Last updated: \(score.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func metricsBreakdown(_ score: VigorScore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Breakdown")
                .font(.headline)

            if let sleepScore = score.sleepScore {
                MetricRow(
                    icon: "bed.double.fill",
                    title: "Sleep",
                    value: score.sleepHours.map { String(format: "%.1f hrs", $0) } ?? "-",
                    score: sleepScore,
                    weight: "30%"
                )
            }

            if let hrvScore = score.hrvScore {
                MetricRow(
                    icon: "waveform.path.ecg",
                    title: "HRV",
                    value: score.hrvValue.map { String(format: "%.0f ms", $0) } ?? "-",
                    score: hrvScore,
                    weight: "30%"
                )
            }

            if let rhrScore = score.rhrScore {
                MetricRow(
                    icon: "heart.fill",
                    title: "Resting HR",
                    value: score.rhrValue.map { String(format: "%.0f bpm", $0) } ?? "-",
                    score: rhrScore,
                    weight: "25%"
                )
            }

            if let tempScore = score.temperatureScore {
                MetricRow(
                    icon: "thermometer.medium",
                    title: "Temperature",
                    value: score.temperatureDeviation.map { String(format: "%+.1f°C", $0) } ?? "-",
                    score: tempScore,
                    weight: "15%"
                )
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func missingDataWarning(_ score: VigorScore) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text("Partial Score")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Missing: \(score.missingMetrics.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func scoreColor(_ score: Double) -> Color {
        switch score {
        case 67...100: return .green
        case 34..<67: return .yellow
        default: return .red
        }
    }

    private func refreshData() async {
        await healthManager.fetchAllMetrics()
        await calculateScore()
    }

    private func calculateScore() async {
        isCalculating = true
        defer { isCalculating = false }

        let score = calculator.calculate(from: healthManager.metrics)

        if score.score > 0 || !score.missingMetrics.isEmpty {
            currentScore = score
            modelContext.insert(score)
            try? modelContext.save()

            let sharedData = SharedVigorData(
                score: score.score,
                date: score.date,
                sleepScore: score.sleepScore,
                hrvScore: score.hrvScore,
                rhrScore: score.rhrScore,
                temperatureScore: score.temperatureScore,
                missingMetrics: score.missingMetrics
            )
            SharedDataManager.shared.saveLatestScore(sharedData)
        }
    }
}

struct MetricRow: View {
    let icon: String
    let title: String
    let value: String
    let score: Double
    let weight: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(score))")
                    .font(.headline)
                    .foregroundStyle(scoreColor(score))
                Text(weight)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
}

#Preview {
    DashboardView()
        .modelContainer(for: VigorScore.self, inMemory: true)
}
