import SwiftUI

/// Per-crate offline download policy editor (Idea #2b): off / keep last N added / keep all, with a
/// configurable N. Shows how many tunes the current policy would keep.
struct DownloadPolicyView: View {
    let crate: Crate
    let tunes: [Tune]
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    @State private var mode: DownloadPolicy.Mode = .off
    @State private var keepCount: Double = 100

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("Off").tag(DownloadPolicy.Mode.off)
                        Text("Keep last N added").tag(DownloadPolicy.Mode.keepLastN)
                        Text("Keep all").tag(DownloadPolicy.Mode.keepAll)
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Offline for “\(crate.name)”")
                } footer: {
                    Text(explanation)
                }

                if mode == .keepLastN {
                    Section("Keep \(Int(keepCount)) most-recently-added") {
                        Slider(value: $keepCount, in: 25...500, step: 25) { Text("Count") }
                            .tint(CratesColor.accent)
                        HStack {
                            ForEach([50, 100, 200], id: \.self) { n in
                                Button("\(n)") { keepCount = Double(n) }
                                    .buttonStyle(.bordered)
                                    .tint(CratesColor.accent)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        downloads.setPolicy(
                            DownloadPolicy(mode: mode, keepCount: Int(keepCount)),
                            for: crate.id, crateTunes: tunes
                        )
                        dismiss()
                    }
                }
            }
            .onAppear {
                let p = downloads.policy(for: crate.id)
                mode = p.mode; keepCount = Double(p.keepCount)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var explanation: String {
        switch mode {
        case .off:
            return "No tracks from this crate are kept offline."
        case .keepAll:
            return "All \(tunes.count) tracks download and stay offline."
        case .keepLastN:
            let kept = DownloadManager.tunesToKeep(tunes: tunes,
                        policy: DownloadPolicy(mode: .keepLastN, keepCount: Int(keepCount))).count
            return "The \(kept) newest-added tracks stay offline; older ones are evicted as new tracks arrive."
        }
    }
}
