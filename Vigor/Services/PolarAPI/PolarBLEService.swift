import Foundation
import PolarBleSdk
import RxSwift
import CoreBluetooth

// MARK: - Connection State

enum PolarConnectionState: Equatable {
    case disconnected
    case searching
    case connecting
    case connected(deviceId: String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

// MARK: - Discovered Device

struct PolarDiscoveredDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let rssi: Int

    var signalStrength: String {
        switch rssi {
        case -50...0: return "Excellent"
        case -60..<(-50): return "Good"
        case -70..<(-60): return "Fair"
        default: return "Weak"
        }
    }
}

// MARK: - Polar BLE Service

@MainActor
final class PolarBLEService: ObservableObject {
    static let shared = PolarBLEService()

    private var api: PolarBleApi!
    private let disposeBag = DisposeBag()
    private var searchDisposable: Disposable?

    @Published var connectionState: PolarConnectionState = .disconnected
    @Published var discoveredDevices: [PolarDiscoveredDevice] = []
    @Published var batteryLevel: Int?

    private let settingsManager = SettingsManager.shared

    private init() {
        setupPolarApi()
    }

    private func setupPolarApi() {
        api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_hr,
                .feature_polar_offline_recording,
                .feature_polar_device_time_setup,
                .feature_battery_info,
                .feature_polar_activity_data  // Includes sleep data, activity, and 24/7 samples
            ]
        )

        api.polarFilter(true)
        api.observer = self
        api.deviceInfoObserver = self
        api.logger = self
    }

    // MARK: - Device Search

    func startSearching() {
        guard connectionState != .searching else { return }

        connectionState = .searching
        discoveredDevices = []

        searchDisposable = api.searchForDevice()
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] deviceInfo in
                    self?.handleDiscoveredDevice(deviceInfo)
                },
                onError: { [weak self] error in
                    self?.connectionState = .error("Search failed: \(error.localizedDescription)")
                }
            )
    }

    func stopSearching() {
        searchDisposable?.dispose()
        searchDisposable = nil
        if case .searching = connectionState {
            connectionState = .disconnected
        }
    }

    private func handleDiscoveredDevice(_ info: PolarDeviceInfo) {
        let device = PolarDiscoveredDevice(
            id: info.deviceId,
            name: info.name,
            rssi: Int(info.rssi)
        )

        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    // MARK: - Connection Management

    func connect(to deviceId: String) {
        stopSearching()
        connectionState = .connecting

        do {
            try api.connectToDevice(deviceId)
        } catch {
            connectionState = .error("Failed to connect: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        guard let deviceId = settingsManager.polarDeviceId else { return }

        do {
            try api.disconnectFromDevice(deviceId)
        } catch {
            print("PolarBLE: Failed to disconnect - \(error)")
        }

        connectionState = .disconnected
        batteryLevel = nil
    }

    func autoReconnect() {
        guard settingsManager.polarIntegrationEnabled,
              let deviceId = settingsManager.polarDeviceId else {
            return
        }

        if !connectionState.isConnected {
            connect(to: deviceId)
        }
    }

    // MARK: - Device Info

    func getPairedDeviceInfo() -> (id: String, name: String)? {
        guard let id = settingsManager.polarDeviceId,
              let name = settingsManager.polarDeviceName else {
            return nil
        }
        return (id, name)
    }
}

// MARK: - PolarBleApiObserver

extension PolarBLEService: PolarBleApiObserver {
    nonisolated func deviceConnecting(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            connectionState = .connecting
        }
    }

    nonisolated func deviceConnected(_ identifier: PolarDeviceInfo) {
        Task { @MainActor in
            connectionState = .connected(deviceId: identifier.deviceId)

            // Save device info for auto-reconnect
            settingsManager.polarDeviceId = identifier.deviceId
            settingsManager.polarDeviceName = identifier.name

            print("PolarBLE: Connected to \(identifier.name) (\(identifier.deviceId))")

            // Clean up any stale device state from previous sessions
            // This fixes issues where app crash left device in sync/streaming mode
            await cleanupDeviceState(deviceId: identifier.deviceId)
        }
    }

    /// Send terminate notifications to ensure device is in clean state
    /// Prevents issues if previous app session crashed during sync or workout
    private func cleanupDeviceState(deviceId: String) async {
        print("PolarBLE: Cleaning up device state...")

        // Send terminate and stop sync notifications to reset device state
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            api.sendTerminateAndStopSyncNotifications(identifier: deviceId)
                .subscribe(
                    onCompleted: {
                        print("PolarBLE: Device state cleanup completed")
                        continuation.resume()
                    },
                    onError: { error in
                        // Ignore errors - device might not have been in sync mode
                        print("PolarBLE: Device state cleanup (expected if not in sync): \(error.localizedDescription)")
                        continuation.resume()
                    }
                )
                .disposed(by: disposeBag)
        }
    }

    nonisolated func deviceDisconnected(_ identifier: PolarDeviceInfo, pairingError: Bool) {
        Task { @MainActor in
            if pairingError {
                connectionState = .error("Pairing failed")
                settingsManager.clearPolarDevice()
            } else {
                connectionState = .disconnected
            }

            batteryLevel = nil
            print("PolarBLE: Disconnected from \(identifier.deviceId), pairing error: \(pairingError)")
        }
    }
}

// MARK: - PolarBleApiDeviceInfoObserver

extension PolarBLEService: PolarBleApiDeviceInfoObserver {
    nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        Task { @MainActor in
            self.batteryLevel = Int(batteryLevel)
            print("PolarBLE: Battery level \(batteryLevel)%")
        }
    }

    nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        print("PolarBLE: Device info - \(uuid.uuidString): \(value)")
    }

    nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        print("PolarBLE: Device info - \(key): \(value)")
    }

    nonisolated func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {
        print("PolarBLE: Charging status - \(chargingStatus)")
    }

    nonisolated func batteryPowerSourcesStateReceived(_ identifier: String, powerSourcesState: BleBasClient.PowerSourcesState) {
        print("PolarBLE: Power sources state - \(powerSourcesState)")
    }
}

// MARK: - PolarBleApiLogger

extension PolarBLEService: PolarBleApiLogger {
    nonisolated func message(_ str: String) {
        #if DEBUG
        print("PolarBLE SDK: \(str)")
        #endif
    }
}

// MARK: - Internal API Access

extension PolarBLEService {
    var polarApi: PolarBleApi {
        return api
    }
}

// MARK: - Background Reconnection

extension PolarBLEService {
    /// Attempt to reconnect to a known device with timeout (for background sync)
    /// - Parameters:
    ///   - deviceId: The device ID to connect to
    ///   - timeout: Maximum seconds to wait for connection
    /// - Returns: true if connected successfully, false otherwise
    func backgroundReconnect(deviceId: String, timeout: TimeInterval) async -> Bool {
        // Already connected
        if case .connected(let connectedId) = connectionState, connectedId == deviceId {
            return true
        }

        // Start connection attempt
        connect(to: deviceId)

        // Wait for connection with timeout
        let checkInterval: UInt64 = 500_000_000 // 0.5 seconds
        let maxChecks = Int(timeout * 2)

        for _ in 0..<maxChecks {
            if connectionState.isConnected {
                print("PolarBLE: Background reconnect successful")
                return true
            }

            // Check for error state
            if case .error = connectionState {
                print("PolarBLE: Background reconnect failed - error state")
                return false
            }

            try? await Task.sleep(nanoseconds: checkInterval)
        }

        print("PolarBLE: Background reconnect timed out after \(timeout)s")
        return false
    }
}
