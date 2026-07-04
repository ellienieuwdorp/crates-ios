import SwiftUI

/// The bottom-accessory mini player that floats above the tab bar. Shows current art/title, a
/// play/pause control, and expands to the full Now Playing screen on tap. The Liquid Glass
/// material comes from the tab bar accessory itself, so this stays visually light.
///
/// Metrics (dogfood round 4, measured — probe app + Apple Music screenshot analysis): the
/// system slot is a hard 48pt (content taller than 48 gets CLIPPED on iOS 26; Music's pill is
/// the same 48). Music's density, not fullness, is what reads premium: 30pt art with ~9pt of
/// air, 14pt leading inset, footnote subtitle, bare primary-color glyphs on 44pt hit targets.
/// The fill-then-floor sandwich keeps iOS 26 (system imposes 48) and iOS 27 (capsule hugs
/// content) producing the identical pill.
struct MiniPlayerView: View {
    @Environment(PlaybackController.self) private var player
    var onExpand: () -> Void

    private let artSize: CGFloat = 30 // Music: ~30pt in the 48pt slot

    var body: some View {
        HStack(spacing: 12) {
            if player.current == nil {
                // Idle state: the accessory stays attached so the tab view's identity never
                // changes when playback starts (see RootView).
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(CratesColor.textSecondary)
                    .frame(width: artSize, height: artSize)
                Text("Not Playing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CratesColor.textSecondary)
                Spacer(minLength: 8)
            }
            if let tune = player.current {
                Artwork(tune: tune, size: artSize)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(tune.displayTitle)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    if player.playbackError != nil {
                        Label("Can't play — tap for details", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(CratesColor.red).lineLimit(1)
                    } else {
                        Text(tune.displayArtist)
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.primary) // Music uses primary here, not accent
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                // An unplayable current track must not show a fully-enabled play button.
                .disabled(player.playbackError != nil)
                .opacity(player.playbackError != nil ? 0.35 : 1)
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 14) // Music's leading inset; trailing air comes from the 44pt frames
        .padding(.trailing, 2)
        // Order is load-bearing:
        // 1. fill what the capsule proposes → content vertically centers (iOS 26);
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 2. floor so a hugging capsule (iOS 27) still comes out at the system 48pt.
        .frame(minHeight: 48)
        .contentShape(.rect)
        .onTapGesture(perform: onExpand)
        .accessibilityIdentifier("miniPlayer")
    }
}
