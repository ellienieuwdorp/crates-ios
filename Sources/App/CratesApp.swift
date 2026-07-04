import SwiftUI

@main
struct CratesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(model.library)
                .environment(model.player)
                .environment(model.downloads)
                .tint(CratesColor.accent)
                .task { await model.bootstrap() }
        }
    }
}
