//
//  AuthService.swift
//  Oriv
//
//  The seam between `AuthManager` and whatever backend is behind it. Supabase will
//  conform to this in a `SupabaseAuthService`; until then `InMemoryAuthService` stands in
//  so the app builds, runs, and is testable with no project and no network.
//
//  Scope is M1 (Apple only). Email/password arrives with M3, Google with M4, and account
//  deletion with M2 — see AUTH_DESIGN.md §13.
//

import Foundation

public nonisolated protocol AuthService: Sendable {
    /// Exchanges a verified Apple credential for a session.
    ///
    /// Implementations must persist `credential.fullName` **only when it is non-nil**.
    /// Apple returns the name on the first authorization and never again, so writing a
    /// later `nil` over a stored name destroys it permanently.
    func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession

    /// Exchanges a refresh token for a fresh session.
    func refresh(_ session: AuthSession) async throws -> AuthSession

    /// Best-effort server-side revocation. Local state is cleared regardless of the outcome.
    func signOut() async throws
}

// MARK: - In-memory stand-in

/// A local fake that behaves like the real backend, including the name-persistence rule
/// above. Backs previews, tests, and M1 builds.
///
/// - Important: This must never ship. `AuthManager` emits a Release-build warning while it
///   is still the default — see `AuthManager.makeDefaultService()`.
public actor InMemoryAuthService: AuthService {

    /// Simulated server-side `profiles` rows, keyed by Apple's stable user identifier.
    private var storedProfiles: [String: UserProfile] = [:]

    /// Injected failure for exercising error paths in tests.
    public nonisolated enum Behaviour: Sendable {
        case succeed
        case fail(AuthError)
        /// Succeeds, but only after a delay — used to exercise the restore timeout.
        case succeedAfter(Duration)
    }

    private var behaviour: Behaviour

    public init(behaviour: Behaviour = .succeed) {
        self.behaviour = behaviour
    }

    public func setBehaviour(_ behaviour: Behaviour) {
        self.behaviour = behaviour
    }

    /// Test helper: what the "server" currently holds for an Apple user.
    public func profile(forAppleUserID id: String) -> UserProfile? {
        storedProfiles[id]
    }

    public func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession {
        try await applyBehaviour()

        let existing = storedProfiles[credential.userID]

        let profile = UserProfile(
            id: existing?.id ?? Self.stableUUID(for: credential.userID),
            // Apple omits the email on repeat sign-ins too; keep what we already have.
            email: credential.email ?? existing?.email,
            // The rule this whole file exists to protect.
            displayName: credential.fullName ?? existing?.displayName,
            signInMethod: .apple,
            createdAt: existing?.createdAt ?? Date()
        )
        storedProfiles[credential.userID] = profile

        return Self.makeSession(for: profile)
    }

    public func refresh(_ session: AuthSession) async throws -> AuthSession {
        try await applyBehaviour()
        return Self.makeSession(for: session.user)
    }

    public func signOut() async throws {
        try await applyBehaviour()
    }

    // MARK: - Helpers

    private func applyBehaviour() async throws {
        switch behaviour {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .succeedAfter(let delay):
            try? await Task.sleep(for: delay)
        }
    }

    private nonisolated static func makeSession(for profile: UserProfile) -> AuthSession {
        AuthSession(
            accessToken: "in-memory-access-\(UUID().uuidString)",
            refreshToken: "in-memory-refresh-\(UUID().uuidString)",
            expiresAt: Date().addingTimeInterval(3600),
            user: profile
        )
    }

    /// Deterministic UUID for a given Apple user id, so repeat sign-ins resolve to the
    /// same profile across process launches.
    private nonisolated static func stableUUID(for appleUserID: String) -> UUID {
        var hasher = Hasher()
        hasher.combine(appleUserID)
        let hash = UInt64(bitPattern: Int64(hasher.finalize()))

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            bytes[index] = UInt8((hash >> (8 * UInt64(index))) & 0xFF)
            bytes[index + 8] = bytes[index] ^ 0xA5
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - Unconfigured

/// Used by builds that carry no Supabase configuration. Every operation fails with a clear
/// message rather than pretending to succeed.
///
/// This exists so a misconfigured Release build cannot ship working-looking fake auth. See
/// `AuthManager.makeDefaultService()`.
public nonisolated struct UnconfiguredAuthService: AuthService {
    public init() {}

    private var failure: AuthError {
        .server("Sign-in isn't available in this build.")
    }

    public func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession {
        throw failure
    }

    public func refresh(_ session: AuthSession) async throws -> AuthSession {
        throw failure
    }

    /// Signing out is always allowed to "succeed" — the caller clears local state either
    /// way, and refusing would strand a user with credentials they cannot drop.
    public func signOut() async throws {}
}
