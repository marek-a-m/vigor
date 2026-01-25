import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VigorScore.date, order: .reverse) private var allScores: [VigorScore]
    @State private var selectedTimeRange: TimeRange = .week
    @State private var selectedMetric: HistoryMetricType = .score

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

                Section {
                    MetricPicker(selectedMetric: $selectedMetric)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                if !filteredScores.isEmpty {
                    Section("Trend") {
                        MetricChartView(scores: chartData, metric: selectedMetric, timeRange: selectedTimeRange)
                            .frame(height: 200)
                            .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
                    }

                    Section("Statistics") {
                        MetricStatisticsView(scores: filteredScores, metric: selectedMetric)
                    }

                    Section("History") {
                        ForEach(filteredScores) { score in
                            MetricHistoryRow(score: score, metric: selectedMetric)
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

    private func deleteScores(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(filteredScores[index])
        }
    }
}

// MARK: - History Metric Type

enum HistoryMetricType: String, CaseIterable {
    case score = "Score"
    case sleep = "Sleep"
    case hrv = "HRV"
    case rhr = "RHR"
    case temperature = "Temp"

    var icon: String {
        switch self {
        case .score: return "gauge.with.needle"
        case .sleep: return "bed.double.fill"
        case .hrv: return "waveform.path.ecg"
        case .rhr: return "heart.fill"
        case .temperature: return "thermometer.medium"
        }
    }

    var color: Color {
        switch self {
        case .score: return .blue
        case .sleep: return .indigo
        case .hrv: return .green
        case .rhr: return .red
        case .temperature: return .orange
        }
    }

    var unit: String {
        switch self {
        case .score: return ""
        case .sleep: return "hrs"
        case .hrv: return "ms"
        case .rhr: return "bpm"
        case .temperature: return "°"
        }
    }

    var chartDomain: ClosedRange<Double>? {
        switch self {
        case .score: return 0...100
        case .sleep: return 0...12
        case .hrv: return nil
        case .rhr: return nil
        case .temperature: return nil
        }
    }

    func value(from score: VigorScore) -> Double? {
        switch self {
        case .score: return score.score
        case .sleep: return score.sleepHours
        case .hrv: return score.hrvValue
        case .rhr: return score.rhrValue
        case .temperature: return score.temperatureDeviation
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .score: return String(format: "%.0f", value)
        case .sleep: return String(format: "%.1f", value)
        case .hrv: return String(format: "%.0f", value)
        case .rhr: return String(format: "%.0f", value)
        case .temperature: return String(format: "%+.1f", value)
        }
    }

    func baseline(from score: VigorScore) -> Double? {
        switch self {
        case .hrv: return score.hrvBaseline
        case .rhr: return score.rhrBaseline
        default: return nil
        }
    }
}

// MARK: - Metric Picker

struct MetricPicker: View {
    @Binding var selectedMetric: HistoryMetricType

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryMetricType.allCases, id: \.self) { metric in
                    MetricButton(
                        metric: metric,
                        isSelected: selectedMetric == metric
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedMetric = metric
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }
}

struct MetricButton: View {
    let metric: HistoryMetricType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: metric.icon)
                    .font(.caption)
                Text(metric.rawValue)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? metric.color : Color(.systemGray5))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Metric Chart View

struct MetricChartView: View {
    let scores: [VigorScore]
    let metric: HistoryMetricType
    let timeRange: TimeRange

    private var validData: [(date: Date, value: Double)] {
        scores.compactMap { score in
            guard let value = metric.value(from: score) else { return nil }
            return (date: score.date, value: value)
        }
    }

    private var baselineValue: Double? {
        // Get baseline from most recent score
        scores.last.flatMap { metric.baseline(from: $0) }
    }

    private var xDomain: ClosedRange<Date> {
        let calendar = Calendar.current
        let now = Date()
        let endDate = calendar.startOfDay(for: now)

        let startDate: Date
        switch timeRange {
        case .week:
            startDate = calendar.date(byAdding: .day, value: -6, to: endDate)!
        case .month:
            startDate = calendar.date(byAdding: .month, value: -1, to: endDate)!
        case .threeMonths:
            startDate = calendar.date(byAdding: .month, value: -3, to: endDate)!
        }

        return startDate...now
    }

    private var yDomain: ClosedRange<Double> {
        if let domain = metric.chartDomain {
            return domain
        }
        var values = validData.map(\.value)
        // Include baseline in domain calculation so it's always visible
        if let baseline = baselineValue {
            values.append(baseline)
        }
        guard let min = values.min(), let max = values.max() else {
            return 0...100
        }
        let padding = (max - min) * 0.15
        return (min - padding)...(max + padding)
    }

    var body: some View {
        if validData.isEmpty {
            ContentUnavailableView(
                "No \(metric.rawValue) Data",
                systemImage: metric.icon,
                description: Text("No \(metric.rawValue.lowercased()) data available for this period.")
            )
        } else {
            Chart {
                // Data line and area
                ForEach(validData, id: \.date) { item in
                    LineMark(
                        x: .value("Date", item.date),
                        y: .value(metric.rawValue, item.value)
                    )
                    .foregroundStyle(metric.color.gradient)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Date", item.date),
                        y: .value(metric.rawValue, item.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [metric.color.opacity(0.3), metric.color.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Date", item.date),
                        y: .value(metric.rawValue, item.value)
                    )
                    .foregroundStyle(metric.color)
                }

                // Baseline reference line
                if let baseline = baselineValue {
                    RuleMark(y: .value("Baseline", baseline))
                        .foregroundStyle(.blue.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("baseline: \(metric.format(baseline))")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(4)
                        }
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text(metric.format(doubleValue))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
        }
    }
}

// MARK: - Metric Statistics View

struct MetricStatisticsView: View {
    let scores: [VigorScore]
    let metric: HistoryMetricType

    private var values: [Double] {
        scores.compactMap { metric.value(from: $0) }
    }

    private var average: Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var highest: Double? {
        values.max()
    }

    private var lowest: Double? {
        values.min()
    }

    private var dataCount: Int {
        values.count
    }

    private var currentBaseline: Double? {
        // Get baseline from most recent score
        scores.first.flatMap { metric.baseline(from: $0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let avg = average {
                    StatBox(
                        title: "Average",
                        value: metric.format(avg) + metric.unit,
                        color: metric.color
                    )
                }
                if let baseline = currentBaseline {
                    StatBox(
                        title: "Baseline",
                        value: metric.format(baseline) + metric.unit,
                        color: .blue
                    )
                }
                if let high = highest {
                    StatBox(
                        title: metric == .rhr ? "Lowest" : "Highest",
                        value: metric.format(metric == .rhr ? lowest! : high) + metric.unit,
                        color: .green
                    )
                }
                if let low = lowest {
                    StatBox(
                        title: metric == .rhr ? "Highest" : "Lowest",
                        value: metric.format(metric == .rhr ? highest! : low) + metric.unit,
                        color: .red
                    )
                }
            }
        }
    }
}

// MARK: - Metric History Row

struct MetricHistoryRow: View {
    let score: VigorScore
    let metric: HistoryMetricType

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(score.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline)

                if metric == .score && score.hasMissingData {
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

            if let value = metric.value(from: score) {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 2) {
                        Text(metric.format(value))
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundStyle(colorForValue(value))
                        Text(metric.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let baseline = metric.baseline(from: score) {
                        Text("baseline: \(metric.format(baseline))\(metric.unit)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("--")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func colorForValue(_ value: Double) -> Color {
        switch metric {
        case .score:
            switch value {
            case 67...100: return .green
            case 34..<67: return .yellow
            default: return .red
            }
        case .sleep:
            switch value {
            case 7...9: return .green
            case 6..<7, 9..<10: return .yellow
            default: return .red
            }
        case .hrv:
            return metric.color
        case .rhr:
            return metric.color
        case .temperature:
            let absValue = abs(value)
            if absValue < 0.3 { return .green }
            if absValue < 0.7 { return .yellow }
            return .red
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


enum TimeRange: String, CaseIterable {
    case week = "Week"
    case month = "Month"
    case threeMonths = "3 Months"
}

#Preview {
    HistoryView()
        .modelContainer(for: [VigorScore.self, DailyMetrics.self], inMemory: true)
}
