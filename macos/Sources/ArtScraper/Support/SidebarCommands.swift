import AppKit

enum SidebarCommands {
    @MainActor
    static func toggle() {
        NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
    }
}
