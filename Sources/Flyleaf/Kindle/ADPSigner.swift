import Foundation
import Security

// Signs Amazon device (ADP) requests the way registered Kindle/Audible apps
// do: RSA-SHA256 over "method\npath\ndate\nbody\nadp_token", the signature
// base64'd and suffixed with the date. Headers x-adp-token / x-adp-alg /
// x-adp-signature authenticate the request as this registered device.
struct ADPSigner {
    let adpToken: String
    private let privateKey: SecKey

    init?(adpToken: String, privateKeyPEMorDER: String) {
        guard let key = ADPSigner.loadRSAPrivateKey(privateKeyPEMorDER) else {
            log(.kindle, .warn, "ADPSigner could not import device private key")
            return nil
        }
        self.adpToken = adpToken
        self.privateKey = key
    }

    func headers(method: String, path: String, body: String = "") -> [String: String]? {
        let date = ADPSigner.signingDate()
        let data = "\(method)\n\(path)\n\(date)\n\(body)\n\(adpToken)"
        guard let signature = sign(data) else { return nil }
        return [
            "x-adp-token": adpToken,
            "x-adp-alg": "SHA256withRSA:1.0",
            "x-adp-signature": "\(signature):\(date)",
        ]
    }

    private func sign(_ string: String) -> String? {
        guard let data = string.data(using: .utf8) else { return nil }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) else {
            log(.kindle, .warn, "ADP signature failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
            return nil
        }
        return (sig as Data).base64EncodedString()
    }

    private static func signingDate() -> String {
        // Mirrors Python datetime.now(UTC).isoformat("T") + "Z".
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00Z'"
        return f.string(from: Date())
    }

    // MARK: Key import

    static func loadRSAPrivateKey(_ input: String) -> SecKey? {
        var der: Data?
        if input.contains("BEGIN") {
            let base64 = input
                .components(separatedBy: "\n")
                .filter { !$0.contains("-----") }
                .joined()
            der = Data(base64Encoded: base64)
        } else {
            der = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard var keyData = der else { return nil }

        // SecKeyCreateWithData wants a bare PKCS#1 RSAPrivateKey. If this is a
        // PKCS#8 wrapper (version + rsaEncryption AlgorithmIdentifier + OCTET
        // STRING), unwrap to the inner key.
        if let pkcs1 = pkcs1FromPKCS8(keyData) {
            keyData = pkcs1
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) {
            return key
        }
        log(.kindle, .warn, "SecKeyCreateWithData failed: \(error?.takeRetainedValue().localizedDescription ?? "?")")
        return nil
    }

    // Minimal ASN.1 walk to extract the PKCS#1 payload from a PKCS#8 RSA key.
    // Returns nil if the input does not look like PKCS#8 (already PKCS#1).
    private static func pkcs1FromPKCS8(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        guard readTag(bytes, &i, expect: 0x30) != nil else { return nil } // outer SEQUENCE
        // version INTEGER
        guard let vLen = readTag(bytes, &i, expect: 0x02) else { return nil }
        i += vLen
        // AlgorithmIdentifier SEQUENCE (contains rsaEncryption OID)
        guard let algLen = readTag(bytes, &i, expect: 0x30) else { return nil }
        // Confirm it is rsaEncryption before committing to the unwrap.
        let algBytes = Array(bytes[i..<min(i + algLen, bytes.count)])
        let rsaOID: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
        guard algBytes.starts(with: rsaOID) else { return nil }
        i += algLen
        // OCTET STRING whose contents are the PKCS#1 key
        guard let octLen = readTag(bytes, &i, expect: 0x04) else { return nil }
        guard i + octLen <= bytes.count else { return nil }
        return Data(bytes[i..<i + octLen])
    }

    // Reads a tag byte and DER length at index; advances index past the
    // length bytes to the content start; returns content length.
    private static func readTag(_ bytes: [UInt8], _ i: inout Int, expect tag: UInt8) -> Int? {
        guard i < bytes.count, bytes[i] == tag else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        let first = bytes[i]; i += 1
        if first & 0x80 == 0 {
            return Int(first)
        }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, i + count <= bytes.count else { return nil }
        var len = 0
        for _ in 0..<count {
            len = (len << 8) | Int(bytes[i]); i += 1
        }
        return len
    }
}
