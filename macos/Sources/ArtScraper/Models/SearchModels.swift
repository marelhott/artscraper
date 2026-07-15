import Foundation

enum SearchMode: String, CaseIterable, Identifiable, Codable {
    case artist
    case scrape
    case visual

    var id: String { rawValue }
    var title: String {
        switch self {
        case .artist: "Umělec"
        case .scrape: "Pinterest URL"
        case .visual: "Vizuálně"
        }
    }
    var icon: String {
        switch self {
        case .artist: "person.crop.rectangle.stack"
        case .scrape: "link"
        case .visual: "photo.badge.magnifyingglass"
        }
    }
}

enum ResultsDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case largePreviews
    case list

    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: "Mřížka"
        case .largePreviews: "Velké náhledy"
        case .list: "Seznam"
        }
    }
    var icon: String {
        switch self {
        case .grid: "square.grid.3x3"
        case .largePreviews: "rectangle.grid.1x2"
        case .list: "list.bullet"
        }
    }
}

struct MediaItem: Codable, Identifiable, Hashable {
    let id: FlexibleID
    let src: URL
    var alt: String?
    var title: String?
    var source: String?
    var resolution: [Int]?
    /// Vizuální shoda s dotazem (visual search re-ranking). Nižší = podobnější.
    /// 0.0 = identické, ~0.3 = duplikát, ~0.5–0.8 = příbuzné, >1.0 = nesouvisející.
    var matchScore: Double?

    var dimensions: String? {
        guard let resolution, resolution.count >= 2 else { return nil }
        return "\(resolution[0]) × \(resolution[1])"
    }

    /// Procentuální vizuální shoda (0–100 %), normalizovaná pro zobrazení.
    /// distance ≤ 0.3 → ~100 %, ≥ 1.2 → ~0 %.
    var matchPercent: Double? {
        guard let matchScore else { return nil }
        let clamped = max(0, min(1.2, matchScore))
        return (1.0 - clamped / 1.2) * 100
    }
}

struct FlexibleID: Codable, Hashable, CustomStringConvertible {
    let value: String
    var description: String { value }

    init(value: String) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else if let number = try? container.decode(Int.self) { value = String(number) }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")) }
    }
}

struct SearchRequest: Encodable {
    let mode: String
    let name: String?
    let query: String?
    let chips: [String]
    let count: Int
    let minW: Int
    let minH: Int
    let minMp: Double
    let sources: [String]
    let dedup: Bool
    let hardFilter: Bool
    let excludeAi: Bool
    let kwInclude: String
    let kwExclude: String

    enum CodingKeys: String, CodingKey {
        case mode, name, query, chips, count, sources, dedup
        case minW = "min_w", minH = "min_h", minMp = "min_mp"
        case hardFilter = "hard_filter", excludeAi = "exclude_ai"
        case kwInclude = "kw_include", kwExclude = "kw_exclude"
    }
}

struct JobResponse: Decodable { let jobId: String; enum CodingKeys: String, CodingKey { case jobId = "job_id" } }
struct PreviewResponse: Decodable { let images: [MediaItem]; let count: Int }
struct DownloadRequest: Encodable {
    let previewJobId: String
    let selectedIds: [String]
    let output: String
    enum CodingKeys: String, CodingKey { case previewJobId = "preview_job_id", selectedIds = "selected_ids", output }
}

struct LoginStatus: Decodable {
    let loggedIn: Bool
    let savedEmail: String
    let autoLoginAvailable: Bool
    enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in", savedEmail = "saved_email", autoLoginAvailable = "auto_login_available"
    }
}

struct StreamEvent: Decodable {
    let type: String
    let text: String?
    let status: String?
    let count: Int?
    let pct: Int?
    let found: Int?
    let images: [MediaItem]?
}
