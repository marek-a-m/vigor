import WidgetKit
import SwiftUI

// MARK: - Shared Data

struct WatchWidgetData {
    let score: Double
    let heartRate: Int?
    let steps: Int?
    let date: Date

    static let placeholder = WatchWidgetData(score: 75, heartRate: 72, steps: 8500, date: Date())
}

// MARK: - Timeline Provider

struct WatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchWidgetEntry {
        WatchWidgetEntry(date: Date(), data: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        let entry = WatchWidgetEntry(date: Date(), data: loadData())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        let entry = WatchWidgetEntry(date: Date(), data: loadData())
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 1, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadData() -> WatchWidgetData {
        let vigorData = SharedDataManager.shared.loadLatestScore()
        let watchData = SharedDataManager.shared.loadWatchData()

        return WatchWidgetData(
            score: vigorData?.score ?? 0,
            heartRate: watchData?.heartRate,
            steps: watchData?.steps,
            date: Date()
        )
    }
}

struct WatchWidgetEntry: TimelineEntry {
    let date: Date
    let data: WatchWidgetData
}

// MARK: - Large Rectangular Widget (Score, Steps, HR)

struct LargeRectangularView: View {
    let data: WatchWidgetData

    var body: some View {
        HStack(spacing: 8) {
            // Score circle
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 4)

                Circle()
                    .trim(from: 0, to: data.score / 100)
                    .stroke(scoreColor(data.score), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                Text("\(Int(data.score))")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                // Heart Rate
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                    Text(data.heartRate.map { "\($0)" } ?? "--")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }

                // Steps
                HStack(spacing: 4) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text(data.steps.map { formatSteps($0) } ?? "--")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
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

    private func formatSteps(_ steps: Int) -> String {
        if steps >= 1000 {
            return String(format: "%.1fK", Double(steps) / 1000)
        }
        return "\(steps)"
    }
}

// MARK: - Circular HR Widget

struct CircularHRView: View {
    let heartRate: Int?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            VStack(spacing: 0) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)

                Text(heartRate.map { "\($0)" } ?? "--")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
        }
    }
}

// MARK: - Circular Steps Widget

struct CircularStepsView: View {
    let steps: Int?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()

            VStack(spacing: 0) {
                Image(systemName: "figure.walk")
                    .font(.system(size: 12))
                    .foregroundColor(.green)

                Text(steps.map { formatSteps($0) } ?? "--")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
        }
    }

    private func formatSteps(_ steps: Int) -> String {
        if steps >= 1000 {
            return String(format: "%.1fK", Double(steps) / 1000)
        }
        return "\(steps)"
    }
}

// MARK: - Corner Widget (HR + Steps)

struct CornerView: View {
    let data: WatchWidgetData

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "heart.fill")
                .foregroundColor(.red)
            Text(data.heartRate.map { "\($0)" } ?? "--")

            Text("•")
                .foregroundColor(.gray)

            Image(systemName: "figure.walk")
                .foregroundColor(.green)
            Text(data.steps.map { formatSteps($0) } ?? "--")
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .widgetLabel {
            Text("Vigor")
        }
    }

    private func formatSteps(_ steps: Int) -> String {
        if steps >= 1000 {
            return String(format: "%.0fK", Double(steps) / 1000)
        }
        return "\(steps)"
    }
}

// MARK: - Widgets

struct VigorLargeWidget: Widget {
    let kind = "VigorLargeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            LargeRectangularView(data: entry.data)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Vigor Dashboard")
        .description("Score, heart rate, and steps")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct VigorHRWidget: Widget {
    let kind = "VigorHRWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            CircularHRView(heartRate: entry.data.heartRate)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Heart Rate")
        .description("Current heart rate")
        .supportedFamilies([.accessoryCircular])
    }
}

struct VigorStepsWidget: Widget {
    let kind = "VigorStepsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            CircularStepsView(steps: entry.data.steps)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Steps")
        .description("Steps today")
        .supportedFamilies([.accessoryCircular])
    }
}

struct VigorCornerWidget: Widget {
    let kind = "VigorCornerWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            CornerView(data: entry.data)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("HR & Steps")
        .description("Heart rate and steps")
        .supportedFamilies([.accessoryCorner])
    }
}

// MARK: - Widget Bundle

@main
struct VigorWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        VigorLargeWidget()
        VigorHRWidget()
        VigorStepsWidget()
        VigorCornerWidget()
    }
}
