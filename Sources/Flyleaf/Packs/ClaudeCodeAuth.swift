import Foundation

// Uses the Claude Code login on this Mac so pack building draws on the user's
// Claude subscription (Max/Pro) instead of a pay-as-you-go API key. Claude
// Code stores an OAuth credential in the login keychain; this reads it, and
// refreshes it when expired the same way Claude Code does.
enum ClaudeCodeAuth {
    static let service = "Claude Code-credentials"
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenEndpoint = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    struct Blob {
        var oauth: [String: Any]
        var accessToken: String { oauth["accessToken"] as? String ?? "" }
        var refreshToken: String { oauth["refreshToken"] as? String ?? "" }
        var expiresAtMs: Double { (oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0 }
        var subscriptionType: String? { oauth["subscriptionType"] as? String }
    }

    static var isAvailable: Bool { readBlob() != nil }

    static var subscriptionType: String? { readBlob()?.subscriptionType }

    // Blocking (keychain + possible network); call from a detached task.
    static func accessToken() -> String? {
        guard let blob = readBlob(), !blob.accessToken.isEmpty else { return nil }
        let nowMs = Date().timeIntervalSince1970 * 1000
        if blob.expiresAtMs > nowMs + 120_000 {
            return blob.accessToken
        }
        // Expired or about to: refresh, and write the rotated tokens back so
        // Claude Code keeps working too.
        if !blob.refreshToken.isEmpty, let refreshed = refresh(blob) {
            writeBack(refreshed)
            log(.anthropic, "Refreshed Claude subscription token")
            return refreshed.accessToken
        }
        return blob.accessToken
    }

    // MARK: Keychain (via the `security` tool, which the login keychain ACL
    // already permits for the user's own tools)

    private static func readBlob() -> Blob? {
        guard let json = runSecurity(["find-generic-password", "-s", service, "-w"]),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else {
            return nil
        }
        return Blob(oauth: oauth)
    }

    private static func writeBack(_ blob: Blob) {
        let root = ["claudeAiOauth": blob.oauth]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: data, encoding: .utf8) else { return }
        let account = runSecurity(["find-generic-password", "-s", service, "-g"]).flatMap(accountFrom) ?? NSUserName()
        _ = runSecurity(["add-generic-password", "-U", "-s", service, "-a", account, "-w", json])
    }

    private static func accountFrom(_ securityOutput: String) -> String? {
        // The -g output includes: "acct"<blob>="thomasjohnell"
        guard let range = securityOutput.range(of: #""acct"<blob>="([^"]+)""#, options: .regularExpression) else { return nil }
        let match = String(securityOutput[range])
        return match.range(of: #"="([^"]+)"$"#, options: .regularExpression).map { String(match[$0].dropFirst(2).dropLast()) }
    }

    @discardableResult
    private static func runSecurity(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        // `-g` prints attributes to stderr; everything else to stdout.
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { return nil }
        let combined = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? stderr : combined
    }

    // MARK: Refresh

    private static func refresh(_ blob: Blob) -> Blob? {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": blob.refreshToken,
            "client_id": clientId,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Blob?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                return
            }
            var oauth = blob.oauth
            oauth["accessToken"] = access
            if let refresh = json["refresh_token"] as? String { oauth["refreshToken"] = refresh }
            if let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue {
                oauth["expiresAt"] = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
            }
            result = Blob(oauth: oauth)
        }.resume()
        semaphore.wait()
        return result
    }
}
