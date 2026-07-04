import SwiftUI

/// The bottom-accessory mini player that floats above the tab bar. Shows current art/title, a
/// play/pause control, and expands to the full Now Playing screen on tap. The Liquid Glass
/// material comes from the tab bar accessory itself, so this stays visually light.
///
/// Sizing (dogfood round 3, W4): iOS 26's accessory capsule imposes a ~48pt height and centers
/// hugging content; the iOS 27 beta derives capsule height FROM the content — bare content with
/// no vertical sizing collapsed into a short, flimsy pill. The frame sandwich below produces
/// the same ~48pt centered pill under both contracts: fill whatever is proposed, floor at 48.
struct MiniPlayerView: View {
    @Environment(PlaybackController.self) private var player
    /// Resolved pill height, measured — drives the Apple-Music-style near-full-height art.
    @State private var accessoryHeight: CGFloat = 48
    var onExpand: () -> Void

    /// Art nearly fills the capsule (~6pt inset top/bottom). Clamped so a stale measurement
    /// can never inflate the layout (iOS 27 hug mode makes the measurement self-referential).
    private var artSize: CGFloat { min(48, max(36, accessoryHeight - 12)) }

    var body: some View {
        HStack(spacing: 10) {
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
                Spacer(minLength: 4)
            }
            if let tune = player.current {
                Artwork(tune: tune, size: artSize)
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
                        .frame(width: 36)
                        .frame(maxHeight: .infinity) // full-pill hit target (44pt+ HIG)
                }
                .buttonStyle(.plain)
                // An unplayable current track must not show a fully-enabled play button —
                // the affordance would contradict the error one line away. Next stays live
                // (the queue may hold playable tracks).
                .disabled(player.playbackError != nil)
                .opacity(player.playbackError != nil ? 0.35 : 1)
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").font(.body)
                        .frame(width: 32)
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        // Order is load-bearing (see header comment):
        // 1. fill what the capsule proposes → content vertically centers (iOS 26);
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 2. floor so a hugging capsule (iOS 27) still comes out tab-bar-scale;
        .frame(minHeight: 48)
        // 3. measure the resolved height → art tracks the real capsule size.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accessoryHeight = $0 }
        .contentShape(.rect)
        .onTapGesture(perform: onExpand)
        .accessibilityIdentifier("miniPlayer")
    }
}
