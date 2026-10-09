import SwiftUI

/// Remote access settings: on/off, pairing, paired devices.
struct RemoteAccessSheet: View {
    @EnvironmentObject private var server: RemoteServer
    @EnvironmentObject private var devices: DeviceStore
    @AppStorage("remoteAccessEnabled") private var enabled = false
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Remote Access").font(.headline)
                Spacer()
                Toggle("Allow connections", isOn: $enabled)
                    .toggleStyle(.switch)
                    .onChange(of: enabled) { RemoteAccess.apply($0, server: server) }
            }
            Text("This Mac only for now — reachable from other devices once encryption (TLS + verified pairing) is in place.")
                .font(.callout)
                .foregroundStyle(.secondary)

            status

            GroupBox("Pair a device") {
                VStack(alignment: .leading, spacing: 8) {
                    if let code = devices.pairingCode {
                        Text(code.prefix(4) + "-" + code.suffix(4))
                            .font(.system(size: 30, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Enter this code on the device. Single use, expires in 5 minutes.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Cancel Pairing") { devices.cancelPairing() }
                    } else {
                        Button("Show Pairing Code") { devices.beginPairing() }
                            .disabled(!server.isRunning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Paired devices") {
                if devices.devices.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        ForEach(devices.devices) { d in
                            HStack {
                                Image(systemName: "iphone")
                                VStack(alignment: .leading) {
                                    Text(d.name)
                                    Text("Paired \(Fmt.relative(d.pairedAt))" + (d.lastSeen.map { " · seen \(Fmt.relative($0))" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if server.connectedDevices.contains(d.name) {
                                    Text("connected").font(.caption).foregroundStyle(.green)
                                }
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    devices.revoke(d.id)
                                    server.disconnect(deviceID: d.id)
                                }
                            }
                        }
                    }
                    .padding(4)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onReceive(tick) { t in
            now = t
            if let expires = devices.pairingExpires, t > expires { devices.cancelPairing() }
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(server.isRunning ? Color.green : Color.secondary).frame(width: 8, height: 8)
            if server.isRunning, let port = server.port {
                Text("Listening on 127.0.0.1:\(String(port))")
            } else if let error = server.lastError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Off")
            }
            Spacer()
            if !server.connectedDevices.isEmpty {
                Text("\(server.connectedDevices.count) connected").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

enum RemoteAccess {
    static let port: UInt16 = 8473

    @MainActor
    static func apply(_ enabled: Bool, server: RemoteServer) {
        if enabled {
            do { try server.start(port: port) } catch { /* surfaced via server.lastError */ }
        } else {
            server.stop()
        }
    }
}
