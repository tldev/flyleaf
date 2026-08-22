import Foundation

// Bridge to the Anthropic CLI so pack building can run on the user's Claude
// account instead of a pasted API key. `ant auth login` (once, in Terminal)
// stores an OAuth profile; print-credentials mints short-lived access tokens
// and refreshes them itself.
enum AntCLI {
    static var binaryPath: String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/ant",
            "/usr/local/bin/ant",
            home + "/go/bin/ant",
            home + "/.local/bin/ant",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { binaryPath != nil }

    // Blocking (subprocess); call from a detached task, not the main actor.
    static func mintAccessToken() -> String? {
        guard let bin = binaryPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["auth", "print-credentials", "--access-token"]
        // A stale exported key must never shadow the profile.
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        process.environment = env

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            log(.anthropic, .warn, "ant launch failed: \(error.localizedDescription)")
            return nil
        }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log(.anthropic, .debug, "ant print-credentials unavailable: \(message.prefix(140))")
            return nil
        }
        return token
    }
}
