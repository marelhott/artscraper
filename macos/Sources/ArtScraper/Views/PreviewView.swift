import SwiftUI

struct PreviewView: View {
    let item: MediaItem
    let selected: Bool
    let toggle: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            AsyncImage(url: item.src) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                .frame(minWidth: 620, minHeight: 480)
            HStack { Text(item.alt ?? "").lineLimit(2); Spacer(); Button(selected ? "Vyřadit" : "Vybrat", action: toggle); Button("Zavřít") { dismiss() }.keyboardShortcut(.cancelAction) }.padding([.horizontal, .bottom])
        }
    }
}
