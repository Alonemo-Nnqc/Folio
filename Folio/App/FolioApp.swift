import SwiftUI

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Folio", id: "main") {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1320, height: 820)
        .commands { FolioCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }
    }
}
