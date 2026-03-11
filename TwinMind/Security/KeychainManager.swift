//
//  KeychainManager.swift
//  TwinMind
//
//  Wraps Security.framework to store / retrieve / delete sensitive strings.
//  Used for the Deepgram API key and any future OAuth tokens.
//

import Foundation
import Security

// MARK: - KeychainError

nonisolated enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case itemNotFound
    case encodingError

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let s): return "Keychain error: \(s)"
        case .itemNotFound:            return "Keychain item not found."
        case .encodingError:           return "Could not encode/decode keychain data."
        }
    }
}

// MARK: - KeychainManager

nonisolated struct KeychainManager {

    // ── Known keys ────────────────────────────────────────────────────────
    nonisolated enum Key: String {
        case deepgramAPIKey = "com.twinmind.deepgram.apikey"
        case encryptionKey = "com.twinmind.encryption.key"
    }

    private static let service = "com.twinmind.app"

    // MARK: - Save

    static func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingError }

        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData   as String: data,
            // Accessible only when device is unlocked; not backed up.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete any existing item first so we can re-add cleanly.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    // MARK: - Read

    static func read(key: Key) throws -> String {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { throw KeychainError.itemNotFound }
        guard status == errSecSuccess      else { throw KeychainError.unexpectedStatus(status) }

        guard
            let data   = item as? Data,
            let string = String(data: data, encoding: .utf8)
        else { throw KeychainError.encodingError }

        return string
    }

    // MARK: - Delete

    static func delete(key: Key) throws {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

// MARK: - SecurityManager

/// Provides AES-256-GCM file encryption using CryptoKit,
/// with the symmetric key stored in the Keychain.
import CryptoKit

actor SecurityManager {

    // MARK: - Encryption

    /// Encrypt a file and return the URL of the encrypted output.
    /// The encrypted file has the `.enc` extension appended.
    func encryptFile(at plainURL: URL) async throws -> URL {
        let key = try symmetricKey()
        let plainData = try Data(contentsOf: plainURL)

        let sealedBox = try AES.GCM.seal(plainData, using: key)
        guard let combined = sealedBox.combined else {
            throw SecurityError.encryptionFailed
        }

        let encURL = plainURL.appendingPathExtension("enc")
        try combined.write(to: encURL, options: .completeFileProtectionUnlessOpen)
        return encURL
    }

    /// Decrypt an `.enc` file and return the plaintext `Data`.
    func decryptFile(at encURL: URL) async throws -> Data {
        let key = try symmetricKey()
        let encData = try Data(contentsOf: encURL)
        let sealedBox = try AES.GCM.SealedBox(combined: encData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    // MARK: - Key Management

    private func symmetricKey() throws -> SymmetricKey {
        // Try to load from Keychain
        if let keyString = try? KeychainManager.read(key: .encryptionKey),
           let keyData   = Data(base64Encoded: keyString) {
            return SymmetricKey(data: keyData)
        }
        // Generate a new 256-bit key and persist it
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try KeychainManager.save(keyData.base64EncodedString(), for: .encryptionKey)
        return newKey
    }
}

// MARK: - SecurityError

nonisolated enum SecurityError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case keyNotFound

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Audio file encryption failed."
        case .decryptionFailed: return "Audio file decryption failed."
        case .keyNotFound:      return "Encryption key not found in Keychain."
        }
    }
}
