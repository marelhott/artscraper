import Foundation
import OSLog

/// Pinterest v3 internal API klient — komunikuje s `visual_search/extension/image/`
/// (stejný endpoint jako Pinterest browser extension a Eagle plugin).
///
/// Port z eagle clonu (PixelFinder) — princip 1:1:
///   PUT https://api.pinterest.com/v3/visual_search/extension/image/
///   Content-Type: multipart/form-data
///   Body: image=<blob>, x, y, w, h, page_size=200
///
/// Auth: cookies z `PinterestAuthStore` (získané přes WKWebView login).
final class PinterestVisualClient: @unchecked Sendable {
    static let shared = PinterestVisualClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let logger = Logger(subsystem: "cz.mulenmara.ArtScraper", category: "PinterestVisual")

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpAdditionalHeaders = [
            "User-Agent": PinterestAuthStore.iphoneUserAgent,
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "en-US,en;q=0.9",
            "X-Pinterest-AppState": "active",
        ]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
    }

    // MARK: - Visual Search

    /// Provede visual search s obrázkem a crop rectem. Vrací piny + bookmark pro pagination.
    ///
    /// Přesný protokol (z RE Eagle pluginu):
    /// ```
    /// PUT https://api.pinterest.com/v3/visual_search/extension/image/
    /// Content-Type: multipart/form-data
    /// Body: image=<blob>, x, y, w, h, page_size=200
    /// ```
    func visualSearch(
        imageURL: URL,
        crop: CropRect = .full,
        bookmark: String? = nil
    ) async throws -> (pins: [PinterestPin], nextBookmark: String?) {

        // 1) Načíst obrázek do Data
        let imageData: Data
        do {
            imageData = try Data(contentsOf: imageURL)
        } catch {
            throw PinterestError.network(error)
        }

        // 2) Sestavit multipart body
        let boundary = "----ArtScraper\(UUID().uuidString)"
        let body = buildMultipartBody(
            boundary: boundary,
            fields: [
                "x": String(crop.x),
                "y": String(crop.y),
                "w": String(crop.w),
                "h": String(crop.h),
                "page_size": "200",
            ],
            file: (name: "image", filename: imageURL.lastPathComponent, data: imageData)
        )

        // 3) URL s volitelným bookmarkem
        var apiURL = URL(string: "https://api.pinterest.com/v3/visual_search/extension/image/")!
        if let bookmark, !bookmark.isEmpty {
            var comps = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "bookmark", value: bookmark)]
            if let u = comps?.url { apiURL = u }
        }

        // 4) Request
        var request = URLRequest(url: apiURL)
        request.httpMethod = "PUT"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(PinterestAuthStore.iphoneUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.pinterest.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://www.pinterest.com", forHTTPHeaderField: "Referer")
        request.httpBody = body

        // 5) Přidat cookies z WKWebView store
        let cookies = await PinterestAuthStore.shared.cookies()
        let cookieHeader = cookies.compactMap { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        // 6) Odeslat
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PinterestError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PinterestError.invalidResponse("non-HTTP response")
        }

        if http.statusCode == 401 {
            throw PinterestError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw PinterestError.invalidResponse("HTTP \(http.statusCode): \(body.prefix(300))")
        }

        // 7) Parse response
        do {
            let parsed = try decoder.decode(VisualSearchResponse.self, from: data)
            return (parsed.data, parsed.bookmark)
        } catch let err as PinterestError {
            throw err
        } catch {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw PinterestError.invalidResponse("JSON parse: \(error.localizedDescription). Body: \(body.prefix(300))")
        }
    }

    // MARK: - Originál obrázku (getLargeURL trick z RE)

    /// Pinterest komprimuje obrázek do `/236x/` nebo `/736x/` cesty. Originál je
    /// v `/originals/`. Nahradíme a zkusíme `.jpg` a `.png` HEAD requesty — co
    /// vrátí 200, to je originál.
    func resolveLargeURL(_ mediumURL: URL) async -> URL? {
        let path = mediumURL.absoluteString
        let originals = path.replacingOccurrences(of: "/[0-9]+x/", with: "/originals/", options: .regularExpression)
        guard originals.contains("/originals/") else { return mediumURL }
        guard let jpgURL = URL(string: originals) else { return mediumURL }

        // Pokud URL už má příponu, zkusíme ji přímo
        if originals.hasSuffix(".jpg") || originals.hasSuffix(".png") {
            if await headOK(jpgURL) { return jpgURL }
            // zkusit prohodit
            let alt = originals.hasSuffix(".jpg")
                ? originals.replacingOccurrences(of: ".jpg", with: ".png")
                : originals.replacingOccurrences(of: ".png", with: ".jpg")
            if let altURL = URL(string: alt), await headOK(altURL) { return altURL }
            return nil
        }

        // Bez přípony — zkusíme obě paralelně
        let jpg = originals + ".jpg"
        let png = originals + ".png"
        guard let jpgURL = URL(string: jpg), let pngURL = URL(string: png) else { return nil }
        async let jpgOK = headOK(jpgURL)
        async let pngOK = headOK(pngURL)
        let jpgResult = await jpgOK
        let pngResult = await pngOK
        if jpgResult { return jpgURL }
        if pngResult { return pngURL }
        return nil
    }

    private func headOK(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(PinterestAuthStore.iphoneUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Stažení do složky

    /// Stáhne originál pinu do `folder`. Vrací výslednou URL souboru.
    func downloadToFolder(_ pin: PinterestPin, folder: URL) async throws -> URL {
        guard let largeURL = await resolveLargeURL(pin.imageMediumURL) else {
            throw PinterestError.downloadFailed("nelze získat URL originálu")
        }

        let (tmpURL, response): (URL, URLResponse)
        do {
            (tmpURL, response) = try await session.download(from: largeURL)
        } catch {
            throw PinterestError.network(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PinterestError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Sestavit jméno — Pinterest pin id + přípona z URL
        let ext = largeURL.pathExtension.isEmpty ? "jpg" : largeURL.pathExtension
        var dest = folder.appendingPathComponent("pinterest_\(pin.id).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("pinterest_\(pin.id)_\(suffix).\(ext)")
            suffix += 1
        }

        // Přesunout z tmp do cíle
        do {
            try FileManager.default.moveItem(at: tmpURL, to: dest)
        } catch {
            // fallback: copy + remove
            try? FileManager.default.copyItem(at: tmpURL, to: dest)
            try? FileManager.default.removeItem(at: tmpURL)
        }
        return dest
    }

    // MARK: - Multipart builder

    private func buildMultipartBody(
        boundary: String,
        fields: [String: String],
        file: (name: String, filename: String, data: Data)
    ) -> Data {
        var body = Data()
        let lineBreak = "\r\n"

        for (key, value) in fields {
            body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            body.append("\(value)\(lineBreak)".data(using: .utf8)!)
        }

        // MIME typ odvozen z přípony
        let ext = (file.filename as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "jpg", "jpeg": mime = "image/jpeg"
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "application/octet-stream"
        }

        body.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\(lineBreak)".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        body.append(file.data)
        body.append(lineBreak.data(using: .utf8)!)

        body.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        return body
    }
}

// MARK: - Modely (port z eagle clonu)

/// Pinterest v3 visual-search pin — pouze pole, která reálně využíváme
/// (z reverzního inženýrství Eagle pluginu). Pinterest vrací desítky dalších,
/// ty ignorujeme (Decodable bere jen deklarované klíče).
struct PinterestPin: Identifiable, Decodable, Hashable {
    let id: String
    let imageMediumURL: URL
    let width: Int
    let height: Int

    enum CodingKeys: String, CodingKey {
        case id
        case imageMediumURL = "image_medium_url"
        case imageMediumSize = "image_medium_size_pixels"
    }

    enum SizeKeys: String, CodingKey {
        case width, height
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Pinterest vrací id jako String i jako Int v závislosti na endpointu.
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let i = try? c.decode(Int.self, forKey: .id) {
            id = String(i)
        } else {
            id = UUID().uuidString
        }
        imageMediumURL = try c.decode(URL.self, forKey: .imageMediumURL)
        let size = try c.nestedContainer(keyedBy: SizeKeys.self, forKey: .imageMediumSize)
        width = try size.decode(Int.self, forKey: .width)
        height = try size.decode(Int.self, forKey: .height)
    }

    /// Pro preview a testování.
    init(id: String, imageMediumURL: URL, width: Int, height: Int) {
        self.id = id
        self.imageMediumURL = imageMediumURL
        self.width = width
        self.height = height
    }
}

/// Pinterest v3 visual-search envelope.
struct VisualSearchResponse: Decodable {
    let status: String
    let data: [PinterestPin]
    let bookmark: String?

    enum CodingKeys: String, CodingKey {
        case status, data, bookmark
    }
}

/// Normalizovaný crop rect (0–1 vůči původnímu obrázku).
/// Pinterest API to bere přesně takhle: x, y, w, h v rozsahu 0–1.
struct CropRect: Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    /// Celý obrázek (default pro visual search bez cropu).
    static let full = CropRect(x: 0, y: 0, w: 1, h: 1)
}

/// Chyby klienta — rozlišujeme 401 (vyžaduje re-login) od ostatních.
enum PinterestError: LocalizedError {
    case unauthorized
    case noResults
    case invalidResponse(String)
    case network(Error)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Pinterest session vypršela — přihlaste se znovu."
        case .noResults: return "Pinterest nic nenašel."
        case .invalidResponse(let msg): return "Pinterest vrátil neplatnou odpověď: \(msg)"
        case .network(let err): return "Síťová chyba: \(err.localizedDescription)"
        case .downloadFailed(let msg): return "Stažení obrázku selhalo: \(msg)"
        }
    }
}
