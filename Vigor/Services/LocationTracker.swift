import Foundation
import CoreLocation

/// Manages GPS location tracking for outdoor workouts
@MainActor
final class LocationTracker: NSObject, ObservableObject {
    static let shared = LocationTracker()

    @Published var isTracking = false
    @Published var currentLocation: CLLocation?
    @Published var routeLocations: [CLLocation] = []
    @Published var totalDistance: Double = 0  // meters
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentSpeed: Double = 0  // m/s
    @Published var averageSpeed: Double = 0  // m/s

    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var trackingStartTime: Date?

    override private init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 5  // meters
        locationManager.activityType = .fitness
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Authorization

    func requestAuthorization() {
        switch authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Request always authorization for background tracking
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    var isAuthorizedForTracking: Bool {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    // MARK: - Tracking Control

    func startTracking() {
        guard isAuthorizedForTracking else {
            print("LocationTracker: Not authorized for location tracking")
            return
        }

        guard !isTracking else { return }

        isTracking = true
        routeLocations = []
        totalDistance = 0
        currentSpeed = 0
        averageSpeed = 0
        lastLocation = nil
        trackingStartTime = Date()

        locationManager.startUpdatingLocation()
        print("LocationTracker: Started tracking")
    }

    func stopTracking() -> [CLLocation] {
        guard isTracking else { return [] }

        locationManager.stopUpdatingLocation()
        isTracking = false

        let capturedRoute = routeLocations
        print("LocationTracker: Stopped tracking. \(capturedRoute.count) points, \(String(format: "%.0f", totalDistance))m")

        // Reset state
        routeLocations = []
        currentLocation = nil
        lastLocation = nil
        trackingStartTime = nil

        return capturedRoute
    }

    // MARK: - Distance Formatting

    var formattedDistance: String {
        if totalDistance >= 1000 {
            return String(format: "%.2f km", totalDistance / 1000)
        } else {
            return String(format: "%.0f m", totalDistance)
        }
    }

    var formattedPace: String? {
        guard averageSpeed > 0 else { return nil }

        // Pace in minutes per kilometer
        let paceSecondsPerKm = 1000 / averageSpeed
        let minutes = Int(paceSecondsPerKm) / 60
        let seconds = Int(paceSecondsPerKm) % 60

        return String(format: "%d:%02d /km", minutes, seconds)
    }

    var formattedSpeed: String {
        // Speed in km/h
        let speedKmh = currentSpeed * 3.6
        return String(format: "%.1f km/h", speedKmh)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for location in locations {
                // Filter out inaccurate locations
                guard location.horizontalAccuracy >= 0 && location.horizontalAccuracy < 50 else {
                    continue
                }

                currentLocation = location
                currentSpeed = max(0, location.speed)

                if let last = lastLocation {
                    let distance = location.distance(from: last)
                    // Only count if movement is reasonable (filter GPS noise)
                    if distance > 2 && distance < 100 {
                        totalDistance += distance
                    }
                }

                routeLocations.append(location)
                lastLocation = location

                // Calculate average speed
                if let startTime = trackingStartTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0 {
                        averageSpeed = totalDistance / elapsed
                    }
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            print("LocationTracker: Authorization changed to \(authorizationStatus.rawValue)")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationTracker: Error - \(error.localizedDescription)")
    }
}
