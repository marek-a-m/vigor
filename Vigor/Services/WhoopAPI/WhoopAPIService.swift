import Foundation
import AuthenticationServices

// MARK: - WHOOP API Configuration

enum WhoopAPIConfig {
    static let clientId = "YOUR_WHOOP_CLIENT_ID"
    static let clientSecret = "YOUR_WHOOP_CLIENT_SECRET"
    static let redirectUri = "vigor://whoop/callback"
    static let baseURL = "https://api.prod.whoop.com/developer"
    static let authURL = "https://api.prod.whoop.com/oauth/oauth2/auth"
    static let tokenURL = "https://api.prod.whoop.com/oauth/oauth2/token"

    // Required scopes for our use case
    static let scopes = [
        "read:profile",
        "read:body_measurement",
        "read:cycles",
        "read:workout",
        "read:sleep",
        "read:recovery"
    ]
}

// MARK: - API Errors

enum WhoopAPIError: LocalizedError {
    case notAuthenticated
    case tokenExpired
    case invalidResponse
    case networkError(Error)
    case apiError(statusCode: Int, message: String)
    case decodingError(Error)
    case rateLimited(retryAfter: Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with WHOOP"
        case .tokenExpired:
            return "WHOOP token expired"
        case .invalidResponse:
            return "Invalid response from WHOOP API"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let code, let message):
            return "WHOOP API error (\(code)): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .rateLimited(let retryAfter):
            return "Rate limited. Retry after \(retryAfter) seconds"
        }
    }
}

// MARK: - WHOOP API Service

@MainActor
final class WhoopAPIService: ObservableObject {
    static let shared = WhoopAPIService()

    @Published var isAuthenticated = false
    @Published var userProfile: WhoopUserProfile?
    @Published var bodyMeasurement: WhoopBodyMeasurement?

    private let urlSession: URLSession
    private let keychain = WhoopKeychainManager.shared
    private let jsonDecoder: JSONDecoder

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)

        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.dateDecodingStrategy = .iso8601

        // Check if we have stored credentials
        if let credentials = keychain.loadCredentials() {
            isAuthenticated = !credentials.isExpired
        }
    }

    // MARK: - OAuth 2.0 Authentication

    /// Generate the OAuth authorization URL
    func authorizationURL(state: String) -> URL? {
        var components = URLComponents(string: WhoopAPIConfig.authURL)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: WhoopAPIConfig.clientId),
            URLQueryItem(name: "redirect_uri", value: WhoopAPIConfig.redirectUri),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: WhoopAPIConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    /// Exchange authorization code for tokens
    func exchangeCodeForTokens(code: String) async throws {
        var request = URLRequest(url: URL(string: WhoopAPIConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": WhoopAPIConfig.redirectUri,
            "client_id": WhoopAPIConfig.clientId,
            "client_secret": WhoopAPIConfig.clientSecret
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhoopAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw WhoopAPIError.apiError(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }

        let tokenResponse = try jsonDecoder.decode(WhoopTokenResponse.self, from: data)
        let credentials = WhoopCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )

        keychain.saveCredentials(credentials)
        isAuthenticated = true

        // Fetch user profile after authentication
        await fetchUserProfile()
    }

    /// Refresh access token using refresh token
    func refreshTokens() async throws {
        guard let credentials = keychain.loadCredentials() else {
            throw WhoopAPIError.notAuthenticated
        }

        var request = URLRequest(url: URL(string: WhoopAPIConfig.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": WhoopAPIConfig.clientId,
            "client_secret": WhoopAPIConfig.clientSecret
        ]

        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhoopAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            // If refresh fails, clear credentials and require re-auth
            logout()
            throw WhoopAPIError.tokenExpired
        }

        let tokenResponse = try jsonDecoder.decode(WhoopTokenResponse.self, from: data)
        let newCredentials = WhoopCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )

        keychain.saveCredentials(newCredentials)
        isAuthenticated = true
    }

    /// Log out and clear credentials
    func logout() {
        keychain.deleteCredentials()
        isAuthenticated = false
        userProfile = nil
        bodyMeasurement = nil
    }

    // MARK: - API Requests

    private func authenticatedRequest(for endpoint: String, queryItems: [URLQueryItem]? = nil) async throws -> URLRequest {
        guard var credentials = keychain.loadCredentials() else {
            throw WhoopAPIError.notAuthenticated
        }

        // Refresh token if expired
        if credentials.isExpired {
            try await refreshTokens()
            credentials = keychain.loadCredentials()!
        }

        var components = URLComponents(string: "\(WhoopAPIConfig.baseURL)\(endpoint)")!
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return request
    }

    private func fetch<T: Codable>(_ type: T.Type, endpoint: String, queryItems: [URLQueryItem]? = nil) async throws -> T {
        let request = try await authenticatedRequest(for: endpoint, queryItems: queryItems)

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhoopAPIError.invalidResponse
        }

        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            let retryAfter = Int(httpResponse.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60
            throw WhoopAPIError.rateLimited(retryAfter: retryAfter)
        }

        guard httpResponse.statusCode == 200 else {
            throw WhoopAPIError.apiError(
                statusCode: httpResponse.statusCode,
                message: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }

        do {
            return try jsonDecoder.decode(T.self, from: data)
        } catch {
            throw WhoopAPIError.decodingError(error)
        }
    }

    // MARK: - User Data

    func fetchUserProfile() async {
        do {
            userProfile = try await fetch(WhoopUserProfile.self, endpoint: "/v1/user/profile/basic")
        } catch {
            print("WhoopAPI: Failed to fetch profile - \(error)")
        }
    }

    func fetchBodyMeasurement() async throws -> WhoopBodyMeasurement {
        let measurement = try await fetch(WhoopBodyMeasurement.self, endpoint: "/v1/user/measurement/body")
        bodyMeasurement = measurement
        return measurement
    }

    // MARK: - Cycles (Strain)

    func fetchCycles(start: Date, end: Date) async throws -> [WhoopCycle] {
        let formatter = ISO8601DateFormatter()
        let queryItems = [
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end))
        ]

        let response = try await fetch(
            WhoopPaginatedResponse<WhoopCycle>.self,
            endpoint: "/v1/cycle",
            queryItems: queryItems
        )

        return response.records
    }

    // MARK: - Workouts

    func fetchWorkouts(start: Date, end: Date) async throws -> [WhoopWorkout] {
        let formatter = ISO8601DateFormatter()
        let queryItems = [
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end))
        ]

        let response = try await fetch(
            WhoopPaginatedResponse<WhoopWorkout>.self,
            endpoint: "/v1/activity/workout",
            queryItems: queryItems
        )

        return response.records
    }

    // MARK: - Sleep

    func fetchSleep(start: Date, end: Date) async throws -> [WhoopSleep] {
        let formatter = ISO8601DateFormatter()
        let queryItems = [
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end))
        ]

        let response = try await fetch(
            WhoopPaginatedResponse<WhoopSleep>.self,
            endpoint: "/v1/activity/sleep",
            queryItems: queryItems
        )

        return response.records
    }

    // MARK: - Recovery

    func fetchRecovery(start: Date, end: Date) async throws -> [WhoopRecovery] {
        let formatter = ISO8601DateFormatter()
        let queryItems = [
            URLQueryItem(name: "start", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end))
        ]

        let response = try await fetch(
            WhoopPaginatedResponse<WhoopRecovery>.self,
            endpoint: "/v1/recovery",
            queryItems: queryItems
        )

        return response.records
    }

    // MARK: - Aggregated Daily Data

    /// Fetch all WHOOP data for a single day
    func fetchDailyPayload(for date: Date) async throws -> WhoopDailyPayload {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)!

        // Fetch body measurement for max HR
        let body = try await fetchBodyMeasurement()

        // Fetch all data types in parallel
        async let cyclesTask = fetchCycles(start: startOfDay, end: endOfDay)
        async let workoutsTask = fetchWorkouts(start: startOfDay, end: endOfDay)
        async let sleepTask = fetchSleep(start: startOfDay, end: endOfDay)
        async let recoveryTask = fetchRecovery(start: startOfDay, end: endOfDay)

        let (cycles, workouts, sleep, recoveries) = try await (
            cyclesTask, workoutsTask, sleepTask, recoveryTask
        )

        // Get recovery for today (most recent)
        let recovery = recoveries.first

        // Get resting HR from recovery, or use default
        let restingHR = recovery?.score.restingHeartRate ?? 60.0

        // Note: WHOOP API doesn't provide granular HR data via API
        // We'll need to generate inferred HR samples from workout/cycle data
        let hrSamples = generateInferredHeartRateSamples(
            cycles: cycles,
            workouts: workouts,
            restingHR: restingHR,
            date: startOfDay
        )

        return WhoopDailyPayload(
            date: startOfDay,
            restingHeartRate: restingHR,
            maxHeartRate: body.maxHeartRate,
            heartRateSamples: hrSamples,
            cycles: cycles,
            workouts: workouts,
            sleep: sleep,
            recovery: recovery
        )
    }

    /// Generate inferred HR samples from available workout data
    /// Since WHOOP API doesn't expose granular HR, we simulate based on known workout times and intensities
    private func generateInferredHeartRateSamples(
        cycles: [WhoopCycle],
        workouts: [WhoopWorkout],
        restingHR: Double,
        date: Date
    ) -> [WhoopHeartRateSample] {
        var samples: [WhoopHeartRateSample] = []
        let calendar = Calendar.current

        // Generate baseline samples every 15 minutes during waking hours (6 AM - 10 PM)
        for hour in 6..<22 {
            for minute in stride(from: 0, to: 60, by: 15) {
                if let sampleTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) {
                    // Baseline is slightly above resting HR during day
                    let baselineHR = Int(restingHR * 1.1)
                    samples.append(WhoopHeartRateSample(time: sampleTime, bpm: baselineHR))
                }
            }
        }

        // Override with workout data where available
        for workout in workouts {
            guard let score = workout.score else { continue }

            let workoutStart = workout.start
            let workoutEnd = workout.end
            var current = workoutStart

            while current < workoutEnd {
                // Use average HR for workout samples
                samples.append(WhoopHeartRateSample(time: current, bpm: score.averageHeartRate))
                current = current.addingTimeInterval(60) // 1-minute intervals
            }
        }

        // Sort by time and remove duplicates (workouts override baseline)
        let uniqueSamples = Dictionary(grouping: samples) { sample in
            calendar.dateComponents([.hour, .minute], from: sample.time)
        }.compactMap { $0.value.max(by: { $0.bpm < $1.bpm }) }

        return uniqueSamples.sorted { $0.time < $1.time }
    }
}

// MARK: - Keychain Manager for Credentials

final class WhoopKeychainManager {
    static let shared = WhoopKeychainManager()
    private let service = "com.vigor.whoop"
    private let account = "credentials"

    private init() {}

    func saveCredentials(_ credentials: WhoopCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        var newItem = query
        newItem[kSecValueData as String] = data

        SecItemAdd(newItem as CFDictionary, nil)
    }

    func loadCredentials() -> WhoopCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(WhoopCredentials.self, from: data) else {
            return nil
        }

        return credentials
    }

    func deleteCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
