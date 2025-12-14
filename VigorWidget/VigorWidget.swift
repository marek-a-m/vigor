import WidgetKit
import SwiftUI

struct VigorEntry: TimelineEntry {
    let date: Date
    let data: SharedVigorData?
}

struct VigorProvider: TimelineProvider {
    func placeholder(in context: Context) -> VigorEntry {
        VigorEntry(date: Date(), data: SharedVigorData(
            score: 75,
            date: Date(),
            sleepScore: 80,
            hrvScore: 70,
            rhrScore: 75,
            temperatureScore: 85,
            missingMetrics: []
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (VigorEntry) -> Void) {
        let entry = VigorEntry(
            date: Date(),
            data: SharedDataManager.shared.loadLatestScore()
        )
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VigorEntry>) -> Void) {
        let entry = VigorEntry(
            date: Date(),
            data: SharedDataManager.shared.loadLatestScore()
        )

        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct VigorWidgetEntryView: View {
    var entry: VigorProvider.Entry
    @Environment(\.widgetFamily) var widgetFamily

    var body: some View {
        switch widgetFamily {
        case .systemSmall:
            SmallWidgetView(data: entry.data)
        case .systemMedium:
            MediumWidgetView(data: entry.data)
        default:
            SmallWidgetView(data: entry.data)
        }
    }
}

struct SmallWidgetView: View {
    let data: SharedVigorData?

    var body: some View {
        if let data = data {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 8)

                    Circle()
                        .trim(from: 0, to: data.score / 100)
                        .stroke(
                            scoreColor(data.score),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text("\(Int(data.score))")
                            .font(.system(size: 32, weight: .bold, design: .rounded))

                        if data.hasMissingData {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .frame(width: 80, height: 80)

                Text(data.scoreCategory)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(scoreColor(data.score))
            }
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "heart.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Open Vigor")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(.fill.tertiary, for: .widget)
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

struct MediumWidgetView: View {
    let data: SharedVigorData?

    var body: some View {
        if let data = data {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.2), lineWidth: 10)

                    Circle()
                        .trim(from: 0, to: data.score / 100)
                        .stroke(
                            scoreColor(data.score),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 0) {
                        Text("\(Int(data.score))")
                            .font(.system(size: 36, weight: .bold, design: .rounded))

                        if data.hasMissingData {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
                .frame(width: 90, height: 90)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Vigor Index")
                        .font(.headline)

                    Text(data.scoreCategory)
                        .font(.subheadline)
                        .foregroundStyle(scoreColor(data.score))

                    Divider()

                    HStack(spacing: 12) {
                        if let sleep = data.sleepScore {
                            MetricPill(icon: "bed.double.fill", value: Int(sleep))
                        }
                        if let hrv = data.hrvScore {
                            MetricPill(icon: "waveform.path.ecg", value: Int(hrv))
                        }
                        if let rhr = data.rhrScore {
                            MetricPill(icon: "heart.fill", value: Int(rhr))
                        }
                    }

                    Text(data.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
        } else {
            HStack {
                Image(systemName: "heart.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading) {
                    Text("Vigor Index")
                        .font(.headline)
                    Text("Open app to calculate")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .containerBackground(.fill.tertiary, for: .widget)
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

struct MetricPill: View {
    let icon: String
    let value: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
            Text("\(value)")
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundStyle(.secondary)
    }
}

@main
struct VigorWidgetBundle: WidgetBundle {
    var body: some Widget {
        VigorWidget()
    }
}

struct VigorWidget: Widget {
    let kind: String = "VigorWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: VigorProvider()) { entry in
            VigorWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Vigor Index")
        .description("View your daily recovery score at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#Preview(as: .systemSmall) {
    VigorWidget()
} timeline: {
    VigorEntry(date: Date(), data: SharedVigorData(
        score: 75,
        date: Date(),
        sleepScore: 80,
        hrvScore: 70,
        rhrScore: 75,
        temperatureScore: 85,
        missingMetrics: []
    ))
}

#Preview(as: .systemMedium) {
    VigorWidget()
} timeline: {
    VigorEntry(date: Date(), data: SharedVigorData(
        score: 82,
        date: Date(),
        sleepScore: 85,
        hrvScore: 78,
        rhrScore: 80,
        temperatureScore: 90,
        missingMetrics: []
    ))
}
