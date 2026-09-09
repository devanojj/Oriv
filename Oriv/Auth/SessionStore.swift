//
//  SessionStore.swift
//  Oriv
//
//  Session persistence. Keychain only — never UserDefaults, which is world-readable to
//  anything with access to the app container and gets swept into device backups.
//

import Foundation
import Security

public nonisolated protocol SessionStoring: Sendable {
    func load() throws -> AuthSession?
    func save(_ session: AuthSession) throws
    func clear() throws
}

// MARK: - Keychain

public nonisolated struct KeychainSessionStore: SessionStoring {

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        /// Returned when the process lacks the keychain entitlement, which happens in some
        /// test configurations. Callers treat this as "no stored session".
        case missingEntitlement
    }

    private let service: String
    private let account: String

    public init(
        service: String = (Bundle.main.bundleIdentifier ?? "com.oriv.health") + ".session",
        account: String = "auth-session"
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> AuthSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return try? JSONDecoder.oriv.decode(AuthSession.self, from: data)
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement:
            throw KeychainError.missingEntitlement
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func save(_ session: AuthSession) throws {
        let data = try JSONEncoder.oriv.encode(session)

        // Update first; insert only if nothing is there. Avoids a delete/add race that can
        // briefly leave the app with no stored session.
        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery()
            attributes[kSecValueData as String] = data
            // Readable after the first unlock, so background HealthKit delivery can still
            // refresh the token while the device is locked. With the stricter
            // `WhenUnlocked`, background sync fails silently. See AUTH_DESIGN.md §5.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                if addStatus == errSecMissingEntitlement { throw KeychainError.missingEntitlement }
                throw KeychainError.unexpectedStatus(addStatus)
            }
        case errSecMissingEntitlement:
            throw KeychainError.missingEntitlement
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            if status == errSecMissingEntitlement { throw KeychainError.missingEntitlement }
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - In-memory

/// Test and preview double. Deliberately not persistent.
public nonisolated final class InMemorySessionStore: SessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AuthSession?
    private let failure: (any Error)?

    public init(initial: AuthSession? = nil, failure: (any Error)? = nil) {
        self.stored = initial
        self.failure = failure
    }

    public func load() throws -> AuthSession? {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    public func save(_ session: AuthSession) throws {
        if let failure { throw failure }
        lock.lock(); defer { lock.unlock() }
        stored = session
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }

    /// Test helper — bypasses the injected failure.
    public var peek: AuthSession? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

// MARK: - Coding

nonisolated extension JSONEncoder {
    static let oriv: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

nonisolated extension JSONDecoder {
    static let oriv: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
