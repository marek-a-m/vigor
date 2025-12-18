import Foundation
import WatchConnectivity

final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var receivedVigorScore: Double?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // Called from iOS app to send score to watch
    func sendVigorScore(_ score: Double, sleepScore: Double?, hrvScore: Double?, rhrScore: Double?, tempScore: Double?) {
        guard WCSession.default.activationState == .activated else { return }

        var context: [String: Any] = ["vigorScore": score, "timestamp": Date().timeIntervalSince1970]
        if let sleep = sleepScore { context["sleepScore"] = sleep }
        if let hrv = hrvScore { context["hrvScore"] = hrv }
        if let rhr = rhrScore { context["rhrScore"] = rhr }
        if let temp = tempScore { context["tempScore"] = temp }

        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            print("Failed to send context: \(error)")
        }
    }

    // Get cached vigor score (for watch)
    func getCachedVigorScore() -> Double? {
        let context = WCSession.default.receivedApplicationContext
        return context["vigorScore"] as? Double
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("WCSession activation failed: \(error)")
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        if let score = applicationContext["vigorScore"] as? Double {
            DispatchQueue.main.async {
                self.receivedVigorScore = score
                // Save to local storage for widgets
                let watchData = SharedVigorData(
                    score: score,
                    date: Date(),
                    sleepScore: applicationContext["sleepScore"] as? Double,
                    hrvScore: applicationContext["hrvScore"] as? Double,
                    rhrScore: applicationContext["rhrScore"] as? Double,
                    temperatureScore: applicationContext["tempScore"] as? Double,
                    missingMetrics: []
                )
                SharedDataManager.shared.saveLatestScore(watchData)
            }
        }
    }
}
