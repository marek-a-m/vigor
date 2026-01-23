import Foundation

// MARK: - HRV Calculation Result

struct PolarHRVResult {
    let sdnn: Double
    let rmssd: Double
    let meanRR: Double
    let validIntervalCount: Int
    let totalIntervalCount: Int
    let calculationDate: Date

    var validRatio: Double {
        guard totalIntervalCount > 0 else { return 0 }
        return Double(validIntervalCount) / Double(totalIntervalCount)
    }

    var isReliable: Bool {
        return validIntervalCount >= 30 && validRatio >= 0.8
    }
}

// MARK: - Resting Heart Rate Result

struct PolarRHRResult {
    let restingHeartRate: Double
    let sampleCount: Int
    let measurementPeriod: DateInterval
}

// MARK: - Polar HRV Calculator

final class PolarHRVCalculator {
    static let shared = PolarHRVCalculator()

    private init() {}

    // MARK: - SDNN Calculation

    /// Calculate SDNN (Standard Deviation of NN intervals) from PP intervals
    /// - Parameters:
    ///   - intervals: Array of PP intervals from Polar device
    ///   - filterInvalid: Whether to filter out invalid intervals (skin contact, blocker)
    /// - Returns: HRV result with SDNN in milliseconds, or nil if insufficient data
    func calculateHRV(from intervals: [PolarPPInterval], filterInvalid: Bool = true) -> PolarHRVResult? {
        let validIntervals: [Int]

        if filterInvalid {
            validIntervals = intervals
                .filter { $0.isValid }
                .map { $0.intervalMs }
        } else {
            validIntervals = intervals
                .filter { $0.intervalMs >= 300 && $0.intervalMs <= 2000 }
                .map { $0.intervalMs }
        }

        guard validIntervals.count >= 30 else {
            print("PolarHRVCalculator: Insufficient valid intervals (\(validIntervals.count))")
            return nil
        }

        // Calculate SDNN
        let sdnn = calculateSDNN(from: validIntervals)

        // Calculate RMSSD
        let rmssd = calculateRMSSD(from: validIntervals)

        // Calculate mean RR
        let meanRR = Double(validIntervals.reduce(0, +)) / Double(validIntervals.count)

        return PolarHRVResult(
            sdnn: sdnn,
            rmssd: rmssd,
            meanRR: meanRR,
            validIntervalCount: validIntervals.count,
            totalIntervalCount: intervals.count,
            calculationDate: Date()
        )
    }

    /// Calculate SDNN from raw interval values in milliseconds
    /// - Parameter intervals: Array of RR intervals in milliseconds (must be pre-filtered)
    /// - Returns: SDNN in milliseconds
    func calculateSDNN(from intervals: [Int]) -> Double {
        guard !intervals.isEmpty else { return 0 }

        let mean = Double(intervals.reduce(0, +)) / Double(intervals.count)
        let squaredDifferences = intervals.map { pow(Double($0) - mean, 2) }
        let variance = squaredDifferences.reduce(0, +) / Double(intervals.count)

        return sqrt(variance)
    }

    /// Calculate RMSSD (Root Mean Square of Successive Differences)
    /// - Parameter intervals: Array of RR intervals in milliseconds
    /// - Returns: RMSSD in milliseconds
    func calculateRMSSD(from intervals: [Int]) -> Double {
        guard intervals.count >= 2 else { return 0 }

        var sumSquaredDiff: Double = 0
        for i in 1..<intervals.count {
            let diff = Double(intervals[i] - intervals[i - 1])
            sumSquaredDiff += diff * diff
        }

        let meanSquaredDiff = sumSquaredDiff / Double(intervals.count - 1)
        return sqrt(meanSquaredDiff)
    }

    // MARK: - Resting Heart Rate Calculation

    /// Calculate resting heart rate from HR samples during sleep
    /// Uses the lowest 5-minute rolling average during actual sleep periods
    /// - Parameters:
    ///   - samples: Array of heart rate samples
    ///   - sleepData: Array of sleep records from the device
    /// - Returns: Resting heart rate result, or nil if insufficient data
    func calculateSleepRestingHeartRate(
        from samples: [PolarHRSample],
        sleepData: [PolarSleepResult]
    ) -> PolarRHRResult? {
        // Filter samples to sleep periods if available
        var sleepSamples: [PolarHRSample] = []

        if let mostRecentSleep = sleepData.first {
            print("PolarHRVCalculator: Filtering HR samples to sleep period: \(mostRecentSleep.sleepStartTime) - \(mostRecentSleep.sleepEndTime)")

            sleepSamples = samples.filter { sample in
                sample.timestamp >= mostRecentSleep.sleepStartTime &&
                sample.timestamp <= mostRecentSleep.sleepEndTime
            }

            print("PolarHRVCalculator: Total HR samples: \(samples.count), During sleep: \(sleepSamples.count)")
        }

        // Fallback to nocturnal samples if no sleep data
        if sleepSamples.isEmpty {
            print("PolarHRVCalculator: No sleep data, falling back to nocturnal filtering (0-6 AM)")
            let calendar = Calendar.current
            sleepSamples = samples.filter { sample in
                let hour = calendar.component(.hour, from: sample.timestamp)
                return hour >= 0 && hour < 6
            }
            print("PolarHRVCalculator: Nocturnal HR samples: \(sleepSamples.count)")
        }

        // If still no samples, we can't calculate proper RHR
        if sleepSamples.isEmpty {
            print("PolarHRVCalculator: No sleep/nocturnal HR samples available for RHR calculation")
            return nil
        }

        return calculateRestingHeartRate(from: sleepSamples)
    }

    /// Calculate resting heart rate from HR samples using time-based sliding window
    /// Uses the lowest 5-minute rolling average
    /// - Parameters:
    ///   - samples: Array of heart rate samples (should be pre-filtered to sleep periods)
    ///   - windowDurationSeconds: Window duration for averaging (default 5 minutes = 300 seconds)
    /// - Returns: Resting heart rate result, or nil if insufficient data
    func calculateRestingHeartRate(
        from samples: [PolarHRSample],
        windowDurationSeconds: TimeInterval = 300
    ) -> PolarRHRResult? {
        guard samples.count >= 5 else {
            print("PolarHRVCalculator: Insufficient HR samples for RHR calculation (\(samples.count) samples)")
            return nil
        }

        // Sort samples by timestamp
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }

        guard let firstTimestamp = sortedSamples.first?.timestamp,
              let lastTimestamp = sortedSamples.last?.timestamp else {
            return nil
        }

        let totalDuration = lastTimestamp.timeIntervalSince(firstTimestamp)
        print("PolarHRVCalculator: HR data spans \(Int(totalDuration / 60)) minutes with \(sortedSamples.count) samples")

        // Calculate time-based sliding window averages
        var lowestAverage = Double.infinity
        var lowestWindowStart = firstTimestamp
        var lowestWindowSampleCount = 0

        // Slide the window across the data
        var windowStartIndex = 0
        for (endIndex, endSample) in sortedSamples.enumerated() {
            // Move window start forward until it's within the window duration
            while windowStartIndex < endIndex {
                let windowDuration = endSample.timestamp.timeIntervalSince(sortedSamples[windowStartIndex].timestamp)
                if windowDuration <= windowDurationSeconds {
                    break
                }
                windowStartIndex += 1
            }

            // Calculate average for this window
            let windowSamples = Array(sortedSamples[windowStartIndex...endIndex])
            let windowDuration = endSample.timestamp.timeIntervalSince(sortedSamples[windowStartIndex].timestamp)

            // Only consider windows that span at least 3 minutes (180 seconds) for meaningful average
            if windowDuration >= 180 && windowSamples.count >= 3 {
                let sum = windowSamples.reduce(0) { $0 + $1.heartRate }
                let average = Double(sum) / Double(windowSamples.count)

                // Filter out unrealistic RHR values (less than 30 or more than 100)
                if average >= 30 && average <= 100 && average < lowestAverage {
                    lowestAverage = average
                    lowestWindowStart = sortedSamples[windowStartIndex].timestamp
                    lowestWindowSampleCount = windowSamples.count
                }
            }
        }

        guard lowestAverage != .infinity else {
            print("PolarHRVCalculator: Could not find valid RHR window")
            return nil
        }

        print("PolarHRVCalculator: Found lowest RHR window: \(String(format: "%.1f", lowestAverage)) bpm at \(lowestWindowStart) (\(lowestWindowSampleCount) samples)")

        let measurementPeriod = DateInterval(
            start: firstTimestamp,
            end: lastTimestamp
        )

        return PolarRHRResult(
            restingHeartRate: lowestAverage,
            sampleCount: samples.count,
            measurementPeriod: measurementPeriod
        )
    }

    // MARK: - Sleep-Based HRV

    /// Calculate HRV from PP intervals during actual sleep periods
    /// Uses sleep data from the device for accurate filtering
    /// - Parameters:
    ///   - intervals: Array of PP intervals from Polar device
    ///   - sleepData: Array of sleep records from the device
    /// - Returns: HRV result with SDNN in milliseconds, or nil if insufficient data
    func calculateSleepHRV(from intervals: [PolarPPInterval], sleepData: [PolarSleepResult]) -> PolarHRVResult? {
        // If we have sleep data, use actual sleep periods
        if let mostRecentSleep = sleepData.first {
            print("PolarHRVCalculator: Using sleep data: \(mostRecentSleep.sleepStartTime) - \(mostRecentSleep.sleepEndTime)")

            // Filter intervals to those during sleep
            let sleepIntervals = intervals.filter { interval in
                interval.timestamp >= mostRecentSleep.sleepStartTime &&
                interval.timestamp <= mostRecentSleep.sleepEndTime
            }

            let validSleepIntervals = sleepIntervals.filter { $0.isValid }
            print("PolarHRVCalculator: Total intervals: \(intervals.count), During sleep: \(sleepIntervals.count), Valid: \(validSleepIntervals.count)")

            if !sleepIntervals.isEmpty {
                return calculateHRV(from: sleepIntervals)
            }
        }

        // Fallback to nocturnal estimation if no sleep data
        print("PolarHRVCalculator: No sleep data available, falling back to nocturnal estimation (0-6 AM)")
        return calculateNocturnalHRV(from: intervals)
    }

    // MARK: - Nocturnal HRV (Fallback)

    /// Calculate HRV from nocturnal PP intervals (between 12 AM and 6 AM)
    /// This is a fallback when no sleep data is available
    /// - Note: Returns nil if no nocturnal data available
    func calculateNocturnalHRV(from intervals: [PolarPPInterval]) -> PolarHRVResult? {
        let calendar = Calendar.current

        // Log time range of available intervals for debugging
        if let first = intervals.min(by: { $0.timestamp < $1.timestamp }),
           let last = intervals.max(by: { $0.timestamp < $1.timestamp }) {
            let firstHour = calendar.component(.hour, from: first.timestamp)
            let lastHour = calendar.component(.hour, from: last.timestamp)
            print("PolarHRVCalculator: PPI data time range: \(first.timestamp) (hour: \(firstHour)) to \(last.timestamp) (hour: \(lastHour))")
        }

        // Filter for nocturnal hours (12 AM - 6 AM) - estimated sleep period
        let nocturnalIntervals = intervals.filter { interval in
            let hour = calendar.component(.hour, from: interval.timestamp)
            return hour >= 0 && hour < 6
        }

        let validNocturnal = nocturnalIntervals.filter { $0.isValid }
        print("PolarHRVCalculator: Total intervals: \(intervals.count), Nocturnal (0-6 AM): \(nocturnalIntervals.count), Valid: \(validNocturnal.count)")

        guard !nocturnalIntervals.isEmpty else {
            print("PolarHRVCalculator: No nocturnal PP intervals found")
            print("PolarHRVCalculator: Make sure the device is worn during sleep")
            return nil
        }

        return calculateHRV(from: nocturnalIntervals)
    }

    // MARK: - Temperature Processing

    /// Result of temperature calculation with skin and estimated body temp
    struct TemperatureResult {
        let skinTemperature: Double
        let estimatedBodyTemperature: Double
        let sampleCount: Int
        let isValid: Bool

        /// The offset used to convert skin temp to body temp
        /// Based on research: wrist skin temp is typically 7-10°C below core temp during sleep
        static let skinToBodyOffset: Double = 8.5
    }

    /// Calculate sleep temperature from samples during actual sleep periods
    /// - Parameters:
    ///   - samples: Array of temperature samples
    ///   - sleepData: Array of sleep records from the device
    /// - Returns: Temperature result with both skin and estimated body temperature
    func calculateSleepTemperature(
        from samples: [PolarTemperatureSample],
        sleepData: [PolarSleepResult]
    ) -> TemperatureResult? {
        var sleepSamples: [PolarTemperatureSample] = []

        // Filter to sleep periods if available
        if let mostRecentSleep = sleepData.first {
            print("PolarHRVCalculator: Filtering temperature to sleep period: \(mostRecentSleep.sleepStartTime) - \(mostRecentSleep.sleepEndTime)")

            sleepSamples = samples.filter { sample in
                sample.timestamp >= mostRecentSleep.sleepStartTime &&
                sample.timestamp <= mostRecentSleep.sleepEndTime
            }

            print("PolarHRVCalculator: Total temp samples: \(samples.count), During sleep: \(sleepSamples.count)")
        }

        // Fallback to nocturnal samples
        if sleepSamples.isEmpty {
            let calendar = Calendar.current
            sleepSamples = samples.filter { sample in
                let hour = calendar.component(.hour, from: sample.timestamp)
                return hour >= 0 && hour < 6
            }
            print("PolarHRVCalculator: Using nocturnal temp samples: \(sleepSamples.count)")
        }

        // Final fallback to all samples
        if sleepSamples.isEmpty {
            sleepSamples = samples
        }

        guard !sleepSamples.isEmpty else { return nil }

        // Calculate average skin temperature
        let skinTemp = sleepSamples.reduce(0.0) { $0 + $1.temperature } / Double(sleepSamples.count)

        // Validate skin temperature is in reasonable range (20-38°C)
        // Typical wrist skin temp during sleep is 28-34°C
        let isValid = skinTemp >= 20 && skinTemp <= 38

        if !isValid {
            print("PolarHRVCalculator: Skin temperature \(skinTemp)°C is outside valid range (20-38°C)")
        }

        // Estimate body temperature from skin temperature
        // Research shows wrist skin temp is typically 7-10°C below core temp during sleep
        let estimatedBodyTemp = skinTemp + TemperatureResult.skinToBodyOffset

        print("PolarHRVCalculator: Skin temp: \(String(format: "%.2f", skinTemp))°C -> Estimated body temp: \(String(format: "%.2f", estimatedBodyTemp))°C")

        return TemperatureResult(
            skinTemperature: skinTemp,
            estimatedBodyTemperature: estimatedBodyTemp,
            sampleCount: sleepSamples.count,
            isValid: isValid
        )
    }

    /// Get the average skin temperature from samples (legacy method)
    func calculateAverageTemperature(from samples: [PolarTemperatureSample]) -> Double? {
        guard !samples.isEmpty else { return nil }

        let total = samples.reduce(0.0) { $0 + $1.temperature }
        return total / Double(samples.count)
    }

    /// Get nocturnal average temperature (legacy fallback)
    func calculateNocturnalTemperature(from samples: [PolarTemperatureSample]) -> Double? {
        let calendar = Calendar.current

        let nocturnalSamples = samples.filter { sample in
            let hour = calendar.component(.hour, from: sample.timestamp)
            return hour >= 0 && hour < 6
        }

        guard !nocturnalSamples.isEmpty else {
            return calculateAverageTemperature(from: samples)
        }

        return calculateAverageTemperature(from: nocturnalSamples)
    }
}
