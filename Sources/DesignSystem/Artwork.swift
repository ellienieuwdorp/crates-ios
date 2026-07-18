import SwiftUI

/// Album artwork, served through the two-tier ArtworkStore: cached covers render SYNCHRONOUSLY
/// in the first body pass (no placeholder frame, no pop — dogfood round 4, I3/I5); genuinely
/// first-seen covers fade in once and are cached forever after. Demo mode uses bundled fictional
/// covers so screenshots exercise the real artwork layouts; a missing cover still renders the
/// deterministic gradient tile so lists never show empty gray squares.
struct Artwork: View {
    @Environment(AppModel.self) private var model
    let tune: Tune
    var size: CGFloat = CratesMetrics.rowArt

    /// Keyed by coverID so a reused List row showing a new tune can never flash stale art.
    @State private var loaded: (coverID: Int64, image: UIImage)?

    private var coverID: Int64? { tune.coverID }
    private var canFetch: Bool { !model.isDemo && model.connection.isConfigured }
    private var demoImage: UIImage? {
        guard model.isDemo, let coverID else { return nil }
        return DemoArtwork.image(for: coverID)
    }
    private var variant: ArtworkStore.Variant { size > 96 ? .display : .row }

    var body: some View {
        Group {
            if let demoImage {
                Image(uiImage: demoImage).resizable().scaledToFill()
            } else if let coverID, let image = displayImage(for: coverID) {
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
            guard canFetch, let coverID, loaded?.coverID != coverID else { return }
            guard ArtworkStore.shared.cachedImage(coverID: coverID, variant: variant) == nil else { return }
            if let image = await ArtworkStore.shared.image(coverID: coverID, variant: variant) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (coverID, image) }
            }
        }
    }

    /// Synchronous fast path first (memory tier), then the async-loaded state.
    private func displayImage(for coverID: Int64) -> UIImage? {
        guard canFetch else { return nil }
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

/// A single cover by ID (mosaic cells) through the ArtworkStore: synchronous when cached,
/// bundled fictional artwork in demo mode, and a seeded gradient placeholder otherwise.
struct CoverImage: View {
    @Environment(AppModel.self) private var model
    let coverID: Int64

    @State private var loaded: (id: Int64, image: UIImage)?

    private var canFetch: Bool { !model.isDemo && model.connection.isConfigured }
    private var demoImage: UIImage? {
        guard model.isDemo else { return nil }
        return DemoArtwork.image(for: coverID)
    }

    var body: some View {
        Group {
            if let image = demoImage ?? displayImage {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Self.gradient(seed: coverID))
            }
        }
        .task(id: coverID) {
            guard canFetch, loaded?.id != coverID,
                  ArtworkStore.shared.cachedImage(coverID: coverID, variant: .row) == nil else { return }
            if let image = await ArtworkStore.shared.image(coverID: coverID, variant: .row) {
                withAnimation(.easeOut(duration: 0.2)) { loaded = (coverID, image) }
            }
        }
    }

    private var displayImage: UIImage? {
        guard canFetch else { return nil }
        if let hit = ArtworkStore.shared.cachedImage(coverID: coverID, variant: .row) { return hit }
        if let loaded, loaded.id == coverID { return loaded.image }
        return nil
    }

    static func gradient(seed: Int64) -> LinearGradient {
        let hue = Double((seed &* 2654435761) % 360) / 360.0
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.5, brightness: 0.55),
                     Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.4)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Fictional, text-free covers bundled solely for the hermetic demo and screenshots. Several
/// tracks intentionally share a sleeve, like tracks from the same release in a real library.
@MainActor
private enum DemoArtwork {
    private static let namesByCoverID: [Int64: String] = [
        101: "demo-cover-solar-wind",
        102: "demo-cover-voltage",
        103: "demo-cover-pulsar",
        104: "demo-cover-reflections",
        105: "demo-cover-cascade",
        106: "demo-cover-voltage",
        107: "demo-cover-cascade",
        108: "demo-cover-pulsar",
        201: "demo-cover-submerged",
        202: "demo-cover-reflections",
        203: "demo-cover-pulsar",
        204: "demo-cover-solar-wind",
        205: "demo-cover-submerged",
        301: "demo-cover-cascade",
        302: "demo-cover-voltage",
        303: "demo-cover-reflections",
    ]

    private static let fallbackNames = [
        "demo-cover-solar-wind",
        "demo-cover-submerged",
        "demo-cover-voltage",
        "demo-cover-pulsar",
        "demo-cover-reflections",
        "demo-cover-cascade",
    ]

    static func image(for coverID: Int64) -> UIImage? {
        let fallbackIndex = Int(coverID.magnitude % UInt64(fallbackNames.count))
        let name = namesByCoverID[coverID] ?? fallbackNames[fallbackIndex]
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg") else { return nil }
        return UIImage(contentsOfFile: url.path)
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
