//
//  SupabaseAuthServiceTests.swift
//  OrivTests
//
//  Covers the Supabase-backed AuthService: config loading, type mapping, error
//  collapsing, and one live round-trip against a local `supabase start` stack.
//

import XCTest
import Auth
@testable import Oriv

final class SupabaseAuthServiceTests: XCTestCase {

    // MARK: - Configuration

    func testConfigLoadsFromTheAppBundle() throws {
        // The app target sets ORIV_SUPABASE_* per configuration; Debug points at the
        // local stack. If this fails, the Config/Info.plist merge has regressed.
        let config = try XCTUnwrap(
            SupabaseConfig.fromBundle(Bundle(for: AuthManager.self)),
            "Expected SupabaseURL/SupabaseAnonKey in the app bundle for the Debug configuration"
        )

        XCTAssertFalse(config.anonKey.isEmpty)
        XCTAssertNotNil(config.url.scheme)
    }

    func testConfigRejectsUnsubstitutedBuildSettings() {
        // A missing build setting leaves the literal "$(ORIV_SUPABASE_URL)" behind. Treating
        // that as a URL would produce a client that fails on every request instead of
        // falling back to the in-memory service.
        let bundle = StubBundle(values: [
            "SupabaseURL": "$(ORIV_SUPABASE_URL)",
            "SupabaseAnonKey": "key"
        ])
        XCTAssertNil(SupabaseConfig.fromBundle(bundle))
    }

    func testConfigRejectsEmptyValues() {
        XCTAssertNil(SupabaseConfig.fromBundle(StubBundle(values: [
            "SupabaseURL": "", "SupabaseAnonKey": ""
        ])))

        XCTAssertNil(SupabaseConfig.fromBundle(StubBundle(values: [
            "SupabaseURL": "http://127.0.0.1:54321", "SupabaseAnonKey": ""
        ])))
    }

    func testConfigMissingKeysYieldNil() {
        XCTAssertNil(SupabaseConfig.fromBundle(StubBundle(values: [:])))
    }

    // MARK: - Error mapping

    func testNetworkErrorsCollapseToNetwork() {
        for code in [URLError.notConnectedToInternet, .timedOut, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertEqual(SupabaseAuthService.map(URLError(code)), .network)
        }
    }

    func testCancellationIsPreserved() {
        XCTAssertEqual(SupabaseAuthService.map(URLError(.cancelled)), .cancelled)
    }

    func testOrivErrorsPassThroughUnchanged() {
        XCTAssertEqual(SupabaseAuthService.map(AuthError.sessionExpired), .sessionExpired)
        XCTAssertEqual(SupabaseAuthService.map(AuthError.invalidCredentials), .invalidCredentials)
    }

    // MARK: - Display name

    func testDisplayNameIsReadFromUserMetadata() {
        XCTAssertEqual(SupabaseAuthService.displayName(from: makeUser(metadata: ["full_name": "Sam Runner"])), "Sam Runner")
        XCTAssertEqual(SupabaseAuthService.displayName(from: makeUser(metadata: ["name": "Sam"])), "Sam")
    }

    func testBlankDisplayNamesAreTreatedAsAbsent() {
        XCTAssertNil(SupabaseAuthService.displayName(from: makeUser(metadata: ["full_name": "   "])))
        XCTAssertNil(SupabaseAuthService.displayName(from: makeUser(metadata: [:])))
    }

    // MARK: - Session mapping

    func testSessionMappingConvertsUnixExpiryToADate() {
        let expiry: TimeInterval = 1_800_000_000
        let session = makeSession(expiresAt: expiry)

        let mapped = SupabaseAuthService.map(session, method: .apple)

        XCTAssertEqual(mapped.accessToken, "access-token")
        XCTAssertEqual(mapped.refreshToken, "refresh-token")
        XCTAssertEqual(mapped.expiresAt, Date(timeIntervalSince1970: expiry))
        XCTAssertEqual(mapped.user.signInMethod, .apple)
        XCTAssertEqual(mapped.user.email, "runner@example.com")
        XCTAssertEqual(mapped.user.displayName, "Sam Runner")
    }

    func testSignInMethodIsCarriedThroughRatherThanGuessed() {
        // GoTrue reports the provider on the identity, not the session, so the caller
        // supplies it. Refresh must preserve whatever the original sign-in was.
        let session = makeSession(expiresAt: 1_800_000_000)
        XCTAssertEqual(SupabaseAuthService.map(session, method: .password).user.signInMethod, .password)
        XCTAssertEqual(SupabaseAuthService.map(session, method: .google).user.signInMethod, .google)
    }

    // MARK: - Live round-trip

    /// Exercises the real client against a local `supabase start` stack: bundle config →
    /// AuthClient → GoTrue → `Session` → `AuthSession`. Skipped when the stack isn't up,
    /// so the suite stays runnable without Docker.
    ///
    /// Uses email/password because Apple sign-in cannot be driven headlessly — verifying a
    /// real Apple identity token needs Apple's keys and a matching audience. What this
    /// proves is everything *around* the credential: configuration, transport, decoding
    /// and mapping.
    func testLiveSignInRoundTripAgainstLocalSupabase() async throws {
        guard let config = SupabaseConfig.fromBundle(Bundle(for: AuthManager.self)) else {
            throw XCTSkip("No Supabase configuration in this build.")
        }
        // Hard guard: this test signs users up. It must never be able to run against a
        // hosted project, whatever the build happens to be configured with.
        guard let host = config.url.host, ["127.0.0.1", "::1", "localhost"].contains(host) else {
            throw XCTSkip("Configured Supabase is not local (\(config.url.host ?? "?")) — refusing to create users against a remote project.")
        }
        guard await Self.isReachable(config) else {
            throw XCTSkip("Local Supabase is not running — start it with `supabase start`.")
        }

        let client = AuthClient(
            configuration: AuthClient.Configuration(
                url: config.url.appendingPathComponent("auth/v1"),
                headers: ["apikey": config.anonKey],
                localStorage: EphemeralAuthStorage(),
                autoRefreshToken: false
            )
        )

        // GoTrue normalises addresses to lowercase, so generate one that already is.
        let email = "test-\(UUID().uuidString.lowercased())@example.com"
        let response = try await client.signUp(email: email, password: "correct-horse-battery")
        let session = try XCTUnwrap(response.session, "Local Supabase should return a session (enable_confirmations = false)")

        let mapped = SupabaseAuthService.map(session, method: .password)

        XCTAssertFalse(mapped.accessToken.isEmpty)
        XCTAssertFalse(mapped.refreshToken.isEmpty)
        XCTAssertEqual(mapped.user.email?.lowercased(), email.lowercased(),
                       "GoTrue normalises the address to lowercase")
        XCTAssertFalse(mapped.isExpired(), "A freshly issued session must not read as expired")

        // The refresh path is what `AuthManager.restoreSession` depends on.
        let refreshed = try await client.refreshSession(refreshToken: session.refreshToken)
        let mappedRefresh = SupabaseAuthService.map(refreshed, method: .password)

        XCTAssertEqual(mappedRefresh.user.id, mapped.user.id, "Refresh must keep the same user")
        XCTAssertFalse(mappedRefresh.isExpired())
    }

    // MARK: - Helpers

    private static func isReachable(_ config: SupabaseConfig) async -> Bool {
        var request = URLRequest(url: config.url.appendingPathComponent("auth/v1/health"))
        request.timeoutInterval = 3
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 500 < 500
        } catch {
            return false
        }
    }

    private func makeUser(metadata: [String: String]) -> User {
        User(
            id: UUID(),
            appMetadata: [:],
            userMetadata: metadata.mapValues { AnyJSON.string($0) },
            aud: "authenticated",
            email: "runner@example.com",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeSession(expiresAt: TimeInterval) -> Session {
        Session(
            accessToken: "access-token",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: expiresAt,
            refreshToken: "refresh-token",
            user: makeUser(metadata: ["full_name": "Sam Runner"])
        )
    }
}

// MARK: - Stub bundle

/// Lets the config loader be tested without building bundles on disk.
private final class StubBundle: Bundle, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
        super.init()
    }

    override func object(forInfoDictionaryKey key: String) -> Any? {
        values[key]
    }
}
