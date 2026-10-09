import SwiftUI
import CoreImage.CIFilterBuiltins

/// Remote access settings: on/off, reach (this Mac / network + interfaces),
/// pairing (QR + code), paired devices, recent activity.
struct RemoteAccessSheet: View {
    @EnvironmentObject private var remote: RemoteAccessController
    @EnvironmentObject private var server: RemoteServer
    @EnvironmentObject private var devices: DeviceStore
    @Environment(\.dismiss) private var dismiss
    @State private var interfaces: [NetworkInterface] = []
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                reach
                pairing
                pairedDevices
                activity
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .safeAreaInset(edge: .bottom) {
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.bar)
        }
        .onAppear { interfaces = NetworkInterface.current() }
        .onReceive(tick) { t in
            if let expires = devices.pairingExpires, t > expires { devices.cancelPairing() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Remote Access").font(.headline)
                Spacer()
                Toggle("Allow connections", isOn: $remote.enabled).toggleStyle(.switch)
            }
            HStack(spacing: 8) {
                Circle().fill(server.isRunning ? Color.green : Color.secondary).frame(width: 8, height: 8)
                if server.isRunning, let port = server.port {
                    Text(remote.scope == .network ? "Listening on port \(String(port)) · TLS" : "This Mac only · port \(String(port)) · TLS")
                } else if let e = remote.tlsError ?? server.lastError {
                    Text(e).foregroundStyle(.red)
                } else {
                    Text("Off")
                }
                Spacer()
                if !server.connectedDevices.isEmpty {
                    Text("\(server.connectedDevices.count) connected").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if let tls = remote.tls {
                Text("Security code \(tls.securityCode) · certificate \(tls.fingerprint.prefix(16))…")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var reach: some View {
        GroupBox("Reachable from") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Reach", selection: $remote.scope) {
                    Text("This Mac only").tag(RemoteAccessController.Scope.thisMac)
                    Text("Local network / VPN").tag(RemoteAccessController.Scope.network)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                if remote.scope == .network {
                    Text(remote.interfaces.isEmpty ? "All interfaces below. Tick some to restrict:" : "Only the ticked interfaces:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(interfaces) { i in
                        Toggle(isOn: Binding(
                            get: { remote.interfaces.contains(i.name) },
                            set: { on in
                                if on { remote.interfaces.insert(i.name) } else { remote.interfaces.remove(i.name) }
                            })) {
                            HStack {
                                Text(i.name).font(.callout.monospaced())
                                Text(i.kind).foregroundStyle(.secondary)
                                Spacer()
                                Text(i.addresses.first ?? "").font(.callout.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("macOS may ask once whether to accept incoming connections — allow it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep this Mac awake while remote access is on", isOn: $remote.keepAwake)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var pairing: some View {
        GroupBox("Pair a device") {
            VStack(alignment: .leading, spacing: 10) {
                if let code = devices.pairingCode {
                    HStack(alignment: .top, spacing: 16) {
                        if let url = remote.pairingURL(code: code), let qr = QRCode.image(url) {
                            Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150, height: 150)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan with the app, or enter:").font(.callout)
                            Text(code.prefix(4) + "-" + code.suffix(4))
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            Text("Single use, expires in 5 minutes. You'll be asked to approve the device here.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                if let url = remote.pairingURL(code: code) {
                                    Button("Copy Pairing Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url, forType: .string)
                                    }
                                }
                                Button("Cancel Pairing") { devices.cancelPairing() }
                            }
                        }
                    }
                } else {
                    Button("Show Pairing Code") { devices.beginPairing() }
                        .disabled(!server.isRunning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var pairedDevices: some View {
        GroupBox("Paired devices") {
            if devices.devices.isEmpty {
                Text("None yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
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
                            Button("Revoke", role: .destructive) { remote.revoke(d) }
                        }
                    }
                }
                .padding(4)
            }
        }
    }

    private var activity: some View {
        GroupBox("Recent activity") {
            if remote.recentAudit.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(4)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(remote.recentAudit) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(Fmt.short(e.at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(e.device ?? "—").font(.caption.weight(.medium))
                            Text(e.action).font(.caption)
                            Text(e.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}

enum QRCode {
    static func image(_ text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Menu bar status + kill switch while remote access is on.
struct RemoteMenuBarContent: View {
    @EnvironmentObject private var remote: RemoteAccessController
    @EnvironmentObject private var server: RemoteServer

    var body: some View {
        Text(server.isRunning ? "Remote access is on" : "Remote access is starting…")
        if server.connectedDevices.isEmpty {
            Text("No devices connected")
        } else {
            ForEach(server.connectedDevices, id: \.self) { Text("● \($0)") }
        }
        Divider()
        Button("Turn Off Remote Access") { remote.turnOff() }
    }
}
