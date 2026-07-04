import SwiftUI

/// Crates palette, sampled pixel-for-pixel from the desktop app UI, with a clear role hierarchy:
///
///   • `accent`   TEAL   #00868D — structure & interaction (tabs, links, buttons, controls,
///                                  selection) AND playback controls / now-playing highlights.
///                                  The desktop's brand-primary; what users tap.
///   • `playback` ORANGE #D88810 — reserved for the waveform scrubber (matching the desktop,
///                                  which keeps orange for the waveform only). NOT for controls —
///                                  orange-tinted buttons read off-brand (Ellie, 2026-07-04).
///   • `green`           #089848 — settled success (downloaded, cache up-to-date).
///   • `red`             danger.
///
/// Surfaces are a warm near-black charcoal in dark (#141412 / #201F1B — matching the desktop) and
/// warm "paper" in light (#F4F1E8 / #FFFDF8). Accents are brightened in dark mode so text/icons
/// clear WCAG AA on charcoal. The app supports both schemes; dark is the signature Crates look.
enum CratesColor {
    /// Primary interactive/brand color — teal.
    static let accent = Color("CratesTeal")
    static let accentDeep = Color("CratesTealDeep")
    static let teal = Color("CratesTeal")
    /// Playback / now-playing energy — orange.
    static let playback = Color("CratesOrange")
    static let green = Color("CratesGreen")
    static let blue = Color("CratesBlue")
    static let gold = Color("CratesGold")
    static let red = Color("CratesRed")

    static let background = Color("CratesBackground")
    static let surface = Color("CratesSurface")
    static let surfaceBorder = Color("CratesSurfaceBorder")
    static let textSecondary = Color("CratesTextSecondary")
}

/// Spacing / radius tokens. One scale, used everywhere, so layouts stay consistent.
enum CratesMetrics {
    static let gutter: CGFloat = 16
    static let rowSpacing: CGFloat = 12
    static let corner: CGFloat = 14
    static let coverCorner: CGFloat = 8
    static let miniPlayerArt: CGFloat = 40
    static let rowArt: CGFloat = 48
}

extension ShapeStyle where Self == Color {
    static var cratesAccent: Color { CratesColor.accent }
}
