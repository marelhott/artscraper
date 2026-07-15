import Foundation
import OSLog

actor BackendService {
    private let baseURL = URL(string: "http://127.0.0.1:5050")!
    private let logger = Logger(subsystem: "cz.mulenmara.ArtScraper", category: "Backend")

    func waitUntilReady() async throws {
        for _ in 0..<50 {
            do {
                let (_, response) = try await URLSession.shared.data(from: baseURL.appending(path: "api/login/status"))
                if (response as? HTTPURLResponse)?.statusCode == 200 { return }
            } catch { }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw BackendError.message("Lokální backend se nepodařilo spustit.")
    }

    func loginStatus() async throws -> LoginStatus { try await get("api/login/status") }

    func startPreview(_ payload: SearchRequest) async throws -> String {
        let response: JobResponse = try await post("api/preview", body: payload)
        return response.jobId
    }

    func previewResult(jobID: String) async throws -> PreviewResponse {
        try await get("api/preview/result/\(jobID)")
    }

    func startDownload(_ payload: DownloadRequest) async throws -> String {
        let response: JobResponse = try await post("api/download", body: payload)
        return response.jobId
    }

    func logout() async throws { let _: EmptyResponse = try await post("api/logout", body: EmptyRequest()) }

    func events(path: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: baseURL.appending(path: path))
                    try Self.validate(response)
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        let data = Data(line.dropFirst(6).utf8)
                        if let event = try? JSONDecoder().decode(StreamEvent.self, from: data) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await URLSession.shared.data(from: baseURL.appending(path: path))
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<B: Encodable, T: Decodable>(_ path: String, body: B) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw BackendError.message(message ?? "Backend vrátil neočekávanou odpověď.")
        }
    }
}

private struct EmptyRequest: Encodable {}
private struct EmptyResponse: Decodable { let ok: Bool }
enum BackendError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { value } else { nil } } }
