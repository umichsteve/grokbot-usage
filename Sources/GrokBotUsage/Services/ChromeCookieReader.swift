import Foundation
import CommonCrypto
import SQLite3

/// Best-effort reader for `WorkosCursorSessionToken` from Chromium-family
/// cookie databases (Chrome, Chromium, Edge, Brave, Arc, Cursor-embedded).
///
/// Chrome encrypts cookie values with a Keychain-backed key ("Chrome Safe Storage").
/// On first run macOS may prompt to allow Keychain access — that is expected and
/// does not require App Sandbox entitlements when running as a normal local app.
enum ChromeCookieReader {
    private static let cookieName = "WorkosCursorSessionToken"

    private struct BrowserProfile {
        let name: String
        let cookiesPath: String
        let safeStorageService: String
        let safeStorageAccount: String
    }

    static func readWorkosSessionToken() -> String? {
        for profile in candidateProfiles() {
            if let value = readCookie(
                dbPath: profile.cookiesPath,
                service: profile.safeStorageService,
                account: profile.safeStorageAccount
            ) {
                return value
            }
        }
        return nil
    }

    private static func candidateProfiles() -> [BrowserProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let support = "\(home)/Library/Application Support"

        var profiles: [BrowserProfile] = []

        let chromiumFamily: [(String, String, String)] = [
            ("Google/Chrome", "Chrome Safe Storage", "Chrome"),
            ("Chromium", "Chromium Safe Storage", "Chromium"),
            ("Microsoft Edge", "Microsoft Edge Safe Storage", "Microsoft Edge"),
            ("BraveSoftware/Brave-Browser", "Brave Safe Storage", "Brave"),
            ("Arc", "Arc Safe Storage", "Arc"),
        ]

        for (rel, service, account) in chromiumFamily {
            let base = "\(support)/\(rel)"
            let dirs = profileDirectories(under: base)
            for dir in dirs {
                let cookies = "\(dir)/Cookies"
                if FileManager.default.fileExists(atPath: cookies) {
                    profiles.append(
                        BrowserProfile(
                            name: rel,
                            cookiesPath: cookies,
                            safeStorageService: service,
                            safeStorageAccount: account
                        )
                    )
                }
            }
        }

        return profiles
    }

    private static func profileDirectories(under base: String) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        let defaultPath = "\(base)/Default"
        if fm.fileExists(atPath: defaultPath) {
            result.append(defaultPath)
        }
        guard let kids = try? fm.contentsOfDirectory(atPath: base) else { return result }
        for name in kids where name.hasPrefix("Profile") {
            let path = "\(base)/\(name)"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                result.append(path)
            }
        }
        return result
    }

    private static func readCookie(dbPath: String, service: String, account: String) -> String? {
        // Copy DB to temp — Chrome locks the live Cookies file.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grokbot-cookies-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }

        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: tmp.path)
            // Best-effort WAL copy
            for suffix in ["-wal", "-shm"] {
                let side = dbPath + suffix
                if FileManager.default.fileExists(atPath: side) {
                    try? FileManager.default.copyItem(atPath: side, toPath: tmp.path + suffix)
                }
            }
        } catch {
            return nil
        }

        guard let encrypted = queryEncryptedValue(dbPath: tmp.path) else { return nil }
        guard let key = keychainPassword(service: service, account: account) else { return nil }
        return decryptChromiumCookie(encrypted: encrypted, password: key)
    }

    private static func queryEncryptedValue(dbPath: String) -> Data? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT encrypted_value FROM cookies
        WHERE name = ?
          AND (host_key LIKE '%cursor.com' OR host_key LIKE '%.cursor.com' OR host_key = 'cursor.com')
        ORDER BY length(encrypted_value) DESC
        LIMIT 1;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        let bindOK = cookieName.withCString { cstr in
            sqlite3_bind_text(stmt, 1, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK
        }
        guard bindOK else { return nil }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: blob, count: length)
    }

    /// Reads the Chromium Safe Storage password from the login keychain via `security`.
    private static func keychainPassword(service: String, account: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "find-generic-password",
            "-w",
            "-s", service,
            "-a", account,
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty
        else { return nil }
        return s
    }

    /// Chromium cookie encryption: `v10` + AES-128-CBC.
    /// Key = PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16).
    private static func decryptChromiumCookie(encrypted: Data, password: String) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8) ?? ""
        let ciphertext: Data
        if prefix == "v10" || prefix == "v11" {
            ciphertext = encrypted.dropFirst(3)
        } else {
            // Legacy / unprefixed — try as-is
            ciphertext = encrypted
        }

        guard let key = pbkdf2(password: password, salt: Data("saltysalt".utf8), keyByteCount: 16, rounds: 1003) else {
            return nil
        }

        let iv = Data(repeating: 0x20, count: 16) // space characters
        guard let plain = aes128CBCDecrypt(data: Data(ciphertext), key: key, iv: iv) else {
            return nil
        }

        // Chromium may append PKCS#7 padding; trim non-printable trailing bytes.
        var trimmed = plain
        while let last = trimmed.last, last < 32 {
            trimmed.removeLast()
        }
        return String(data: trimmed, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private static func pbkdf2(password: String, salt: Data, keyByteCount: Int, rounds: Int) -> Data? {
        let passwordData = Data(password.utf8)
        var derived = Data(count: keyByteCount)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(rounds),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyByteCount
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : nil
    }

    private static func aes128CBCDecrypt(data: Data, key: Data, iv: Data) -> Data? {
        let outLength = data.count + kCCBlockSizeAES128
        var outBytes = Data(count: outLength)
        var numBytesDecrypted: size_t = 0

        let status = outBytes.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            outPtr.baseAddress, outLength,
                            &numBytesDecrypted
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return outBytes.prefix(numBytesDecrypted)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
