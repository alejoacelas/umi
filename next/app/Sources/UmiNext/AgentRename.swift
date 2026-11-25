import Foundation

enum AgentRename {
    struct ErrorMessage: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func write(_ name: String, thread: String, agent: [String: Any]) throws {
        switch agent["agent"] as? String {
        case "claude":
            guard let path = agent["transcript"] as? String, path.hasPrefix("/") else {
                throw ErrorMessage("Claude has not reported its transcript yet.")
            }
            let transcript = URL(fileURLWithPath: path).standardizedFileURL
            let project = transcript.deletingLastPathComponent()
            guard transcript.lastPathComponent == thread + ".jsonl",
                  project.deletingLastPathComponent().lastPathComponent == "projects" else {
                throw ErrorMessage("Claude has not reported its transcript yet.")
            }
            // Claude's SDK uses the same append-only custom-title record as /rename.
            // O_APPEND and one write keep a concurrent hook or message from being overwritten.
            // --name sets the live title before the first turn creates a transcript.
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let fd = open(transcript.path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var record = try JSONSerialization.data(withJSONObject: ["type": "custom-title", "sessionId": thread, "customTitle": name])
            // Preserve the final record in transcripts whose last line has no newline.
            var last: UInt8 = 0
            let end = lseek(fd, 0, SEEK_END)
            if end > 0, pread(fd, &last, 1, end - 1) == 1, last != 10 { record.insert(10, at: 0) }
            record.append(10)
            try record.withUnsafeBytes { bytes in
                var n: Int
                repeat { n = Darwin.write(fd, bytes.baseAddress, bytes.count) } while n < 0 && errno == EINTR
                guard n == bytes.count else { throw POSIXError(n < 0 ? POSIXErrorCode(rawValue: errno) ?? .EIO : .EIO) }
            }
        case "codex":
            let helper = Bundle.main.resourceURL!.appendingPathComponent("umi-next-codex-title").path
            // The app can start from Finder. Resolve codex with the pane's login-shell PATH.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let home = agent["codexHome"] as? String ?? SessionTitles.codexHome.path
            let result = SessionBackend.run(shell, ["-lc", #"exec "$@""#, "umi-rename", helper, "rename", thread, name],
                                            extraEnv: ["CODEX_HOME": home])
            guard result.status == 0 else {
                throw ErrorMessage("Codex could not rename this session. " + result.err.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        default:
            throw ErrorMessage("This session has no agent name to change.")
        }
    }
}
