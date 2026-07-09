import SwiftUI

/// Connection / pairing screen driving the real onboarding: manual IP entry → pairing handshake
/// (approve on the desktop) → bulk library backup sync → browse. QR + mDNS discovery are
/// documented follow-ups.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var port: String = String(CratesConnection.defaultPort)
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section {
                if model.isPaired {
                    LabeledContent("Connected to", value: model.connection.host)
                    Button("Re-sync Library") { Task { try? await model.runInitialSync() } }
                    // ~112MB for the full corpus; makes every cover render offline.
                    Button("Cache All Artwork") { model.warmAllArtwork() }
                    Button("Sign Out", role: .destructive) { model.signOut(); dismiss() }
                } else {
                    TextField("Server address (IP or Tailscale name)", text: $host)
                        // Not .decimalPad: hostnames need letters, and comma-decimal locales get
                        // no "." key on it. numbersAndPunctuation covers IPs and *.ts.net names.
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    pairRow
                }
            } header: {
                Text("Crates Server")
            } footer: {
                connectionFooter
            }
            .animation(.snappy, value: model.onboarding)

            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button("Explore Demo Library") { model.enterDemoMode(); dismiss() }
            } footer: {
                Text("No server? Browse representative sample data to see the app.")
            }

            Section("About") {
                LabeledContent("Auth", value: "Bearer token via pairing")
                LabeledContent("Sync", value: "Bulk backup + delta")
                LabeledContent("Transport", value: "HTTP · local network")
                // Build is stamped with the build date/time, so this line answers "which
                // version is actually on the phone" at a glance.
                LabeledContent("Version", value: appVersion)
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.onboarding) { _, new in
            if new == .done { dismiss() }
        }
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    @ViewBuilder private var pairRow: some View {
        switch model.onboarding {
        case .waitingForApproval:
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approve on your computer…").font(.subheadline)
                    Text("A prompt is waiting in the Crates desktop app")
                        .font(.caption).foregroundStyle(CratesColor.textSecondary)
                }
            }
        case .syncing(let stage, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction) { Text(stage).font(.subheadline) }
                    .tint(CratesColor.accent)
            }
        default:
            // .failed also lands here: the button stays put and the error renders in the section
            // footer (connectionFooter), so the row never grows or jumps.
            pairButton
        }
    }

    /// Section footer: a neutral hint normally, a coherent inline warning when pairing failed.
    /// Living in the footer (not the button's cell) keeps the control boundary stable and reads
    /// as a natural part of the form rather than a control that suddenly sprouted an error.
    @ViewBuilder private var connectionFooter: some View {
        if model.isPaired {
            EmptyView()
        } else if case .failed(let msg) = model.onboarding {
            Label {
                Text(msg)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.footnote)
            .foregroundStyle(CratesColor.red)
        } else {
            Text("Enter your server's LAN IP or Tailscale address, then approve the pairing prompt in the Crates desktop app.")
        }
    }

    private var pairButton: some View {
        Button("Pair with Server") {
            Task { await model.pairAndSync(host: host, port: Int(port) ?? CratesConnection.defaultPort) }
        }
        .disabled(host.isEmpty)
    }
}
