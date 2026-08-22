// kprobe: fast standalone prober for Amazon device (ADP) endpoints.
// Reuses the device credentials Flyleaf exported to
// ~/Library/Application Support/Flyleaf/device-creds.json so requests can be
// tested without rebuilding the app.
//
// Usage:
//   swift Tools/kprobe.swift GET  cde-ta-g7g.amazon.com "/FionaCDEServiceEngine/sidecar?type=PDOC&key=ASIN"
//   swift Tools/kprobe.swift POST host "/path" '{"json":"body"}'
//   swift Tools/kprobe.swift position ASIN          # sidecar -> lpr, pretty
//   swift Tools/kprobe.swift raw GET host "/path"   # print full body, no truncation
import Foundation
import Security
import CryptoKit

// MARK: Credentials

struct Creds: Codable { let adpToken: String; let devicePrivateKey: String; let deviceType: String; let deviceSerial: String; let accessToken: String?; let refreshToken: String? }

func loadCreds() -> Creds {
    let path = ("~/Library/Application Support/Flyleaf/device-creds.json" as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write("No device-creds.json. Run flyleaf://register in the app first.\n".data(using: .utf8)!)
        exit(2)
    }
    return try! JSONDecoder().decode(Creds.self, from: data)
}

// MARK: ADP signing (mirror of the app's ADPSigner)

func loadRSAKey(_ input: String) -> SecKey? {
    var der: Data?
    if input.contains("BEGIN") {
        der = Data(base64Encoded: input.components(separatedBy: "\n").filter { !$0.contains("-----") }.joined())
    } else {
        der = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard var key = der else { return nil }
    if let pkcs1 = pkcs1FromPKCS8(key) { key = pkcs1 }
    let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate]
    var err: Unmanaged<CFError>?
    return SecKeyCreateWithData(key as CFData, attrs as CFDictionary, &err)
}

func pkcs1FromPKCS8(_ data: Data) -> Data? {
    let b = [UInt8](data); var i = 0
    func tag(_ t: UInt8) -> Int? {
        guard i < b.count, b[i] == t else { return nil }; i += 1
        guard i < b.count else { return nil }
        let f = b[i]; i += 1
        if f & 0x80 == 0 { return Int(f) }
        let n = Int(f & 0x7F); guard n > 0, n <= 4, i + n <= b.count else { return nil }
        var len = 0; for _ in 0..<n { len = (len << 8) | Int(b[i]); i += 1 }; return len
    }
    guard tag(0x30) != nil else { return nil }
    guard let vl = tag(0x02) else { return nil }; i += vl
    guard let al = tag(0x30) else { return nil }
    let oid: [UInt8] = [0x06,0x09,0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x01,0x01]
    guard Array(b[i..<min(i+al,b.count)]).starts(with: oid) else { return nil }
    i += al
    guard let ol = tag(0x04), i + ol <= b.count else { return nil }
    return Data(b[i..<i+ol])
}

func signingDate() -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00Z'"; return f.string(from: Date())
}

func adpHeaders(method: String, path: String, body: String, creds: Creds, key: SecKey) -> [String: String] {
    let date = signingDate()
    let data = "\(method)\n\(path)\n\(date)\n\(body)\n\(creds.adpToken)"
    var err: Unmanaged<CFError>?
    let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, data.data(using: .utf8)! as CFData, &err)!
    let sig64 = (sig as Data).base64EncodedString()
    return ["x-adp-token": creds.adpToken, "x-adp-alg": "SHA256withRSA:1.0", "x-adp-signature": "\(sig64):\(date)"]
}

func request(method: String, host: String, path: String, body: String?, creds: Creds, key: SecKey, extraHeaders: [String: String] = [:]) -> (Int, Data) {
    var req = URLRequest(url: URL(string: "https://\(host)\(path)")!)
    req.httpMethod = method
    req.setValue("Flyleaf/0.1", forHTTPHeaderField: "User-Agent")
    if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = body.data(using: .utf8) }
    for (k, v) in adpHeaders(method: method, path: path, body: body ?? "", creds: creds, key: key) { req.setValue(v, forHTTPHeaderField: k) }
    for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0); var out = (0, Data())
    URLSession.shared.dataTask(with: req) { d, r, _ in out = ((r as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data()); sem.signal() }.resume()
    sem.wait(); return out
}

// Bearer / plain requests to api.amazon.com (OAuth device token, no ADP).
func bearerRequest(method: String, url: String, bearer: String?, body: String?, contentType: String?) -> (Int, Data) {
    var req = URLRequest(url: URL(string: url)!)
    req.httpMethod = method
    req.setValue("Kindle/1.0.235280.0.10 CFNetwork/1220.1 Darwin/20.3.0", forHTTPHeaderField: "User-Agent")
    if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
    if let body { req.httpBody = body.data(using: .utf8) }
    let sem = DispatchSemaphore(value: 0); var out = (0, Data())
    URLSession.shared.dataTask(with: req) { d, r, _ in out = ((r as? HTTPURLResponse)?.statusCode ?? 0, d ?? Data()); sem.signal() }.resume()
    sem.wait(); return out
}

// MARK: Main

let args = Array(CommandLine.arguments.dropFirst())
let creds = loadCreds()
guard let key = loadRSAKey(creds.devicePrivateKey) else { print("bad key"); exit(3) }

func show(_ status: Int, _ body: Data, truncate: Int = 1500) {
    let text = String(data: body, encoding: .utf8) ?? "<\(body.count) binary bytes: \(body.prefix(32).base64EncodedString())>"
    print("HTTP \(status)  \(body.count) bytes")
    print(text.count > truncate ? String(text.prefix(truncate)) + "…[+\(text.count - truncate)]" : text)
}

switch args.first {
case "position":
    let asin = args[1]
    let (s1, b1) = request(method: "GET", host: "cde-ta-g7g.amazon.com", path: "/FionaCDEServiceEngine/sidecar?type=PDOC&key=\(asin)", body: nil, creds: creds, key: key)
    print("== sidecar =="); show(s1, b1)
case "raw":
    let (status, body) = request(method: args[1], host: args[2], path: args[3], body: args.count > 4 ? args[4] : nil, creds: creds, key: key)
    show(status, body, truncate: 100_000)
case "manifest":
    // kprobe manifest ASIN [pdoc|ebook]
    let asin = args[1].uppercased()
    let type = args.count > 2 ? args[2] : "pdoc"
    let kindleType = type == "ebook" ? "EBOK" : "PDOC"
    let ts = String(Int(Date().timeIntervalSince1970 * 1000))
    let corr = "Device:\(creds.deviceType):\(creds.deviceSerial);kindle.\(kindleType):\(asin):\(ts)"
    let extra = [
        "X-ADP-AttemptCount": "1",
        "X-ADP-CorrelationId": corr,
        "X-ADP-Transport": "WiFi",
        "X-ADP-Reason": "ArchivedItems",
        "x-amzn-accept-type": "application/x.amzn.digital.deliverymanifest@1.0",
        "X-ADP-SW": "1184366692",
        "User-Agent": "Kindle/1.0.235280.0.10 CFNetwork/1220.1 Darwin/20.3.0",
    ]
    let (status, body) = request(method: "GET", host: "kindle-digital-delivery.amazon.com", path: "/delivery/manifest/kindle.\(type)/\(asin)", body: nil, creds: creds, key: key, extraHeaders: extra)
    show(status, body, truncate: 6000)
case "download":
    // Download the (un-DRM'd personal doc) content and inspect its format.
    let asin = args[1].uppercased()
    let (s, b) = request(method: "GET", host: "kindle-digital-delivery.amazon.com", path: "/FionaCDEServiceEngine/FSDownloadContent?type=PDOC&key=\(asin)", body: nil, creds: creds, key: key)
    let out = "/tmp/flyleaf-doc.bin"
    try? b.write(to: URL(fileURLWithPath: out))
    print("HTTP \(s), wrote \(b.count) bytes to \(out)")
    print("magic hex: \(b.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " "))")
    print("magic ascii: \(String(decoding: b.prefix(24).map { ($0 >= 32 && $0 < 127) ? $0 : 46 }, as: UTF8.self))")
case "whispersync":
    // Refresh the device access token, resolve the user id, then dump the
    // Whispersync v2 reading-position datasets.
    let refreshBody = "app_name=Kindle%20for%20iOS&app_version=6.38.0.100&source_token=\(creds.refreshToken ?? "")&requested_token_type=access_token&source_token_type=refresh_token"
    let (ts, tb) = bearerRequest(method: "POST", url: "https://api.amazon.com/auth/token", bearer: nil, body: refreshBody, contentType: "application/x-www-form-urlencoded")
    guard ts == 200, let tj = try? JSONSerialization.jsonObject(with: tb) as? [String: Any], let access = tj["access_token"] as? String else {
        print("token refresh failed (\(ts)):"); show(ts, tb); exit(1)
    }
    print("refreshed device access token")
    let (ps, pb) = bearerRequest(method: "GET", url: "https://api.amazon.com/user/profile", bearer: access, body: nil, contentType: nil)
    let userId = ((try? JSONSerialization.jsonObject(with: pb)) as? [String: Any])?["user_id"] as? String ?? "A1MHXAUUM5569S"
    print("user_id: \(userId) (profile HTTP \(ps))")
    let arg = args.count > 1 ? args[1] : "datasets"
    let path = arg == "datasets" ? "datasets?embed=records.first_page&quiet=true" : arg
    let (ws, wb) = bearerRequest(method: "GET", url: "https://api.amazon.com/whispersync/v2/data/\(userId)/\(path)", bearer: access, body: nil, contentType: nil)
    show(ws, wb, truncate: 3_000_000)
default:
    let method = args.count >= 1 ? args[0] : "GET"
    let host = args.count >= 2 ? args[1] : "cde-ta-g7g.amazon.com"
    let path = args.count >= 3 ? args[2] : "/"
    let body = args.count >= 4 ? args[3] : nil
    let (status, resp) = request(method: method, host: host, path: path, body: body, creds: creds, key: key)
    show(status, resp)
}
