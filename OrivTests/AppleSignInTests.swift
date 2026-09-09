//
//  AppleSignInTests.swift
//  OrivTests
//
//  Nonce generation and hashing, and session storage round-trips.
//

import XCTest
@testable import Oriv

final class AppleSignInTests: XCTestCase {

    // MARK: - Nonce

    /// The hash sent to Apple must be a lowercase hex SHA256 of the raw nonce; the backend
    /// re-derives it to verify the identity token. A known vector guards the direction and
    /// the encoding at once.
    func testSHA256MatchesAKnownVector() {
        XCTAssertEqual(
            Nonce.sha256Hex("test"),
            "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
        )
        XCTAssertEqual(
            Nonce.sha256Hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testSHA256IsLowercaseHexOfTheExpectedLength() {
        let hash = Nonce.sha256Hex(Nonce.random())

        XCTAssertEqual(hash.count, 64)
        XCTAssertEqual(hash, hash.lowercased())
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    }

    func testHashedNonceDiffersFromTheRawNonce() {
        let raw = Nonce.random()
        XCTAssertNotEqual(raw, Nonce.sha256Hex(raw),
                          "Apple gets the hash, the backend gets the raw value — never the same")
    }

    func testRandomNonceHasTheRequestedLength() {
        XCTAssertEqual(Nonce.random().count, 32)
        XCTAssertEqual(Nonce.random(length: 8).count, 8)
        XCTAssertEqual(Nonce.random(length: 64).count, 64)
    }

    func testRandomNoncesAreUnique() {
        let nonces = Set((0..<200).map { _ in Nonce.random() })
        XCTAssertEqual(nonces.count, 200)
    }

    func testRandomNonceIsURLSafe() {
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = Nonce.random(length: 512)
        XCTAssertTrue(nonce.allSatisfy { allowed.contains($0) })
    }

    // MARK: - Name formatting

    func testFullNameIsFormattedForDisplay() {
        var components = PersonNameComponents()
        components.givenName = "Sam"
        components.familyName = "Runner"

        XCTAssertEqual(AppleCredential.formatted(components), "Sam Runner")
    }

    func testEmptyNameComponentsProduceNil() {
        XCTAssertNil(AppleCredential.formatted(PersonNameComponents()))
    }

    // MARK: - Session storage

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySessionStore()
        let session = AuthSession(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            user: UserProfile(
                id: UUID(),
                email: "runner@example.com",
                displayName: "Sam Runner",
                signInMethod: .apple,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        try store.save(session)
        XCTAssertEqual(try store.load(), session)

        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testSessionSurvivesJSONEncoding() throws {
        let session = AuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            user: UserProfile(
                id: UUID(),
                email: nil,
                displayName: nil,
                signInMethod: .apple,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        let data = try JSONEncoder.oriv.encode(session)
        XCTAssertEqual(try JSONDecoder.oriv.decode(AuthSession.self, from: data), session)
    }

    func testExpiryIsEvaluatedAgainstTheGivenInstant() {
        let session = AuthSession(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date(timeIntervalSince1970: 1000),
            user: UserProfile(
                id: UUID(), email: nil, displayName: nil,
                signInMethod: .apple, createdAt: Date()
            )
        )

        XCTAssertFalse(session.isExpired(asOf: Date(timeIntervalSince1970: 999)))
        XCTAssertTrue(session.isExpired(asOf: Date(timeIntervalSince1970: 1000)))
        XCTAssertTrue(session.isExpired(asOf: Date(timeIntervalSince1970: 1001)))
    }

    /// The Keychain is the real store; exercise it when the test process is entitled to
    /// use it, and skip rather than fail when it is not.
    func testKeychainStoreRoundTrip() throws {
        let store = KeychainSessionStore(
            service: "com.oriv.health.tests.\(UUID().uuidString)",
            account: "auth-session"
        )
        let session = AuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            user: UserProfile(
                id: UUID(),
                email: "runner@example.com",
                displayName: "Sam Runner",
                signInMethod: .apple,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        )

        do {
            try store.save(session)
        } catch KeychainSessionStore.KeychainError.missingEntitlement {
            throw XCTSkip("Test process is not entitled to use the keychain.")
        }

        defer { try? store.clear() }

        XCTAssertEqual(try store.load(), session)

        // Saving again must update in place rather than duplicating or failing.
        try store.save(session)
        XCTAssertEqual(try store.load(), session)

        try store.clear()
        XCTAssertNil(try store.load())
    }
}
