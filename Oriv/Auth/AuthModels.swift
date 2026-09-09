//
//  AuthModels.swift
//  Oriv
//
//  Domain types for authentication. No SDK types leak past this boundary, which is what
//  lets `AuthManager` be tested without a live backend — the same reason `ReadinessEngine`
//  takes a `ReadinessInput` rather than a health store.
//

import Foundation

// MARK: - Identity

public nonisolated enum SignInMethod: String, Sendable, Codable, Equatable {
    case apple
    case google
    case password

    public var displayName: String {
        switch self {
        case .apple:    return "Apple"
        case .google:   return "Google"
        case .password: return "Email"
        }
    }
}

public nonisolated struct UserProfile: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    /// May be an Apple private relay address. Never key identity on this — use `id`.
    public let email: String?
    /// Captured on the *first* Apple authorization only; `nil` forever after if missed.
    public let displayName: String?
    public let signInMethod: SignInMethod
    public let createdAt: Date

    public init(
        id: UUID,
        email: String?,
        displayName: String?,
        signInMethod: SignInMethod,
        createdAt: Date
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.signInMethod = signInMethod
        self.createdAt = createdAt
    }
}

public nonisolated struct AuthSession: Sendable, Equatable, Codable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let user: UserProfile

    public init(accessToken: String, refreshToken: String, expiresAt: Date, user: UserProfile) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.user = user
    }

    public func isExpired(asOf now: Date = Date()) -> Bool {
        expiresAt <= now
    }
}

// MARK: - Errors

public nonisolated enum AuthError: Error, Sendable, Equatable {
    case sessionExpired
    case appleCredentialRevoked
    /// Wrong password *or* no such account. Deliberately one case: distinguishing them in
    /// the UI is a user-enumeration leak, and a single case makes that structurally
    /// impossible rather than a copy-review problem.
    case invalidCredentials
    case emailNotVerified
    case network
    case cancelled
    case malformedAppleCredential
    case server(String)
}

nonisolated extension AuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sessionExpired:
            return "Your session expired. Please sign in again."
        case .appleCredentialRevoked:
            return "Apple sign-in access was revoked. Please sign in again."
        case .invalidCredentials:
            return "That email or password doesn't match an account."
        case .emailNotVerified:
            return "Check your inbox and confirm your email address first."
        case .network:
            return "Couldn't reach the server. Check your connection and try again."
        case .cancelled:
            return nil          // user-initiated; never surfaced
        case .malformedAppleCredential:
            return "Apple sign-in returned something unexpected. Please try again."
        case .server(let message):
            return message
        }
    }

    /// Cancellation is a normal outcome, not a failure to report.
    public var isSilent: Bool { self == .cancelled }
}

// MARK: - State

public nonisolated enum AuthState: Sendable, Equatable {
    /// Restoring a stored session. Always bounded — see `AuthManager.restoreSession`.
    case loading
    /// No account, by choice. The app works exactly as it did before accounts existed.
    case anonymous
    /// Showing the login screen. Carries the reason when there is one to explain.
    case signedOut(AuthError?)
    case signedIn(UserProfile)

    /// Whether the main app content should be shown.
    public var showsApp: Bool {
        switch self {
        case .anonymous, .signedIn: return true
        case .loading, .signedOut:  return false
        }
    }

    public var user: UserProfile? {
        if case .signedIn(let user) = self { return user }
        return nil
    }
}
