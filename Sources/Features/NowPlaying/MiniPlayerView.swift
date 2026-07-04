import SwiftUI

/// The bottom-accessory mini player that floats above the tab bar. Shows current art/title, a
/// play/pause control, and expands to the full Now Playing screen on tap. The Liquid Glass
/// material comes from the tab bar accessory itself, so this stays visually light.
struct MiniPlayerView: View {
    @Environment(PlaybackController.self) private var player
    var onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if player.current == nil {
                // Idle state: the accessory stays attached so the tab view's identity never
                // changes when playback starts (see RootView).
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(CratesColor.textSecondary)
                    .frame(width: CratesMetrics.miniPlayerArt, height: CratesMetrics.miniPlayerArt)
                Text("Not Playing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CratesColor.textSecondary)
                Spacer(minLength: 4)
            }
            if let tune = player.current {
                Artwork(tune: tune, size: CratesMetrics.miniPlayerArt)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tune.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if player.playbackError != nil {
                        Label("Can't play — tap for details", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(CratesColor.red).lineLimit(1)
                    } else {
                        Text(tune.displayArtist).font(.caption).foregroundStyle(CratesColor.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(CratesColor.accent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").font(.body)
                        .frame(width: 32, height: 36)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .contentShape(.rect)
        .onTapGesture(perform: onExpand)
        .accessibilityIdentifier("miniPlayer")
    }
}
