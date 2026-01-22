import SwiftUI

struct PolarPairingView: View {
    @ObservedObject var bleService = PolarBLEService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with search status
                searchStatusHeader

                // Device list or empty state
                if bleService.discoveredDevices.isEmpty && isSearching {
                    searchingView
                } else if bleService.discoveredDevices.isEmpty {
                    emptyStateView
                } else {
                    deviceListView
                }
            }
            .navigationTitle("Pair Polar Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        bleService.stopSearching()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if isSearching {
                        Button("Stop") {
                            stopSearching()
                        }
                    } else {
                        Button("Search") {
                            startSearching()
                        }
                    }
                }
            }
            .onAppear {
                startSearching()
            }
            .onDisappear {
                bleService.stopSearching()
            }
            .onChange(of: bleService.connectionState) { _, newState in
                if case .connected = newState {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Views

    private var searchStatusHeader: some View {
        VStack(spacing: 8) {
            if isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Searching for Polar devices...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if !bleService.discoveredDevices.isEmpty {
                Text("\(bleService.discoveredDevices.count) device(s) found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var searchingView: some View {
        VStack(spacing: 20) {
            Spacer()

            // Animated radar effect
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .stroke(Color.blue.opacity(0.3 - Double(i) * 0.1), lineWidth: 2)
                        .frame(width: CGFloat(80 + i * 40), height: CGFloat(80 + i * 40))
                }

                Image(systemName: "wave.3.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
            }

            Text("Searching for Polar devices...")
                .font(.headline)

            Text("Make sure your Polar Loop is nearby\nand Bluetooth is enabled")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)

            Text("No Devices Found")
                .font(.headline)

            Text("Tap Search to scan for nearby\nPolar devices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: startSearching) {
                Label("Start Search", systemImage: "magnifyingglass")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
        .padding()
    }

    private var deviceListView: some View {
        List {
            Section {
                ForEach(bleService.discoveredDevices) { device in
                    DeviceRow(device: device) {
                        connectToDevice(device)
                    }
                }
            } header: {
                Text("Available Devices")
            } footer: {
                Text("Tap a device to pair and connect")
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Actions

    private func startSearching() {
        isSearching = true
        bleService.startSearching()
    }

    private func stopSearching() {
        isSearching = false
        bleService.stopSearching()
    }

    private func connectToDevice(_ device: PolarDiscoveredDevice) {
        stopSearching()
        bleService.connect(to: device.id)
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let device: PolarDiscoveredDevice
    let onTap: () -> Void

    @ObservedObject private var bleService = PolarBLEService.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Device icon
                Image(systemName: "waveform.path.ecg")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 40)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.body)
                        .foregroundStyle(.primary)

                    Text("ID: \(device.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Signal strength
                VStack(alignment: .trailing, spacing: 2) {
                    signalIcon
                    Text(device.signalStrength)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Connection indicator
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .disabled(isConnecting)
    }

    private var isConnecting: Bool {
        if case .connecting = bleService.connectionState {
            return true
        }
        return false
    }

    private var signalIcon: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { i in
                Rectangle()
                    .fill(signalColor(for: i))
                    .frame(width: 3, height: CGFloat(4 + i * 3))
            }
        }
    }

    private func signalColor(for bar: Int) -> Color {
        let strength: Int
        switch device.rssi {
        case -50...0: strength = 4
        case -60..<(-50): strength = 3
        case -70..<(-60): strength = 2
        default: strength = 1
        }

        return bar < strength ? .green : .gray.opacity(0.3)
    }
}

#Preview {
    PolarPairingView()
}
