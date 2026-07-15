import Foundation
import Vision
import OSLog

/// Re-rankuje Pinterest visual-search výsledky podle **skutečné vizuální podobnosti**
/// k dotazovacímu obrázku pomocí Vision featureprint embeddingu.
///
/// Problém, který řeší: Pinterest `visual_search` endpoint míchá vizuálně podobné piny
/// s doporučovacím šumem (piny, které s dotazem nesouvisí). Tento re-ranker:
///   1. spočítá featureprint dotazovacího obrázku,
///   2. souběžně stáhne náhledy pinů a spočítá jejich featureprinty,
///   3. změří vzdálenost každého pinu k dotazu (`VNFeaturePrintObservation.computeDistance`),
///   4. seřadí piny vzestupně (nejpodobnější první) a zahodí ty příliš vzdálené.
///
/// API potvrzeno pro macOS 15: `VNGenerateImageFeaturePrintRequest` → `VNFeaturePrintObservation`,
/// 768-dim L2-normalizovaný embedding, distance = cosine-like (nižší = podobnější).
actor VisualReRanker {
    static let shared = VisualReRanker()

    private let logger = Logger(subsystem: "cz.mulenmara.ArtScraper", category: "VisualReRanker")
    /// Souběžnost pro featureprint výpočet — omezíme na počet jader,
    /// protože Vision interně serializuje na Neural Engine/GPU.
    private let maxConcurrent = max(2, min(ProcessInfo.processInfo.processorCount, 6))
    /// Pinterest náhledy stahujeme souběžně, ale mírně (aby Pinterest neblokoval).
    private let downloadConcurrency = 8

    /// Prahová vzdálenost — piny nad tento limit zahodíme jako nepodobné.
    /// Kalibrováno pro Vision v2 featureprint: ~0.3 = téměř duplikát,
    /// ~0.5–0.8 = vizuálně příbuzné, >1.0 = nesouvisející.
    static let similarityThreshold: Float = 1.0

    private let session: URLSession
    /// Stav pro omezení souběžnosti featureprint výpočtu.
    private var slotsAvailable: Int
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    /// Featureprinty dotazovacích obrázků pro aktuální rerank běh.
    private var queryFeaturePrints: [VNFeaturePrintObservation] = []

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.httpMaximumConnectionsPerHost = 10
        session = URLSession(configuration: config)
        slotsAvailable = maxConcurrent
    }

    // MARK: - Slot management (bounded concurrency)

    private func acquireSlot() async {
        if slotsAvailable > 0 {
            slotsAvailable -= 1
            return
        }
        await withCheckedContinuation { cont in slotWaiters.append(cont) }
    }

    private func releaseSlot() {
        if let cont = slotWaiters.first {
            slotWaiters.removeFirst()
            cont.resume()
        } else {
            slotsAvailable += 1
        }
    }

    // MARK: - Veřejné API

    /// Seřadí piny podle vizuální podobnosti k dotazovacím obrázkům.
    /// U více dotazovacích obrázků se bere **minimální** vzdálenost (nejlepší shoda).
    /// Zahodí piny s vzdáleností nad `similarityThreshold`.
    ///
    /// - Returns: Seřazené (pin, distance) dvojice — nejpodobnější první.
    func rerank(
        pins: [PinterestPin],
        queries: [Data]
    ) async -> [(pin: PinterestPin, distance: Float)] {
        guard !pins.isEmpty, !queries.isEmpty else {
            return pins.map { ($0, 0) }
        }

        // 1) Featureprinty všech dotazovacích obrázků (uložíme do actor stavu
        //    — používá je score(), VNFeaturePrintObservation zůstává v actoru).
        queryFeaturePrints = queries.compactMap { featurePrint(data: $0) }
        if queryFeaturePrints.isEmpty {
            logger.error("Nepodařilo se spočítat featureprint dotazu — vracím neseřazené.")
            return pins.map { ($0, 0) }
        }

        // 2) Souběžně: stáhni náhled (Sendable Data), pak spočti skóre v actoru.
        //    VNFeaturePrintObservation NENÍ Sendable → držíme ji uvnitř actoru,
        //    do TaskGroup closure vracíme jen Data (Sendable) a Float (Sendable).
        let indexed = await withTaskGroup(of: (Int, Float?).self, returning: [(Int, Float)].self) { group in
            for (idx, pin) in pins.enumerated() {
                group.addTask { [session, self] in
                    await self.acquireSlot()
                    // release slot až po dokončení celé úlohy (download + score).
                    let thumbData = await self.download(url: pin.imageMediumURL, session: session)
                    let score: Float? = await self.score(thumbData: thumbData)
                    await self.releaseSlot()
                    return (idx, score)
                }
            }
            var results: [(Int, Float)] = []
            for await item in group {
                if let d = item.1 { results.append((item.0, d)) }
            }
            return results
        }

        // 3) Seřaď vzestupně podle vzdálenosti + zahod nad prahem.
        var ranked = indexed
            .filter { $0.1 <= Self.similarityThreshold }
            .sorted { $0.1 < $1.1 }
            .map { (pins[$0.0], $0.1) }

        // Pokud by prahování zahodilo úplně vše (moc přísné), uchováme top-N
        // jako fallback, ať uživatel něco dostane.
        if ranked.isEmpty && !indexed.isEmpty {
            let fallback = indexed.sorted { $0.1 < $1.1 }
            let keep = Array(fallback.prefix(40))
            ranked = keep.map { (pins[$0.0], $0.1) }
        }

        let dropped = pins.count - ranked.count
        logger.info("Re-rank: \(pins.count) pinů → \(ranked.count) (zahozeno \(dropped) jako nepodobné). Top distance: \(ranked.first?.1 ?? -1)")
        return ranked
    }

    // MARK: - Featureprint

    /// Spočítá featureprint. Voláno uvnitř actoru (nonisolated-context-safe:
    /// Vision typy neopouští tento kontext, vracíme jen referenci observation).
    private func featurePrint(data: Data) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        // Výchozí modelVersion (.version2) dává 768-dim normalizovaný embedding.
        let handler = VNImageRequestHandler(data: data, orientation: .up)
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            logger.warning("Featureprint selhal: \(error.localizedDescription)")
            return nil
        }
    }

    /// Actor-isolated: změří vizuální vzdálenost náhledu pinu k dotazovacím obrázkům.
    /// VNFeaturePrintObservation zůstává uvnitř actoru (není Sendable) — vracíme jen Float.
    /// Vrací minimální vzdálenost přes všechny dotazy (nejlepší shoda), nil při selhání.
    private func score(thumbData: Data?) -> Float? {
        guard let thumbData, let pinFP = featurePrint(data: thumbData) else { return nil }
        var best: Float = .infinity
        for q in queryFeaturePrints {
            var d: Float = 0
            if (try? q.computeDistance(&d, to: pinFP)) != nil, d < best { best = d }
        }
        return best == .infinity ? nil : best
    }

    // MARK: - Stahování náhledu

    private func download(url: URL, session: URLSession) async -> Data? {
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
                    return data
                }
            } catch {
                if attempt == 1 { return nil }
            }
        }
        return nil
    }
}
