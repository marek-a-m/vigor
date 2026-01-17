import Foundation
import HealthKit

/// Service to fetch HRV data with WHOOP fallback
/// If no HRV from Apple Watch/other sources, converts WHOOP RMSSD → SDNN
@MainActor
final class WhoopHRVService: ObservableObject {
    static let shared = WhoopHRVService()

    private let healthStore = HKHealthStore()
    private let settingsManager = SettingsManager.shared

    @Published var lastHRVSource: HRVSource = .none
    @Published var lastHRVValue: Double?
    @Published var conversionInfo: String = ""

    enum HRVSource: String {
        case appleWatch = "Apple Watch"
        case whoop = "WHOOP (converted)"
        case other = "Other device"
        case none = "No data"
    }

    private init() {}

    // MARK: - Main HRV Fetch with Fallback

    /// Fetch HRV with WHOOP fallback if no other source available
    /// Returns SDNN value in milliseconds
    func fetchHRVWithWhoopFallback() async -> Double? {
        print("═══════════════════════════════════════════════════════")
        print("WhoopHRVService: Checking HRV sources...")
        print("═══════════════════════════════════════════════════════")

        // First, try to get HRV from Apple Health (non-WHOOP sources)
        let (hrvValue, source) = await fetchHRVFromHealthKit()

        if let hrv = hrvValue {
            lastHRVValue = hrv
            lastHRVSource = source
            conversionInfo = "HRV from \(source.rawValue): \(Int(hrv)) ms (SDNN)"
            print("  ✓ Found HRV from \(source.rawValue): \(Int(hrv)) ms (SDNN)")
            print("  → Using native HRV, no WHOOP fallback needed")
            print("═══════════════════════════════════════════════════════")
            return hrv
        }

        print("  ✗ No HRV from Apple Watch or other devices")

        // No HRV from other sources - try WHOOP fallback
        guard settingsManager.whoopIntegrationEnabled else {
            lastHRVSource = .none
            lastHRVValue = nil
            conversionInfo = "No HRV data available"
            print("  ✗ WHOOP integration disabled, cannot fallback")
            print("═══════════════════════════════════════════════════════")
            return nil
        }

        print("  → Trying WHOOP HRV fallback...")

        // Fetch WHOOP HRV (RMSSD) and convert
        if let whoopHRV = await fetchWhoopHRV() {
            let convertedSDNN = convertRMSSDtoSDNN(whoopHRV)
            lastHRVValue = convertedSDNN
            lastHRVSource = .whoop
            conversionInfo = "WHOOP RMSSD: \(Int(whoopHRV)) ms → SDNN: \(Int(convertedSDNN)) ms"
            print("  ✓ Got WHOOP HRV (RMSSD): \(Int(whoopHRV)) ms")
            print("  → Converted to SDNN: \(Int(convertedSDNN)) ms (×0.7)")
            print("═══════════════════════════════════════════════════════")
            return convertedSDNN
        }

        lastHRVSource = .none
        lastHRVValue = nil
        conversionInfo = "No HRV data available"
        print("  ✗ No WHOOP HRV data available either")
        print("═══════════════════════════════════════════════════════")
        return nil
    }

    // MARK: - HealthKit HRV (non-WHOOP sources)

    /// Fetch HRV from HealthKit, excluding WHOOP sources
    /// Returns (value, source) tuple
    private func fetchHRVFromHealthKit() async -> (Double?, HRVSource) {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return (nil, .none)
        }

        let calendar = Calendar.current
        let now = Date()
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!

        let predicate = HKQuery.predicateForSamples(
            withStart: startOfYesterday,
            end: now,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty, error == nil else {
                    print("  No HRV samples found in HealthKit (last 24h)")
                    continuation.resume(returning: (nil, .none))
                    return
                }

                // Debug: List all HRV sources found
                let sourceInfo = samples.map { sample -> String in
                    let name = sample.sourceRevision.source.name
                    let date = sample.endDate
                    let value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    return "\(name): \(Int(value))ms @ \(formatter.string(from: date))"
                }
                print("  HRV samples found (last 24h):")
                for info in sourceInfo.prefix(5) {
                    print("    • \(info)")
                }
                if sourceInfo.count > 5 {
                    print("    ... and \(sourceInfo.count - 5) more")
                }

                // Find the most recent non-WHOOP sample
                for sample in samples {
                    let sourceName = sample.sourceRevision.source.name.uppercased()
                    let bundleId = sample.sourceRevision.source.bundleIdentifier.lowercased()

                    // Skip WHOOP sources
                    if sourceName.contains("WHOOP") || bundleId.contains("whoop") {
                        continue
                    }

                    let value = sample.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                    let sampleDate = sample.endDate

                    // Determine source type
                    let source: HRVSource
                    if sourceName.contains("APPLE WATCH") || bundleId.contains("apple.health") {
                        source = .appleWatch
                    } else {
                        source = .other
                    }

                    // Show when this sample was recorded
                    let formatter = DateFormatter()
                    formatter.dateStyle = .short
                    formatter.timeStyle = .short
                    print("  Selected: \(sample.sourceRevision.source.name) @ \(formatter.string(from: sampleDate))")

                    continuation.resume(returning: (value, source))
                    return
                }

                // All samples were from WHOOP
                print("  All HRV samples were from WHOOP (skipped)")
                continuation.resume(returning: (nil, .none))
            }

            healthStore.execute(query)
        }
    }

    // MARK: - WHOOP HRV Fetch

    /// Fetch WHOOP HRV (RMSSD) from Apple Health or WHOOP API
    private func fetchWhoopHRV() async -> Double? {
        // First try to get from WHOOP recovery data stored in UserDefaults
        // (This would be populated by WhoopAPIService when syncing)
        if let cachedRMSSD = getCachedWhoopHRV() {
            return cachedRMSSD
        }

        // Try to fetch from WHOOP API if authenticated
        // Note: This requires the WhoopAPIService to be authenticated
        return await fetchWhoopHRVFromAPI()
    }

    /// Get cached WHOOP HRV from UserDefaults
    private func getCachedWhoopHRV() -> Double? {
        let defaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") ?? .standard
        let cachedValue = defaults.double(forKey: "whoopLastHRV_RMSSD")
        let cacheDate = defaults.object(forKey: "whoopLastHRV_Date") as? Date

        // Only use if cached within last 24 hours
        if cachedValue > 0, let date = cacheDate {
            let hoursSinceCache = Date().timeIntervalSince(date) / 3600
            if hoursSinceCache < 24 {
                print("WhoopHRVService: Using cached WHOOP HRV: \(Int(cachedValue)) ms (RMSSD)")
                return cachedValue
            }
        }

        return nil
    }

    /// Fetch WHOOP HRV from API (requires authentication)
    private func fetchWhoopHRVFromAPI() async -> Double? {
        // Check if WhoopAPIService is available and authenticated
        // This is a simplified check - in production you'd want proper dependency injection
        guard let whoopAPI = getWhoopAPIService(), whoopAPI.isAuthenticated else {
            print("WhoopHRVService: WHOOP API not authenticated")
            return nil
        }

        do {
            let calendar = Calendar.current
            let now = Date()
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

            let recoveries = try await whoopAPI.fetchRecovery(start: yesterday, end: now)

            if let latestRecovery = recoveries.first {
                let rmssd = latestRecovery.score.hrvRmssdMilli
                cacheWhoopHRV(rmssd)
                return rmssd
            }
        } catch {
            print("WhoopHRVService: Failed to fetch WHOOP HRV - \(error)")
        }

        return nil
    }

    /// Cache WHOOP HRV for later use
    private func cacheWhoopHRV(_ rmssd: Double) {
        let defaults = UserDefaults(suiteName: "group.cloud.buggygames.vigor") ?? .standard
        defaults.set(rmssd, forKey: "whoopLastHRV_RMSSD")
        defaults.set(Date(), forKey: "whoopLastHRV_Date")
    }

    /// Get WhoopAPIService instance (avoids circular dependency)
    private func getWhoopAPIService() -> WhoopAPIService? {
        return WhoopAPIService.shared
    }

    // MARK: - RMSSD to SDNN Conversion

    /// Convert RMSSD to SDNN (approximate)
    ///
    /// Research suggests SDNN ≈ RMSSD × 0.65 to 0.8 for overnight/resting measurements
    /// We use 0.7 as a middle-ground conversion factor
    ///
    /// References:
    /// - Shaffer & Ginsberg (2017): "An Overview of Heart Rate Variability Metrics and Norms"
    /// - During sleep, RMSSD and SDNN are more closely correlated
    ///
    /// - Parameter rmssd: RMSSD value in milliseconds
    /// - Returns: Approximate SDNN value in milliseconds
    func convertRMSSDtoSDNN(_ rmssd: Double) -> Double {
        // Conversion factor based on research
        // SDNN is typically 65-80% of RMSSD for overnight measurements
        let conversionFactor = 0.70

        let sdnn = rmssd * conversionFactor

        // Apply reasonable bounds (SDNN typically 20-200ms for healthy adults)
        return min(max(sdnn, 10), 250)
    }

    /// Convert SDNN to RMSSD (reverse conversion, for reference)
    func convertSDNNtoRMSSD(_ sdnn: Double) -> Double {
        return sdnn / 0.70
    }

    // MARK: - Debug Info

    /// Get detailed debug info about HRV sources
    func debugHRVSources() async -> String {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return "HRV type not available"
        }

        let calendar = Calendar.current
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -7, to: now)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: now,
            options: .strictStartDate
        )

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrvType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                guard let samples = samples as? [HKQuantitySample], error == nil else {
                    continuation.resume(returning: "Error fetching HRV samples")
                    return
                }

                // Group by source
                let sourceGroups = Dictionary(grouping: samples) { sample in
                    sample.sourceRevision.source.name
                }

                var result = "HRV Sources (last 7 days):\n"
                result += "═══════════════════════════════════════\n"

                for (source, sourceSamples) in sourceGroups.sorted(by: { $0.key < $1.key }) {
                    let avgHRV = sourceSamples.reduce(0.0) {
                        $0 + $1.quantity.doubleValue(for: HKUnit.secondUnit(with: .milli))
                    } / Double(sourceSamples.count)

                    result += "• \(source): \(sourceSamples.count) samples, avg \(Int(avgHRV)) ms\n"
                }

                result += "═══════════════════════════════════════"
                continuation.resume(returning: result)
            }

            healthStore.execute(query)
        }
    }
}

// MARK: - Integration with HealthKitManager

extension HealthKitManager {
    /// Fetch HRV with WHOOP fallback
    func fetchHRVWithFallback() async -> Double? {
        // First try native HRV fetch
        if let hrv = await fetchHRVData() {
            return hrv
        }

        // Fall back to WHOOP HRV service
        return await WhoopHRVService.shared.fetchHRVWithWhoopFallback()
    }
}
