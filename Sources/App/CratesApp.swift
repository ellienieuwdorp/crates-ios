import SwiftUI

/// User-selectable appearance. The palette has full light/dark variants; this only decides
/// which one wins (or defers to the system).
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "Follow System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@main
struct CratesApp: App {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance: AppAppearance = .system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.library)
                .environment(model.player)
                .environment(model.downloads)
                .tint(CratesColor.accent)
                .preferredColorScheme(appearance.colorScheme)
                .task { await model.bootstrap() }
        }
    }
}
