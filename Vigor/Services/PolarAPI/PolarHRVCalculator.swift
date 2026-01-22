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

    /// Calculate resting heart rate from HR samples
    /// Uses the lowest 5-minute average during sleep/rest periods
    /// - Parameters:
    ///   - samples: Array of heart rate samples
    ///   - windowMinutes: Window size for averaging (default 5 minutes)
    /// - Returns: Resting heart rate result, or nil if insufficient data
    func calculateRestingHeartRate(
        from samples: [PolarHRSample],
        windowMinutes: Int = 5
    ) -> PolarRHRResult? {
        guard samples.count >= windowMinutes else {
            print("PolarHRVCalculator: Insufficient HR samples for RHR calculation")
            return nil
        }

        // Sort samples by timestamp
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }

        // Calculate sliding window averages
        var lowestAverage = Double.infinity
        var lowestWindowStart = sortedSamples.first!.timestamp

        for i in 0...(sortedSamples.count - windowMinutes) {
            let windowSamples = Array(sortedSamples[i..<(i + windowMinutes)])
            let average = Double(windowSamples.map { $0.heartRate }.reduce(0, +)) / Double(windowMinutes)

            if average < lowestAverage {
                lowestAverage = average
                lowestWindowStart = windowSamples.first!.timestamp
            }
        }

        guard lowestAverage != .infinity else { return nil }

        let measurementPeriod = DateInterval(
            start: sortedSamples.first!.timestamp,
            end: sortedSamples.last!.timestamp
        )

        return PolarRHRResult(
            restingHeartRate: lowestAverage,
            sampleCount: samples.count,
            measurementPeriod: measurementPeriod
        )
    }

    // MARK: - Nocturnal HRV

    /// Calculate HRV from nocturnal PP intervals (between 12 AM and 6 AM)
    /// This is the most accurate period for HRV measurement during sleep
    /// - Note: Returns nil if no nocturnal data available (HRV should only be from sleep)
    func calculateNocturnalHRV(from intervals: [PolarPPInterval]) -> PolarHRVResult? {
        let calendar = Calendar.current

        // Log time range of available intervals for debugging
        if let first = intervals.min(by: { $0.timestamp < $1.timestamp }),
           let last = intervals.max(by: { $0.timestamp < $1.timestamp }) {
            let firstHour = calendar.component(.hour, from: first.timestamp)
            let lastHour = calendar.component(.hour, from: last.timestamp)
            print("PolarHRVCalculator: PPI data time range: \(first.timestamp) (hour: \(firstHour)) to \(last.timestamp) (hour: \(lastHour))")
        }

        // Filter for nocturnal hours (12 AM - 6 AM) - sleep period
        let nocturnalIntervals = intervals.filter { interval in
            let hour = calendar.component(.hour, from: interval.timestamp)
            return hour >= 0 && hour < 6
        }

        let validNocturnal = nocturnalIntervals.filter { $0.isValid }
        print("PolarHRVCalculator: Total intervals: \(intervals.count), Nocturnal: \(nocturnalIntervals.count), Valid nocturnal: \(validNocturnal.count)")

        guard !nocturnalIntervals.isEmpty else {
            print("PolarHRVCalculator: No nocturnal PP intervals found - HRV requires sleep data")
            print("PolarHRVCalculator: Make sure the device is worn during sleep (12 AM - 6 AM)")
            return nil
        }

        return calculateHRV(from: nocturnalIntervals)
    }

    // MARK: - Temperature Processing

    /// Get the average skin temperature from samples
    func calculateAverageTemperature(from samples: [PolarTemperatureSample]) -> Double? {
        guard !samples.isEmpty else { return nil }

        let total = samples.reduce(0.0) { $0 + $1.temperature }
        return total / Double(samples.count)
    }

    /// Get nocturnal average temperature (most stable measurement)
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
