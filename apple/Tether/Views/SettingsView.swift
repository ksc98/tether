//
//  SettingsView.swift
//  Tether
//
//  Device identity, paired devices list, and app information.
//

import SwiftUI
import TetherFramework

struct SettingsView: View {
    @Environment(TetherViewModel.self) private var viewModel

    @State private var showDeleteConfirm = false
    @State private var fingerprintToDelete: String?

    var body: some View {
        NavigationStack {
            List {
                // This Device
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    LinearGradient(
                                        colors: [.teal, .teal.opacity(0.7)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 40, height: 40)

                            Image(systemName: "iphone")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Device Name", text: Bindable(viewModel.certificateManager).localDeviceName)
                                .font(.body.weight(.medium))
                                .submitLabel(.done)

                            Text("This device")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !viewModel.certificateManager.myFingerprint.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TLS Fingerprint")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(formatFingerprint(viewModel.certificateManager.myFingerprint))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("This Device")
                }

                // Paired Devices
                Section {
                    if viewModel.certificateManager.knownHosts.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "shield.slash")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)

                                Text("No paired devices")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 20)
                            Spacer()
                        }
                    } else {
                        ForEach(
                            Array(viewModel.certificateManager.knownHosts.sorted(by: { $0.value < $1.value })),
                            id: \.key
                        ) { fingerprint, name in
                            HStack(spacing: 14) {
                                Image(systemName: "desktopcomputer")
                                    .font(.title3)
                                    .foregroundStyle(.teal)
                                    .frame(width: 32)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name)
                                        .font(.body.weight(.medium))

                                    Text(formatFingerprint(String(fingerprint.prefix(16))) + "…")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()
                            }
                            .accessibilityElement(children: .combine)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    fingerprintToDelete = fingerprint
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Unpair", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("Paired Devices")
                } footer: {
                    if !viewModel.certificateManager.knownHosts.isEmpty {
                        Text("Swipe left on a device to unpair it.")
                    }
                }

                // Sync Settings
                Section {
                    Toggle(isOn: Bindable(viewModel).autoSyncClipboard) {
                        HStack(spacing: 14) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.title3)
                                .foregroundStyle(.teal)
                                .frame(width: 32)
                                .accessibilityHidden(true)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic Clipboard Sync")
                                    .font(.body.weight(.medium))
                                
                                Text("Write remote updates to system pasteboard")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Sync Settings")
                } footer: {
                    Text("When enabled, the iPhone's clipboard will be updated immediately when a connected desktop clipboard changes.")
                }

                // Bluetooth clipboard
                Section {
                    Toggle(isOn: Bindable(viewModel).bluetoothClipboardEnabled) {
                        HStack(spacing: 14) {
                            Image(systemName: "bolt.horizontal.circle")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 32)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Desktop Copies in Background")
                                    .font(.body.weight(.medium))

                                Text("Notify when the desktop clipboard changes")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if viewModel.bluetoothClipboardEnabled {
                        HStack {
                            Text("Bluetooth")
                            Spacer()
                            Text(bluetoothClipboardStatusText)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.bluetoothClipboardStatus == .unknownDesktop
                            || viewModel.bluetoothClipboardStatus == .scanning {
                            Button {
                                viewModel.findDesktopOverBluetooth()
                            } label: {
                                Label("Find Desktop", systemImage: "dot.radiowaves.left.and.right")
                            }
                            .disabled(viewModel.bluetoothClipboardStatus == .scanning)
                        }
                    }
                } header: {
                    Text("Bluetooth Clipboard")
                } footer: {
                    Text("Tether stays subscribed to the desktop over Bluetooth after you leave the app. A copy on the desktop shows as a notification; tap Copy to put it on this iPhone's clipboard. Finding the desktop needs the Wi-Fi connection once.")
                }

                // Connection
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        ConnectionStatusView(state: viewModel.appState)
                    }

                    if !viewModel.connection.serverFingerprint.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server Fingerprint")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(formatFingerprint(viewModel.connection.serverFingerprint))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Connection")
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Protocol")
                        Spacer()
                        Text("TCP + mTLS")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Service Type")
                        Spacer()
                        Text("_tether._tcp")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Daemon Port")
                        Spacer()
                        Text("5134")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Unpair Device",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) {
                    if let fp = fingerprintToDelete {
                        viewModel.certificateManager.removeKnownHost(fingerprint: fp)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This device will need to be paired again to connect.")
            }
        }
    }

    // MARK: - Helpers

    private var bluetoothClipboardStatusText: String {
        switch viewModel.bluetoothClipboardStatus {
        case .off: return "Off"
        case .bluetoothOff: return "Bluetooth is off"
        case .unauthorized: return "Not allowed in Settings"
        case .unknownDesktop: return "Desktop not found yet"
        case .scanning: return "Scanning…"
        case .connecting: return "Waiting for desktop"
        case .subscribed: return "Subscribed"
        }
    }

    private func formatFingerprint(_ fp: String) -> String {
        var result = ""
        for (i, char) in fp.enumerated() {
            if i > 0 && i % 2 == 0 { result += ":" }
            result.append(char)
        }
        return result
    }
}

#Preview {
    SettingsView()
        .environment(TetherViewModel())
        .preferredColorScheme(.dark)
}
