import Foundation
import OSLog

@MainActor
final class BackendProcess {
    private var process: Process?
    private let logger = Logger(subsystem: "cz.mulenmara.ArtScraper", category: "BackendProcess")

    func start() throws {
        guard process?.isRunning != true else { return }
        let root = Self.projectRoot()
        let python = Self.pythonExecutable(root: root)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [root.appending(path: "gui_app.py").path]
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PORT": "5050",
            "PYTHONUNBUFFERED": "1"
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [logger] handle in
            guard let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty else { return }
            logger.debug("\(text, privacy: .public)")
        }
        try process.run()
        self.process = process
        logger.info("Backend started")
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private static func projectRoot() -> URL {
        if let configured = ProcessInfo.processInfo.environment["ARTSCRAPER_ROOT"] { return URL(fileURLWithPath: configured) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
        var candidate = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appending(path: "gui_app.py").path) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private static func pythonExecutable(root: URL) -> String {
        let candidates = [root.appending(path: ".venv/bin/python3").path, "/opt/homebrew/bin/python3", "/usr/bin/python3"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? "/usr/bin/python3"
    }
}
