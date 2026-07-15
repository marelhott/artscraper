import AppKit
import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers

@MainActor @Observable
final class AppStore {
    var mode: SearchMode = .artist
    var artistName = ""
    var pinterestURL = ""
    var selectedStyles: Set<String> = []
    var resultLimit = 500
    var minimumWidth = 0
    var minimumHeight = 0
    var minimumMegapixels = 0.0
    var includeKeywords = ""
    var excludeKeywords = ""
    var usePinterest = true
    var useGoogle = false
    var deduplicate = true
    var qualityFilter = true
    var excludeAI = true
    var outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appending(path: "ArtScraper").path
    var results: [MediaItem] = []
    var selectedIDs: Set<FlexibleID> = Set<FlexibleID>()
    var logs: [String] = []
    var isSearching = false
    var isDownloading = false
    var progress: Double = 0
    var statusText = "Připraveno"
    var errorMessage: String?
    var isLoggedIn = false
    var selectedPreview: MediaItem?
    var displayMode: ResultsDisplayMode = .grid {
        didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "resultsDisplayMode") }
    }
    var gridItemSize: Double = 210 {
        didSet { UserDefaults.standard.set(gridItemSize, forKey: "gridItemSize") }
    }

    // Visual search (.visual mode) — port principu z eagle clonu (PixelFinder):
    // multipart PUT na Pinterest v3 visual_search/extension/image/.
    var visualImages: [URL] = []
    var useVisualCrop = false
    var visualCrop: CropRect = .full
    /// Pin cache pro visual mód — download podle id potřebuje původní PinterestPin,
    /// MediaItem ho neobsahuje. Mapa id → pin.
    private var visualPinCache: [String: PinterestPin] = [:]

    let styles = ["paintings", "drawings", "illustrations", "portraits", "sketches", "sculptures", "prints"]
    private let backend = BackendService()
    private let process = BackendProcess()
    private let logger = Logger(subsystem: "cz.mulenmara.ArtScraper", category: "AppStore")
    private var previewJobID: String?
    /// Pinterest visual-search auth store (nezávislý na backend session — vlastní WKWebView login).
    private let visualAuth = PinterestAuthStore.shared
    private let visualClient = PinterestVisualClient.shared

    var canSearch: Bool {
        guard !isSearching else { return false }
        switch mode {
        case .artist:
            return !artistName.trimmingCharacters(in: .whitespaces).isEmpty && (usePinterest || useGoogle)
        case .scrape:
            return !pinterestURL.trimmingCharacters(in: .whitespaces).isEmpty && (usePinterest || useGoogle)
        case .visual:
            return !visualImages.isEmpty
        }
    }

    init() {
        if let rawMode = UserDefaults.standard.string(forKey: "resultsDisplayMode"),
           let savedMode = ResultsDisplayMode(rawValue: rawMode) {
            displayMode = savedMode
        }
        let savedSize = UserDefaults.standard.double(forKey: "gridItemSize")
        if savedSize >= 140 { gridItemSize = savedSize }
        Task { await bootstrap() }
    }

    func bootstrap() async {
        do {
            try process.start()
            try await backend.waitUntilReady()
            isLoggedIn = try await backend.loginStatus().loggedIn
            statusText = "Připraveno"
        } catch { present(error) }
    }

    func startSearch() {
        guard canSearch else { return }
        if mode == .visual {
            Task { await runVisualSearch() }
        } else {
            Task { await search() }
        }
    }

    /// Visual search — port principu z eagle clonu (PixelFinder).
    /// Více obrázků → souběžný visual search pro každý přes TaskGroup, sloučení + dedup.
    @MainActor
    func runVisualSearch() async {
        isSearching = true
        results = []; selectedIDs = []; logs = []; progress = 0
        visualPinCache = [:]
        statusText = "Přihlašuji se do Pinterestu…"

        // 1) Zajistit login (otevře login sheet pokud třeba, čeká na dokončení).
        await visualAuth.ensureLoggedIn()
        guard visualAuth.isLoggedIn else {
            statusText = "Pinterest login zrušen"
            isSearching = false
            return
        }

        let crop = useVisualCrop ? visualCrop : .full
        let total = visualImages.count
        var done = 0
        statusText = "Hledám vizuálně (0/\(total))…"

        // 2) Souběžný visual search pro každý obrázek.
        let merged = await withTaskGroup(of: [PinterestPin].self, returning: [PinterestPin].self) { [visualClient] group in
            for url in visualImages {
                group.addTask {
                    do {
                        let (pins, _) = try await visualClient.visualSearch(imageURL: url, crop: crop)
                        return pins
                    } catch PinterestError.unauthorized {
                        // Signál — handler výše otevře login.
                        return []
                    } catch {
                        return []
                    }
                }
            }
            var all: [PinterestPin] = []
            for await batch in group {
                done += 1
                progress = Double(done) / Double(total)
                statusText = "Hledám vizuálně (\(done)/\(total))…"
                all.append(contentsOf: batch)
            }
            return all
        }

        // 3) Dedup podle Pinterest pin id a src URL.
        var seen = Set<String>()
        var unique: [PinterestPin] = []
        for pin in merged {
            let key = pin.id + "|" + pin.imageMediumURL.absoluteString
            if seen.insert(key).inserted { unique.append(pin) }
        }

        // 4) Vizuální re-ranking — seřadit piny podle skutečné vizuální podobnosti
        //    k dotazovacím obrázkům (Vision featureprint) a zahodit nepodobné.
        //    Řeší „doporučovací šum": Pinterest míchá relevantní piny s nerelevantními.
        statusText = "Hodnotím vizuální podobnost (\(unique.count) pinů)…"
        let queryData = visualImages.compactMap { try? Data(contentsOf: $0) }
        let ranked = await VisualReRanker.shared.rerank(pins: unique, queries: queryData)
        let rankedPins = ranked.map { $0.pin }

        // 5) Normalizace PinterestPin → MediaItem (napojení na stávající grid/select/download).
        //    matchScore = vizuální distance z re-rankeru (nižší = podobnější).
        for pin in rankedPins { visualPinCache[pin.id] = pin }
        let items = ranked.enumerated().map { (i, entry) in
            MediaItem(
                id: FlexibleID(value: entry.pin.id),
                src: entry.pin.imageMediumURL,
                alt: "Pinterest visual search",
                title: nil,
                source: "pinterest-visual",
                resolution: [entry.pin.width, entry.pin.height],
                matchScore: Double(entry.distance)
            )
        }
        results = items
        selectedIDs = Set(items.map(\.id))
        progress = 1
        statusText = "\(items.count) výsledků"

        // Pokud nedošlo k žádným výsledkům a session je neplatná → otevřít login.
        if results.isEmpty && !visualAuth.isLoggedIn {
            visualAuth.isLoginSheetPresented = true
        }
        isSearching = false
    }

    func search() async {
        isSearching = true
        results = []; selectedIDs = []; logs = []; progress = 0
        statusText = "Hledám…"
        let request = SearchRequest(
            mode: mode.rawValue,
            name: mode == .artist ? artistName : nil,
            query: mode == .scrape ? pinterestURL : nil,
            chips: Array(selectedStyles).sorted(), count: resultLimit,
            minW: minimumWidth, minH: minimumHeight, minMp: minimumMegapixels,
            sources: [usePinterest ? "pinterest" : nil, useGoogle ? "google" : nil].compactMap { $0 },
            dedup: deduplicate, hardFilter: qualityFilter, excludeAi: excludeAI,
            kwInclude: includeKeywords, kwExclude: excludeKeywords
        )
        do {
            let jobID = try await backend.startPreview(request)
            previewJobID = jobID
            for try await event in await backend.events(path: "api/preview/stream/\(jobID)") {
                if event.type == "log", let text = event.text { logs.append(text) }
                if let images = event.images { merge(images) }
                if let pct = event.pct { progress = Double(pct) / 100 }
                if event.type == "preview_done" {
                    let final = try await backend.previewResult(jobID: jobID)
                    results = final.images
                    selectedIDs = Set(final.images.map(\.id))
                    progress = 1
                    statusText = "\(final.count) výsledků"
                } else if event.type == "done", event.status != "done" {
                    throw BackendError.message("Hledání selhalo. Podrobnosti jsou v aktivitě.")
                }
            }
        } catch { present(error) }
        isSearching = false
    }

    func downloadSelected() {
        guard !selectedIDs.isEmpty else { return }
        if mode == .visual {
            Task { await downloadVisualSelected() }
            return
        }
        guard let previewJobID else { return }
        Task {
            isDownloading = true; statusText = "Stahuji…"
            do {
                let request = DownloadRequest(previewJobId: previewJobID, selectedIds: selectedIDs.map(\.description), output: outputDirectory)
                let jobID = try await backend.startDownload(request)
                for try await event in await backend.events(path: "api/download/stream/\(jobID)") {
                    if let text = event.text { logs.append(text); statusText = text }
                    if event.type == "done" {
                        statusText = event.status == "done" ? "Staženo do \(outputDirectory)" : "Stahování selhalo"
                    }
                }
            } catch { present(error) }
            isDownloading = false
        }
    }

    /// Stahování vybraných visual-search výsledků — přes PinterestVisualClient
    /// přímo do outputDirectory (resolve originálu přes /originals/).
    @MainActor
    func downloadVisualSelected() async {
        isDownloading = true; statusText = "Stahuji…"
        let folder = URL(fileURLWithPath: outputDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            present(error); isDownloading = false; return
        }
        let selected = selectedIDs.map(\.description)
        var downloaded = 0
        for id in selected {
            guard let pin = visualPinCache[id] else { continue }
            do {
                let dest = try await visualClient.downloadToFolder(pin, folder: folder)
                downloaded += 1
                statusText = "Staženo \(downloaded)/\(selected.count)…"
                logs.append("✓ \(dest.lastPathComponent)")
            } catch {
                logs.append("✗ pin \(id): \(error.localizedDescription)")
            }
        }
        statusText = downloaded > 0 ? "Staženo \(downloaded) do \(outputDirectory)" : "Stahování selhalo"
        isDownloading = false
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url.path }
    }

    // MARK: - Visual search: správa vstupních obrázků

    /// Otevře file picker pro výběr jednoho i více obrázků.
    func addVisualImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            for url in panel.urls where !visualImages.contains(url) {
                visualImages.append(url)
            }
        }
    }

    /// Přidá obrázky z drag&drop (URL).
    func addVisualImageURLs(_ urls: [URL]) {
        let imgExt = Set(["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"])
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard imgExt.contains(ext) else { continue }
            if !visualImages.contains(url) { visualImages.append(url) }
        }
    }

    func removeVisualImage(_ url: URL) { visualImages.removeAll { $0 == url } }
    func clearVisualImages() { visualImages.removeAll() }

    func toggle(_ item: MediaItem) { if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) } else { selectedIDs.insert(item.id) } }
    func selectAll() { selectedIDs = Set(results.map(\.id)) }
    func deselectAll() { selectedIDs.removeAll() }
    func revealOutput() { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: outputDirectory) }

    private func merge(_ newItems: [MediaItem]) {
        let known = Set(results.map(\.src)); results.append(contentsOf: newItems.filter { !known.contains($0.src) }); selectedIDs.formUnion(newItems.map(\.id))
    }
    private func present(_ error: Error) { errorMessage = error.localizedDescription; statusText = "Chyba"; logger.error("\(error.localizedDescription, privacy: .public)") }
}
