# Vigor

iOS app that calculates a "Vigor Index" (0-100) recovery score from Apple Health data, similar to Whoop Recovery or Garmin Body Battery.

## Build

```bash
xcodegen generate  # Generate Xcode project from project.yml
open Vigor.xcodeproj
```

## Project Structure

- `project.yml` - XcodeGen configuration (source of truth for project settings)
- `Vigor/` - Main iOS app
  - `VigorApp.swift` - App entry point with SwiftData container
  - `ContentView.swift` - Tab view (Dashboard + History)
  - `Views/DashboardView.swift` - Main score display with circular gauge
  - `Views/HistoryView.swift` - Charts and historical data
  - `Models/VigorScore.swift` - SwiftData model for persistence
  - `Models/HealthMetrics.swift` - Health data struct
  - `Services/HealthKitManager.swift` - HealthKit queries for sleep, HRV, RHR, temperature
  - `Services/VigorCalculator.swift` - Scoring algorithm
- `VigorWidget/` - WidgetKit extension (small + medium widgets)
- `Shared/SharedDataManager.swift` - App Group data sharing between app and widget

## Algorithm

Vigor Index (0-100) is calculated from weighted metrics:
- **Sleep** (30%): Duration vs 7-9 hour optimal range
- **HRV** (30%): Compared to personal 30-day baseline
- **Resting HR** (25%): Compared to baseline (lower is better)
- **Temperature** (15%): Deviation from baseline

Missing metrics are handled by redistributing weights among available data.

## Key Technologies

- SwiftUI, SwiftData, HealthKit, WidgetKit, Swift Charts
- App Groups for widget data sharing
- iOS 17.0+ deployment target
