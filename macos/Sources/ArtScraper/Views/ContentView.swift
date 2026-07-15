import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    /// Pinterest visual-search login (nezávislý na backend session).
    @State private var visualAuth = PinterestAuthStore.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            ResultsView(store: store)
        }
        .navigationTitle("ArtScraper")
        .toolbar(removing: .sidebarToggle)
        .preferredColorScheme(.dark)
        .tint(.blue)
        .sheet(item: $store.selectedPreview) { item in
            PreviewView(item: item, selected: store.selectedIDs.contains(item.id)) { store.toggle(item) }
        }
        .onChange(of: visualAuth.isLoginSheetPresented) { _, presented in
            if presented { PinterestLoginWindowController.shared.show() }
            else { PinterestLoginWindowController.shared.close() }
        }
        .alert("ArtScraper", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

}
