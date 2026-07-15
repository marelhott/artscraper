import SwiftUI

struct ResultsView: View {
    @Bindable var store: AppStore
    @State private var activityExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            if store.results.isEmpty { emptyState } else { resultsContent }
            if activityExpanded { ActivityView(logs: store.logs) }
        }
    }

    @ViewBuilder private var resultsContent: some View {
        switch store.displayMode {
        case .grid: grid
        case .largePreviews: largePreviews
        case .list: list
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Button(action: SidebarCommands.toggle) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Zobrazit nebo skrýt sidebar")
            Divider().frame(height: 16)
            if store.isSearching || store.isDownloading { ProgressView().controlSize(.small) }
            Text(store.statusText).font(.headline)
            if store.isSearching { ProgressView(value: store.progress).frame(maxWidth: 180) }
            Spacer()
            ElegantSlider(
                value: $store.gridItemSize,
                range: 140...360,
                increment: 10,
                accessibilityLabel: "Velikost mřížky"
            )
            .frame(width: 170)
            .disabled(store.displayMode != .grid)
            .opacity(store.displayMode == .grid ? 1 : 0.35)
            HStack(spacing: 13) {
                ForEach(ResultsDisplayMode.allCases) { mode in
                    Button { store.displayMode = mode } label: {
                        Image(systemName: mode.icon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(store.displayMode == mode ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(mode.title)
                }
            }
            if !store.results.isEmpty {
                Text("\(store.selectedIDs.count) z \(store.results.count)").foregroundStyle(.secondary)
                Button("Vše", action: store.selectAll).buttonStyle(.link)
                Button("Nic", action: store.deselectAll).buttonStyle(.link)
            }
            Divider().frame(height: 16)
            Button(action: store.downloadSelected) {
                Image(systemName: "arrow.down").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Stáhnout vybrané")
            .disabled(store.selectedIDs.isEmpty || store.isDownloading)
            .keyboardShortcut("d", modifiers: .command)
            Button(action: store.revealOutput) {
                Image(systemName: "folder").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Zobrazit složku")
            Button { activityExpanded.toggle() } label: {
                Image(systemName: "text.alignleft").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("Aktivita")
        }.padding(.horizontal, 14).frame(height: 44)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Najděte vizuální reference", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Zadejte umělce nebo Pinterest URL. Výsledky se objeví v nativní galerii.")
        } actions: {
            Button("Spustit hledání", action: store.startSearch).disabled(!store.canSearch)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: store.gridItemSize, maximum: store.gridItemSize * 1.28), spacing: 14)], spacing: 14) {
                ForEach(store.results) { item in
                    MediaCard(
                        item: item,
                        selected: store.selectedIDs.contains(item.id),
                        imageHeight: store.gridItemSize * 0.92,
                        toggle: { store.toggle(item) },
                        preview: { store.selectedPreview = item }
                    )
                }
            }.padding(18)
        }
    }

    private var largePreviews: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(store.results) { item in
                    LargePreviewCard(
                        item: item,
                        selected: store.selectedIDs.contains(item.id),
                        toggle: { store.toggle(item) },
                        preview: { store.selectedPreview = item }
                    )
                }
            }
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
            .padding(22)
        }
    }

    private var list: some View {
        List(store.results) { item in
            MediaListRow(
                item: item,
                selected: store.selectedIDs.contains(item.id),
                toggle: { store.toggle(item) },
                preview: { store.selectedPreview = item }
            )
        }
        .listStyle(.inset)
    }
}

private struct MediaCard: View {
    let item: MediaItem; let selected: Bool; let imageHeight: Double; let toggle: () -> Void; let preview: () -> Void
    @State private var isHovered = false
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: item.src) { phase in
                switch phase { case .success(let image): image.resizable().scaledToFill(); case .failure: Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.secondary); default: ProgressView() }
            }
            .frame(height: imageHeight)
            .frame(maxWidth: .infinity)
            .background(.quaternary)
            if isHovered {
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.alt?.isEmpty == false ? item.alt! : "Bez popisu").lineLimit(1).font(.caption.weight(.medium))
                        Text([item.source, item.dimensions].compactMap { $0 }.joined(separator: " · ")).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: toggle) { Image(systemName: selected ? "checkmark.circle.fill" : "circle") }
                        .buttonStyle(.plain)
                }
                .padding(9)
            }
            // Procenta vizuální shody (visual search re-ranking) — tenký bílý font bez pozadí.
            if let pct = item.matchPercent {
                Text(String(format: "%.0f%%", pct))
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .clipShape(.rect(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : Color.white.opacity(isHovered ? 0.22 : 0.06), lineWidth: selected ? 2 : 1) }
        .opacity(selected ? 1 : 0.48)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
        .onTapGesture(count: 2, perform: preview)
        .contextMenu { Button(selected ? "Vyřadit" : "Vybrat", action: toggle); Button("Náhled", action: preview) }
    }
}

private struct LargePreviewCard: View {
    let item: MediaItem; let selected: Bool; let toggle: () -> Void; let preview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: item.src) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: ContentUnavailableView("Náhled není dostupný", systemImage: "photo.badge.exclamationmark")
                default: ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 560)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(Rectangle())
            .onTapGesture(perform: preview)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.alt?.isEmpty == false ? item.alt! : "Bez popisu").font(.headline).lineLimit(2)
                    Text([item.source, item.dimensions].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Vybrat", isOn: Binding(get: { selected }, set: { _ in toggle() }))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .opacity(selected ? 1 : 0.45)
    }
}

private struct MediaListRow: View {
    let item: MediaItem; let selected: Bool; let toggle: () -> Void; let preview: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.src) { image in image.resizable().scaledToFill() } placeholder: { ProgressView() }
                .frame(width: 76, height: 58)
                .background(.quaternary)
                .clipShape(.rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.alt?.isEmpty == false ? item.alt! : "Bez popisu").lineLimit(1).font(.body.weight(.medium))
                Text([item.source, item.dimensions].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Vybrat", isOn: Binding(get: { selected }, set: { _ in toggle() })).labelsHidden()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: preview)
        .opacity(selected ? 1 : 0.45)
        .contextMenu { Button(selected ? "Vyřadit" : "Vybrat", action: toggle); Button("Náhled", action: preview) }
    }
}

private struct ActivityView: View {
    let logs: [String]
    var body: some View { ScrollViewReader { proxy in ScrollView { LazyVStack(alignment: .leading, spacing: 4) { ForEach(Array(logs.enumerated()), id: \.offset) { index, line in Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).id(index) } }.frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(height: 150).background(.black.opacity(0.82)).onChange(of: logs.count) { _, count in if count > 0 { proxy.scrollTo(count - 1) } } } }
}
