import SwiftUI
import AppKit
import SMSBackupCore

@main
struct SMSBackupViewerApp: App {
    @State private var model = AppModel()

    init() {
        // Lets the app behave properly when launched via `swift run` (outside a .app bundle).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("SMS Backup Viewer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Backup…") { model.showImporter = true }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .sidebar) {
                Button("Show Messages") { model.sidebarMode = .messages }
                    .keyboardShortcut("1")
                Button("Show Calls") { model.sidebarMode = .calls }
                    .keyboardShortcut("2")
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
