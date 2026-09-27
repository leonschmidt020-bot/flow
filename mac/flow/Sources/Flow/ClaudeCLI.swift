import Foundation

/// Ruft die lokale Claude-Code-CLI im Druckmodus auf (läuft über das eigene Claude-Abo, kein API-Schlüssel).
/// Optional: ohne CLI gibt es keine Zusammenfassungen/Transforms – Diktat und Transkript laufen trotzdem.
/// Keine Werkzeuge, keine MCP-Server, keine Sitzung wird gespeichert.
enum ClaudeCLI {
    static let binary: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for p in ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    static var isAvailable: Bool { binary != nil }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(system: String, input: String, model: String = "sonnet", timeout: TimeInterval = 180) async throws -> String {
        guard let bin = binary else { throw Failure(message: "Claude-CLI nicht gefunden") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-p", "--model", model, "--system-prompt", system, "--tools", "",
                               "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence",
                               "--output-format", "text"]
                // Nur die nötigen Variablen weitergeben (keine Schlüssel/Proxys aus der Umgebung)
                let src = ProcessInfo.processInfo.environment
                var env: [String: String] = [:]
                for k in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL"] { if let v = src[k] { env[k] = v } }
                env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                p.environment = env
                p.currentDirectoryURL = Paths.base
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
                var outData = Data(), errData = Data()
                let readGroup = DispatchGroup()
                readGroup.enter(); readGroup.enter()
                DispatchQueue.global().async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); readGroup.leave() }
                DispatchQueue.global().async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); readGroup.leave() }
                do { try p.run() } catch {
                    cont.resume(throwing: Failure(message: "Claude-CLI startet nicht: \(error.localizedDescription)"))
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input.data(using: .utf8) ?? Data())
                    try? inPipe.fileHandleForWriting.close()
                }
                p.waitUntilExit()
                killer.cancel()
                readGroup.wait()
                let out = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if p.terminationStatus != 0 || out.isEmpty {
                    let err = String(data: errData, encoding: .utf8) ?? ""
                    cont.resume(throwing: Failure(message: "Claude-CLI Fehler (\(p.terminationStatus)): \(err.prefix(300))\(out.prefix(300))"))
                } else {
                    cont.resume(returning: out)
                }
            }
        }
    }
}
