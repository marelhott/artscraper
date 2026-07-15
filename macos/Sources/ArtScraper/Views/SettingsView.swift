import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    var body: some View {
        Form {
            Section("Výchozí umístění") { HStack { Text(store.outputDirectory).lineLimit(1).truncationMode(.middle); Spacer(); Button("Vybrat…", action: store.chooseOutputDirectory) } }
            Section("Backend") { LabeledContent("Lokální služba", value: "127.0.0.1:5050"); LabeledContent("Pinterest relace", value: store.isLoggedIn ? "Přihlášeno" : "Nepřihlášeno") }
        }.formStyle(.grouped).padding()
    }
}
