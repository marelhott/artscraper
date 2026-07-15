import SwiftUI

struct SidebarView: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarSection("Hledat podle") {
                        Picker("Hledat podle", selection: $store.mode) {
                            ForEach(SearchMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                    }

                    SidebarSection(store.mode == .artist ? "Umělec" : (store.mode == .scrape ? "Zdroj" : "Obrázky")) {
                        if store.mode == .artist {
                            sidebarField("Jméno umělce", text: $store.artistName)
                            FlowLayout(spacing: 5) {
                                ForEach(store.styles, id: \.self) { style in
                                    Button(style.capitalized) { toggleStyle(style) }
                                        .buttonStyle(.plain)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(store.selectedStyles.contains(style) ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.07), in: .capsule)
                                }
                            }
                        } else if store.mode == .scrape {
                            sidebarField("https://pinterest.com/…", text: $store.pinterestURL)
                        } else {
                            visualImagePicker
                        }
                    }

                    if store.mode == .visual {
                        SidebarSection("Oblast hledání") {
                            compactToggle("Oříznout oblast (crop)", isOn: $store.useVisualCrop)
                            if store.useVisualCrop, let first = store.visualImages.first {
                                cropOverlayPreview(url: first)
                            }
                        }
                    }

                    if store.mode != .visual {
                        SidebarSection("Zdroje") {
                            compactToggle("Pinterest", isOn: $store.usePinterest)
                            compactToggle("Google / web", isOn: $store.useGoogle)
                        }
                    }

                    SidebarSection("Kvalita") {
                        HStack {
                            Text("Počet výsledků")
                            Spacer()
                            Text(store.resultLimit.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                        ElegantSlider(
                            value: Binding(get: { Double(store.resultLimit) }, set: { store.resultLimit = Int($0) }),
                            range: 50...2000,
                            increment: 50,
                            accessibilityLabel: "Počet výsledků"
                        )
                        compactToggle("Odstranit duplicity", isOn: $store.deduplicate)
                        if store.mode != .visual {
                            compactToggle("Filtr kvality", isOn: $store.qualityFilter)
                            compactToggle("Vyloučit AI / fan art", isOn: $store.excludeAI)
                        }
                    }

                    if store.mode != .visual {
                        SidebarSection("Klíčová slova") {
                            sidebarField("Musí obsahovat", text: $store.includeKeywords)
                            sidebarField("Vyloučit", text: $store.excludeKeywords)
                        }
                    }

                    SidebarSection("Uložení") {
                        Button(action: store.chooseOutputDirectory) {
                            HStack(spacing: 7) {
                                Image(systemName: "folder")
                                Text(store.outputDirectory).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    Button(action: store.startSearch) {
                        HStack(spacing: 8) {
                            Spacer()
                            if store.isSearching { ProgressView().controlSize(.small) }
                            Image(systemName: "sparkle.magnifyingglass")
                            Text(store.isSearching ? "Hledám…" : "Spustit hledání")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .frame(height: 25)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 7))
                    .controlSize(.large)
                    .disabled(!store.canSearch)
                }
                .font(.system(size: 12))
                .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func sidebarField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.22), in: .rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.06)) }
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .frame(height: 21)
    }

    private func toggleStyle(_ style: String) {
        if store.selectedStyles.contains(style) { store.selectedStyles.remove(style) }
        else { store.selectedStyles.insert(style) }
    }

    // MARK: - Visual: drop-zone pro více obrázků

    @State private var isDropTargeted = false
    /// Dočasný crop rect během tažení (drag) — final uložen do store.visualCrop.
    @State private var pendingCropRect = CGRect.zero

    @ViewBuilder private var visualImagePicker: some View {
        // Drop-zone tlačítko
        Button(action: store.addVisualImages) {
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 18))
                Text(store.visualImages.isEmpty ? "Přidat obrázky" : "Přidat další")
                    .font(.system(size: 11))
                Text("Nebo sem přetáhněte soubory").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.22))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.white.opacity(0.1),
                        style: .init(lineWidth: 1, dash: [3, 3])
                    )
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let collected = CollectableURLs()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    if let url = object as? URL { collected.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                store.addVisualImageURLs(collected.values)
            }
            return true
        }

        // Seznam miniatur vybraných obrázků
        if !store.visualImages.isEmpty {
            VStack(spacing: 6) {
                ForEach(store.visualImages, id: \.self) { url in
                    HStack(spacing: 8) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            default: Color.gray.opacity(0.2).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(url.lastPathComponent).lineLimit(1).font(.system(size: 10))
                        Spacer()
                        Button { store.removeVisualImage(url) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Odebrat")
                    }
                }
                Button("Vyčistit") { store.clearVisualImages() }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Náhled prvního obrázku s drag-to-crop výběrem (port z eagle clonu).
    @ViewBuilder
    private func cropOverlayPreview(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFit()
            default:
                Color.gray.opacity(0.15).overlay(ProgressView())
            }
        }
        .frame(maxHeight: 130)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            GeometryReader { geo in
                // Zvýraznění aktuálního crop rect
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.15))
                    .frame(
                        width: store.visualCrop.w * geo.size.width,
                        height: store.visualCrop.h * geo.size.height
                    )
                    .position(
                        x: store.visualCrop.x * geo.size.width + (store.visualCrop.w * geo.size.width) / 2,
                        y: store.visualCrop.y * geo.size.height + (store.visualCrop.h * geo.size.height) / 2
                    )
            }
        }
        .overlay {
            GeometryReader { geo in
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                let start = value.startLocation
                                let end = value.location
                                pendingCropRect = CGRect(
                                    x: min(start.x, end.x) / geo.size.width,
                                    y: min(start.y, end.y) / geo.size.height,
                                    width: abs(end.x - start.x) / geo.size.width,
                                    height: abs(end.y - start.y) / geo.size.height
                                )
                            }
                            .onEnded { _ in
                                store.visualCrop = CropRect(
                                    x: max(0, pendingCropRect.origin.x),
                                    y: max(0, pendingCropRect.origin.y),
                                    w: min(1, max(0.05, pendingCropRect.width)),
                                    h: min(1, max(0.05, pendingCropRect.height))
                                )
                            }
                    )
            }
        }
        Button("Resetovat oříznutí") {
            store.visualCrop = .full
            pendingCropRect = .zero
        }
        .font(.system(size: 10))
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.45)
                .foregroundStyle(.tertiary)
            content
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: .init(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified) }
    }
    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 300; var x: CGFloat = 0; var y: CGFloat = 0; var rowHeight: CGFloat = 0; var points: [CGPoint] = []
        for view in subviews { let size = view.sizeThatFits(.unspecified); if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }; points.append(.init(x: x, y: y)); x += size.width + spacing; rowHeight = max(rowHeight, size.height) }
        return (.init(width: width, height: y + rowHeight), points)
    }
}

/// Thread-safe kolekce URL z drag&drop completion handlerů (mohou přijít z různých vláken).
private final class CollectableURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    func append(_ url: URL) { lock.lock(); defer { lock.unlock() }; storage.append(url) }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
}
