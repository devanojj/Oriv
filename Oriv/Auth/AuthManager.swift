//
//  AuthManager.swift
//  Oriv
//
//  Owns authentication state. Deliberately shaped like `HealthKitManager`: @Observable,
//  @MainActor, wraps one external system, publishes one enum that a view switches on.
//

import Foundation
import Observation
import AuthenticationServices

@Observable
@MainActor
public final class AuthManager {

    // MARK: - Published state

    public private(set) var state: AuthState = .loading
    /// True while a sign-in or sign-out is in flight, so the UI can disable its controls.
    public private(set) var isBusy: Bool = false

    public var currentUser: UserProfile? { state.user }

    // MARK: - Collaborators

    private let service: any AuthService
    private let sessionStore: any SessionStoring
    private let credentialStateProvider: any AppleCredentialStateProviding
    private let defaults: UserDefaults

    /// How long session restore may take before falling through to a usable state. Without
    /// a bound, a bad network leaves the user on the splash screen indefinitely.
    private let restoreTimeout: Duration

    private var session: AuthSession?
    /// The raw nonce for the in-flight Apple request. Held only between `prepareAppleRequest`
    /// and the corresponding completion.
    private var pendingNonce: String?

    private static let skippedSignInKey = "auth.hasSkippedSignIn"
    private static let appleUserIDKey = "auth.appleUserID"

    public init(
        service: (any AuthService)? = nil,
        sessionStore: (any SessionStoring)? = nil,
        credentialStateProvider: any AppleCredentialStateProviding = LiveAppleCredentialStateProvider(),
        defaults: UserDefaults = .standard,
        restoreTimeout: Duration = .seconds(5)
    ) {
        self.service = service ?? Self.makeDefaultService()
        self.sessionStore = sessionStore ?? KeychainSessionStore()
        self.credentialStateProvider = credentialStateProvider
        self.defaults = defaults
        self.restoreTimeout = restoreTimeout
    }

    /// The backend stand-in used until Supabase is wired (AUTH_DESIGN.md M1).
    private static func makeDefaultService() -> any AuthService {
        #if !DEBUG
        #warning("Auth is still backed by InMemoryAuthService — wire SupabaseAuthService before any release. See AUTH_DESIGN.md §2.")
        #endif
        return InMemoryAuthService()
    }

    // MARK: - Launch

    /// Restores a stored session, always resolving out of `.loading`.
    public func restoreSession() async {
        state = .loading

        let stored: AuthSession?
        do {
            stored = try sessionStore.load()
        } catch {
            // A keychain that cannot be read is indistinguishable from an empty one.
            stored = nil
        }

        guard let stored else {
            state = signedOutOrAnonymous()
            return
        }

        guard stored.isExpired() else {
            session = stored
            state = .signedIn(stored.user)
            return
        }

        // Expired: try to refresh, but never hang on it.
        do {
            let service = self.service
            let refreshed = try await withTimeout(restoreTimeout) {
                try await service.refresh(stored)
            }
            adopt(refreshed)
        } catch {
            try? sessionStore.clear()
            session = nil
            state = .signedOut(.sessionExpired)
        }
    }

    /// Checks whether the user revoked Apple access in iOS Settings. Called on launch and
    /// on returning to the foreground.
    public func refreshAppleCredentialState() async {
        guard case .signedIn(let user) = state,
              user.signInMethod == .apple,
              let appleUserID = defaults.string(forKey: Self.appleUserIDKey)
        else { return }

        switch await credentialStateProvider.credentialState(forUserID: appleUserID) {
        case .revoked, .notFound:
            await clearLocalSession()
            state = .signedOut(.appleCredentialRevoked)
        case .authorized, .transferred, .unknown:
            break
        }
    }

    // MARK: - Sign in with Apple

    /// Configures the outgoing request. Apple receives the **hashed** nonce; the raw value
    /// is retained here for the token exchange.
    public func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let raw = Nonce.random()
        pendingNonce = raw
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256Hex(raw)
    }

    /// Handles the result delivered by `SignInWithAppleButton`.
    public func completeAppleSignIn(_ result: Result<ASAuthorization, any Error>) async {
        guard let rawNonce = pendingNonce else {
            state = .signedOut(.malformedAppleCredential)
            return
        }
        pendingNonce = nil

        switch result {
        case .failure(let error):
            let isCancellation = (error as? ASAuthorizationError)?.code == .canceled
            state = .signedOut(isCancellation ? nil : .server(error.localizedDescription))

        case .success(let authorization):
            guard let credential = AppleCredential.from(authorization, rawNonce: rawNonce) else {
                state = .signedOut(.malformedAppleCredential)
                return
            }
            await handleAppleCredential(credential)
        }
    }

    /// Token exchange. Separated from the framework plumbing above so it can be tested
    /// directly — `ASAuthorization` cannot be constructed outside AuthenticationServices.
    func handleAppleCredential(_ credential: AppleCredential) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let session = try await service.signInWithApple(credential)
            // Needed later by `refreshAppleCredentialState`; Apple's user id is not part
            // of the session we get back.
            defaults.set(credential.userID, forKey: Self.appleUserIDKey)
            adopt(session)
        } catch let error as AuthError {
            state = .signedOut(error.isSilent ? nil : error)
        } catch {
            state = .signedOut(.network)
        }
    }

    // MARK: - Anonymous

    /// "Skip for now". Remembered, so the login screen doesn't reappear every launch.
    public func skipSignIn() {
        defaults.set(true, forKey: Self.skippedSignInKey)
        state = .anonymous
    }

    /// Returns an anonymous user to the login screen so they can create an account.
    public func presentSignIn() {
        state = .signedOut(nil)
    }

    // MARK: - Sign out

    /// Always clears local state, even when the server call fails. A sign-out that leaves
    /// a usable token behind because the network was down is a security bug.
    public func signOut() async {
        isBusy = true
        defer { isBusy = false }

        try? await service.signOut()
        await clearLocalSession()

        // Signing out is an explicit choice to leave; don't drop into anonymous mode.
        defaults.set(false, forKey: Self.skippedSignInKey)
        state = .signedOut(nil)
    }

    // MARK: - Helpers

    private func adopt(_ session: AuthSession) {
        self.session = session
        try? sessionStore.save(session)
        // A successful sign-in supersedes any earlier decision to skip.
        defaults.set(false, forKey: Self.skippedSignInKey)
        state = .signedIn(session.user)
    }

    private func clearLocalSession() async {
        session = nil
        pendingNonce = nil
        try? sessionStore.clear()
        defaults.removeObject(forKey: Self.appleUserIDKey)
    }

    private func signedOutOrAnonymous() -> AuthState {
        defaults.bool(forKey: Self.skippedSignInKey) ? .anonymous : .signedOut(nil)
    }
}

// MARK: - Timeout

nonisolated enum TimeoutError: Error { case timedOut }

/// Runs `operation`, failing with `TimeoutError` if it outlives `duration`.
nonisolated func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError.timedOut
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw TimeoutError.timedOut }
        return result
    }
}
