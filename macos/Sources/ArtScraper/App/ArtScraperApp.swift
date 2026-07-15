import AppKit
import SwiftUI

@main
struct ArtScraperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("ArtScraper", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Spustit hledání") { store.startSearch() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canSearch)
                Button("Vybrat vše") { store.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(store.results.isEmpty)
            }
        }

        Settings {
            SettingsView(store: store)
                .frame(width: 520, height: 260)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
