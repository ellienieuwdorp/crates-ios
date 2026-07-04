import SwiftUI

/// Album artwork, served through the two-tier ArtworkStore: cached covers render SYNCHRONOUSLY
/// in the first body pass (no placeholder frame, no pop — dogfood round 4, I3/I5); genuinely
/// first-seen covers fade in once and are cached forever after. No cover, demo mode, or a miss
/// renders the deterministic gradient tile so lists never show empty gray squares.
struct Artwork: View {
    @Environment(AppModel.self) private var model
    let tune: Tune
    var size: CGFloat = CratesMetrics.rowArt

    /// Keyed by coverID so a reused List row showing a new tune can never flash stale art.
    @State private var loaded: (coverID: Int64, image: UIImage)?

    private var coverID: Int64? {
        guard !model.isDemo, model.connection.isConfigured else { return nil }
        return tune.coverID
    }
    private var variant: ArtworkStore.Variant { size > 96 ? .display : .row }

    var body: some View {
        Group {
            if let coverID, let image = displayImage(for: coverID) {
                Image(uiImage: image).resizable().scaledToFill()
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
        .task(id: taskKey) {
            guard let coverID, loaded?.coverID != coverID else { return }
            guard ArtworkStore.shared.cachedImage(coverID: coverID, variant: variant) == nil else { return }
            if let image = await ArtworkStore.shared.image(coverID: coverID, variant: variant) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (coverID, image) }
            }
        }
    }

    /// Synchronous fast path first (memory tier), then the async-loaded state.
    private func displayImage(for coverID: Int64) -> UIImage? {
        if let hit = ArtworkStore.shared.cachedImage(coverID: coverID, variant: variant) { return hit }
        if let loaded, loaded.coverID == coverID { return loaded.image }
        return nil
    }

    private var taskKey: String { "\(coverID ?? -1)-\(variant.rawValue)" }

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
