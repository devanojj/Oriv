//
//  SupabaseAuthService.swift
//  Oriv
//
//  The live `AuthService`, backed by Supabase GoTrue.
//
//  Only the `Auth` product of supabase-swift is linked, not the umbrella `Supabase`
//  target — M1 needs nothing else, and PostgREST can be added when M5 needs it.
//

import Foundation
import Auth

// MARK: - Configuration

public nonisolated struct SupabaseConfig: Sendable, Equatable {
    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Reads `SupabaseURL` / `SupabaseAnonKey` from the app's Info.plist, which are
    /// populated from build settings.
    ///
    /// The anon key is designed to be shipped in the client — it carries no authority of
    /// its own and every table is gated by Row Level Security. The `service_role` key is
    /// the one that must never appear here, or anywhere in the app bundle.
    public static func fromBundle(_ bundle: Bundle = .main) -> SupabaseConfig? {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let key = bundle.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String,
            !urlString.isEmpty, !key.isEmpty,
            !urlString.hasPrefix("$("),          // unsubstituted build setting
            let url = URL(string: urlString)
        else { return nil }

        return SupabaseConfig(url: url, anonKey: key)
    }
}

// MARK: - Service

public nonisolated final class SupabaseAuthService: AuthService {

    private let client: AuthClient

    public init(config: SupabaseConfig) {
        client = AuthClient(
            configuration: AuthClient.Configuration(
                url: config.url.appendingPathComponent("auth/v1"),
                headers: ["apikey": config.anonKey],
                // The SDK gets throwaway storage on purpose. `AuthManager`'s
                // `KeychainSessionStore` is the single source of truth for "who is signed
                // in", and two persistent stores would be free to drift apart — the SDK
                // silently refreshing a token that our copy never sees, for instance.
                // Every session the SDK hands back is mapped and persisted by us.
                localStorage: EphemeralAuthStorage(),
                autoRefreshToken: false
            )
        )
    }

    // MARK: AuthService

    public func signInWithApple(_ credential: AppleCredential) async throws -> AuthSession {
        do {
            let session = try await client.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: credential.identityToken,
                    // The **raw** nonce. Supabase hashes it and compares against the
                    // `nonce` claim inside Apple's signed token; sending the hash here
                    // fails verification. See AUTH_DESIGN.md §4.1.
                    nonce: credential.rawNonce
                )
            )
            return Self.map(session, method: .apple)
        } catch {
            throw Self.map(error)
        }
    }

    public func refresh(_ session: AuthSession) async throws -> AuthSession {
        do {
            let refreshed = try await client.refreshSession(refreshToken: session.refreshToken)
            return Self.map(refreshed, method: session.user.signInMethod)
        } catch {
            throw Self.map(error)
        }
    }

    public func signOut() async throws {
        do {
            try await client.signOut()
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: - Mapping

    /// Supabase `Session` → Oriv `AuthSession`.
    ///
    /// `signInMethod` is carried in rather than derived: GoTrue reports the provider on
    /// the identity, not the session, and we already know which path we came through.
    static func map(_ session: Session, method: SignInMethod) -> AuthSession {
        AuthSession(
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt),
            user: map(session.user, method: method)
        )
    }

    static func map(_ user: User, method: SignInMethod) -> UserProfile {
        UserProfile(
            id: user.id,
            email: user.email,
            displayName: displayName(from: user),
            signInMethod: method,
            createdAt: user.createdAt
        )
    }

    /// Apple's one-shot name is stored in user metadata by the sign-up trigger. Only
    /// non-empty strings count, so a blank value never displaces a real one.
    static func displayName(from user: User) -> String? {
        for key in ["full_name", "name", "display_name"] {
            if case .string(let value)? = user.userMetadata[key] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Collapses SDK errors into Oriv's vocabulary. Sign-in failures deliberately all land
    /// on `.invalidCredentials` so nothing distinguishes "no such account" from "wrong
    /// credentials" — see AUTH_DESIGN.md §4.3.
    static func map(_ error: any Error) -> AuthError {
        if let authError = error as? AuthError { return authError }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .network
            default:
                return .network
            }
        }

        // Auth.AuthError is the SDK's own error type.
        if let sdkError = error as? Auth.AuthError {
            switch sdkError.errorCode {
            case .sessionExpired, .refreshTokenNotFound, .refreshTokenAlreadyUsed:
                return .sessionExpired
            case .invalidCredentials, .userNotFound, .badJWT:
                return .invalidCredentials
            case .emailNotConfirmed:
                return .emailNotVerified
            default:
                return .server(sdkError.localizedDescription)
            }
        }

        return .server(error.localizedDescription)
    }
}

// MARK: - Storage

/// In-memory `AuthLocalStorage` for the SDK. See the note in `SupabaseAuthService.init`.
nonisolated final class EphemeralAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = value
    }

    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key]
    }

    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        items[key] = nil
    }
}
