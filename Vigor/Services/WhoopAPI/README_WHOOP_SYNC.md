# WHOOP to Apple Health Activity Ring Sync

This module syncs WHOOP data to Apple Health using a "Generosity Algorithm" that transforms WHOOP's cardiovascular-focused metrics to match Apple Watch's motion + heart rate based Activity Ring calculations.

## The Problem

WHOOP calculates calories/strain based purely on cardiovascular load, while Apple Watch calculates activity based on motion + heart rate. This results in:
- **Move Ring**: WHOOP reports fewer active calories (misses fidgeting, slow walks)
- **Exercise Ring**: WHOOP requires high strain; Apple counts any "brisk walk" intensity
- **Stand Ring**: WHOOP doesn't track standing at all

## The Solution: Generosity Algorithm

### Move Ring (Active Energy)

**Original**: WHOOP Active Calories (cardiovascular only)

**Transformed**:
```
Final Calories = (WHOOP Calories × Dynamic Multiplier) + Motion Bonus

Where:
- Dynamic Multiplier = 1.15 - 1.5x based on HR elevation throughout day
- Motion Bonus = ~8 cal/hour of waking time (simulates NEAT)
```

### Exercise Ring (Exercise Time)

**Original**: WHOOP only counts high-strain workouts

**Transformed**:
```
Exercise Minutes = Low Intensity × 0.5 + Moderate Intensity × 1.0 + High Intensity × 1.0

Where:
- Low Intensity: HR > 45% of max HR
- Moderate Intensity: HR > 55% of max HR
- High Intensity: HR > 75% of max HR
+ Workout bonus: 5-8 min per workout (Apple is generous with workout detection)
```

### Stand Ring (Stand Hours)

**Original**: WHOOP doesn't track standing

**Inferred**:
```
Stand Hour credited if ANY of:
1. HR spike > 10 BPM above resting for > 1 minute in that hour
2. Workout activity during that hour
3. Adjacent hours have activity (inferred movement)
```

## Configuration Presets

| Preset | Move Multiplier | Exercise Threshold | Stand Sensitivity |
|--------|-----------------|-------------------|-------------------|
| Conservative | 1.05-1.15x | 60% max HR | 12 BPM spike |
| Balanced | 1.15-1.30x | 55% max HR | 10 BPM spike |
| Generous | 1.25-1.50x | 50% max HR | 8 BPM spike |

## Required Permissions

### Info.plist Keys

```xml
<!-- HealthKit Read Access -->
<key>NSHealthShareUsageDescription</key>
<string>Vigor needs to read your health data to calculate your daily recovery score and sync activity metrics from WHOOP.</string>

<!-- HealthKit Write Access (REQUIRED for Activity Rings) -->
<key>NSHealthUpdateUsageDescription</key>
<string>Vigor writes activity data (calories, exercise minutes, stand hours) to fill your Activity Rings based on WHOOP data.</string>

<!-- OAuth Callback URL Scheme -->
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>vigor</string>
        </array>
        <key>CFBundleURLName</key>
        <string>WHOOP OAuth Callback</string>
    </dict>
</array>
```

### Entitlements

```xml
<!-- HealthKit capability -->
<key>com.apple.developer.healthkit</key>
<true/>

<key>com.apple.developer.healthkit.access</key>
<array/>

<!-- App Groups for data sharing -->
<key>com.apple.security.application-groups</key>
<array>
    <string>group.cloud.buggygames.vigor</string>
</array>
```

### HealthKit Types

**Read Types** (for conflict checking):
- `HKQuantityType.activeEnergyBurned`
- `HKQuantityType.appleExerciseTime`
- `HKCategoryType.appleStandHour`

**Write Types** (CRITICAL for Activity Rings):
- `HKQuantityType.activeEnergyBurned` → Move Ring
- `HKQuantityType.appleExerciseTime` → Exercise Ring
- `HKCategoryType.appleStandHour` → Stand Ring

## WHOOP API Setup

1. Register at https://developer.whoop.com
2. Create an app to get Client ID and Client Secret
3. Set Redirect URI to: `vigor://whoop/callback`
4. Request these scopes:
   - `read:profile`
   - `read:body_measurement`
   - `read:cycles`
   - `read:workout`
   - `read:sleep`
   - `read:recovery`

5. Update `WhoopAPIConfig` in `WhoopAPIService.swift`:
```swift
enum WhoopAPIConfig {
    static let clientId = "YOUR_CLIENT_ID"
    static let clientSecret = "YOUR_CLIENT_SECRET"
    // ...
}
```

## Source Priority Setup

For Vigor's data to take priority over WHOOP's native sync:

1. Open Apple Health app
2. Tap profile → Apps & Services
3. For each data type:
   - Tap the type → Data Sources & Access → Edit
   - Drag **Vigor** above **WHOOP**
4. Tap Done

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    WhoopActivityRingSyncManager                 │
│                    (Coordinates sync flow)                      │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│  WhoopAPIService │ │GenerosityAlgorithm│ │ActivityRingWriter│
│  (OAuth + Fetch) │ │  (Transform)     │ │ (Write HealthKit)│
└──────────────────┘ └──────────────────┘ └──────────────────┘
          │                   │                   │
          ▼                   ▼                   ▼
    WHOOP API          WhoopDailyPayload    Apple HealthKit
    (REST)             → AppleStyleMetrics   (Activity Rings)
```

## Files

| File | Purpose |
|------|---------|
| `WhoopModels.swift` | Data models for WHOOP API responses |
| `WhoopAPIService.swift` | OAuth 2.0 auth + API client |
| `GenerosityAlgorithm.swift` | Transform WHOOP → Apple metrics |
| `ActivityRingWriter.swift` | Write to HealthKit Activity Rings |
| `WhoopActivityRingSyncManager.swift` | Orchestrates the sync flow |

## Usage

```swift
// 1. Authenticate with WHOOP
let authURL = WhoopAPIService.shared.authorizationURL(state: UUID().uuidString)
// Present authURL in ASWebAuthenticationSession

// 2. Handle callback and exchange code
try await WhoopAPIService.shared.exchangeCodeForTokens(code: authCode)

// 3. Request HealthKit permissions
try await ActivityRingWriter.shared.requestAuthorization()

// 4. Sync today's data
try await WhoopActivityRingSyncManager.shared.syncToday()

// 5. Or enable auto-sync
WhoopActivityRingSyncManager.shared.startAutoSync()
```

## Debugging

The algorithm prints a detailed breakdown:

```
═══════════════════════════════════════════════════════════════
GENEROSITY ALGORITHM BREAKDOWN - 2025-01-16

🔴 MOVE RING (Active Calories)
───────────────────────────────────────────────────────────────
WHOOP Raw Calories:     312 kcal
Applied Multiplier:     1.23x
Motion Bonus (NEAT):    +128 kcal
───────────────────────────────────────────────────────────────
FINAL MOVE CALORIES:    512 kcal

🟢 EXERCISE RING (Minutes)
───────────────────────────────────────────────────────────────
WHOOP Workout Minutes:  45 min
Low Intensity:          22 min (weighted)
Moderate Intensity:     35 min
High Intensity:         12 min
───────────────────────────────────────────────────────────────
FINAL EXERCISE MINUTES: 58 min

🔵 STAND RING (Hours)
───────────────────────────────────────────────────────────────
Hours with HR Spike:    [7, 8, 10, 12, 14, 15, 17, 19]
Hours with Activity:    [9, 16, 18]
Inferred Movement:      [11, 13]
───────────────────────────────────────────────────────────────
FINAL STAND HOURS:      13/12 - [7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
═══════════════════════════════════════════════════════════════
```

## Limitations

1. **WHOOP API doesn't provide granular HR data** - We infer HR samples from workout data and simulate baseline patterns
2. **Stand Ring is estimated** - Without motion sensors, we use HR spikes and activity patterns
3. **Historical data limited** - WHOOP API returns ~7 days by default
4. **Rate limits** - WHOOP API has rate limits; sync includes delays

## Legal Note

This implementation is for personal use. Ensure compliance with:
- WHOOP API Terms of Service
- Apple HealthKit guidelines
- Local health data privacy regulations
