import SwiftUI

/// Album artwork. When connected, loads the real cover from `covers/byCoverID/{id}` (the one
/// unauthenticated media endpoint, so a plain `AsyncImage` works); otherwise — no cover, demo
/// mode, or while loading — renders a deterministic gradient tile so lists never show empty
/// gray squares.
struct Artwork: View {
    @Environment(AppModel.self) private var model
    let tune: Tune
    var size: CGFloat = CratesMetrics.rowArt

    private var coverURL: URL? {
        guard !model.isDemo, model.connection.isConfigured, let coverID = tune.coverID else { return nil }
        return model.connection.coverURL(coverID: coverID)
    }

    var body: some View {
        Group {
            if let coverURL {
                AsyncImage(url: coverURL, transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: CratesMetrics.coverCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CratesMetrics.coverCorner, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: CratesMetrics.coverCorner, style: .continuous)
            .fill(gradient)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
    }

    /// Two-stop gradient seeded by the title so each track keeps a stable, recognizable color.
    private var gradient: LinearGradient {
        var hash: UInt64 = 1469598103934665603
        for b in tune.displayTitle.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let hue = Double(hash % 360) / 360.0
        let base = Color(hue: hue, saturation: 0.55, brightness: 0.55)
        let accent = Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.4)
        return LinearGradient(colors: [base, accent], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// The small provenance glyph shown per row (Idea #7).
struct SourceBadge: View {
    let source: TrackSource
    var body: some View {
        Image(systemName: source.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(source.tint)
            .accessibilityLabel(source.label)
    }
}
