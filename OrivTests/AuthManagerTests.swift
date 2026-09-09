//
//  AuthManagerTests.swift
//  OrivTests
//
//  Covers the state machine in AUTH_DESIGN.md §3.1 and the rules in §4.1 and §14.
//

import XCTest
@testable import Oriv

@MainActor
final class AuthManagerTests: XCTestCase {

    // MARK: - Fixtures

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AuthManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeProfile(
        id: UUID = UUID(),
        email: String? = "runner@example.com",
        displayName: String? = "Sam Runner"
    ) -> UserProfile {
        UserProfile(
            id: id,
            email: email,
            displayName: displayName,
            signInMethod: .apple,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeSession(expiresIn: TimeInterval = 3600) -> AuthSession {
        AuthSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(expiresIn),
            user: makeProfile()
        )
    }

    private func makeCredential(
        userID: String = "apple-user-1",
        email: String? = "runner@example.com",
        fullName: String? = "Sam Runner"
    ) -> AppleCredential {
        AppleCredential(
            userID: userID,
            identityToken: "token",
            rawNonce: "raw-nonce",
            email: email,
            fullName: fullName
        )
    }

    private func makeManager(
        service: any AuthService = InMemoryAuthService(),
        store: any SessionStoring = InMemorySessionStore(),
        credentialState: AppleCredentialState = .authorized,
        restoreTimeout: Duration = .seconds(5)
    ) -> AuthManager {
        AuthManager(
            service: service,
            sessionStore: store,
            credentialStateProvider: StubAppleCredentialStateProvider(credentialState),
            defaults: defaults,
            restoreTimeout: restoreTimeout
        )
    }

    // MARK: - Restore

    func testRestoreWithNoStoredSessionShowsLogin() async {
        let manager = makeManager()
        await manager.restoreSession()
        XCTAssertEqual(manager.state, .signedOut(nil))
    }

    func testRestoreWithNoSessionButPreviouslySkippedGoesAnonymous() async {
        defaults.set(true, forKey: "auth.hasSkippedSignIn")

        let manager = makeManager()
        await manager.restoreSession()

        XCTAssertEqual(manager.state, .anonymous,
                       "A user who skipped should not face the login wall again on every launch")
    }

    func testRestoreWithValidSessionSignsIn() async {
        let session = makeSession()
        let manager = makeManager(store: InMemorySessionStore(initial: session))

        await manager.restoreSession()

        XCTAssertEqual(manager.state, .signedIn(session.user))
        XCTAssertEqual(manager.currentUser?.id, session.user.id)
    }

    func testRestoreWithExpiredSessionRefreshes() async {
        let expired = makeSession(expiresIn: -60)
        let manager = makeManager(store: InMemorySessionStore(initial: expired))

        await manager.restoreSession()

        guard case .signedIn = manager.state else {
            return XCTFail("Expected a refreshed session, got \(manager.state)")
        }
    }

    func testRestoreWithFailedRefreshSignsOutAndClearsTheKeychain() async {
        let store = InMemorySessionStore(initial: makeSession(expiresIn: -60))
        let manager = makeManager(
            service: InMemoryAuthService(behaviour: .fail(.network)),
            store: store
        )

        await manager.restoreSession()

        XCTAssertEqual(manager.state, .signedOut(.sessionExpired))
        XCTAssertNil(store.peek, "A session that cannot be refreshed must not be left behind")
    }

    func testRestoreIsBoundedByTimeout() async {
        let manager = makeManager(
            service: InMemoryAuthService(behaviour: .succeedAfter(.seconds(30))),
            store: InMemorySessionStore(initial: makeSession(expiresIn: -60)),
            restoreTimeout: .milliseconds(150)
        )

        let start = ContinuousClock.now
        await manager.restoreSession()
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(manager.state, .signedOut(.sessionExpired))
        XCTAssertLessThan(elapsed, .seconds(5),
                          "Restore must never strand the user on the splash screen")
    }

    func testRestoreSurvivesAnUnreadableKeychain() async {
        let manager = makeManager(
            store: InMemorySessionStore(failure: KeychainSessionStore.KeychainError.missingEntitlement)
        )

        await manager.restoreSession()

        XCTAssertEqual(manager.state, .signedOut(nil),
                       "An unreadable keychain is indistinguishable from an empty one")
    }

    // MARK: - Apple sign-in

    func testSuccessfulAppleSignInStoresTheSession() async {
        let store = InMemorySessionStore()
        let manager = makeManager(store: store)

        await manager.handleAppleCredential(makeCredential())

        guard case .signedIn(let user) = manager.state else {
            return XCTFail("Expected signed in, got \(manager.state)")
        }
        XCTAssertEqual(user.displayName, "Sam Runner")
        XCTAssertEqual(user.signInMethod, .apple)
        XCTAssertNotNil(store.peek, "The session must be persisted for the next launch")
        XCTAssertFalse(manager.isBusy)
    }

    /// Apple returns name and email on the first authorization only. A later `nil` must
    /// never overwrite what was captured — there is no API to recover it.
    func testSecondAppleSignInDoesNotEraseTheCapturedName() async {
        let service = InMemoryAuthService()
        let manager = makeManager(service: service)

        await manager.handleAppleCredential(makeCredential(fullName: "Sam Runner"))
        XCTAssertEqual(manager.currentUser?.displayName, "Sam Runner")

        // Apple sends nil for both on every subsequent sign-in.
        await manager.handleAppleCredential(makeCredential(email: nil, fullName: nil))

        XCTAssertEqual(manager.currentUser?.displayName, "Sam Runner",
                       "A repeat sign-in must not destroy the one-shot name")
        XCTAssertEqual(manager.currentUser?.email, "runner@example.com",
                       "A repeat sign-in must not destroy the captured email")
    }

    func testRepeatAppleSignInResolvesToTheSameUser() async {
        let manager = makeManager()

        await manager.handleAppleCredential(makeCredential())
        let firstID = manager.currentUser?.id

        await manager.handleAppleCredential(makeCredential(email: nil, fullName: nil))

        XCTAssertEqual(manager.currentUser?.id, firstID)
    }

    func testFailedAppleSignInSurfacesTheError() async {
        let manager = makeManager(service: InMemoryAuthService(behaviour: .fail(.network)))

        await manager.handleAppleCredential(makeCredential())

        XCTAssertEqual(manager.state, .signedOut(.network))
    }

    func testCancelledSignInIsNotShownAsAnError() async {
        let manager = makeManager(service: InMemoryAuthService(behaviour: .fail(.cancelled)))

        await manager.handleAppleCredential(makeCredential())

        XCTAssertEqual(manager.state, .signedOut(nil),
                       "Cancelling is a normal outcome, not a failure to report")
    }

    func testSigningInClearsAPreviousSkip() async {
        let manager = makeManager()
        manager.skipSignIn()
        XCTAssertTrue(defaults.bool(forKey: "auth.hasSkippedSignIn"))

        await manager.handleAppleCredential(makeCredential())

        XCTAssertFalse(defaults.bool(forKey: "auth.hasSkippedSignIn"))
    }

    // MARK: - Anonymous

    // Async deliberately. Constructing an app-module `@Observable` type inside a
    // *synchronous* XCTest method reliably crashes this toolchain with
    // "pointer being freed was not allocated" — construction alone is enough, with no
    // method calls. The same construction in an async test is fine, and the app only ever
    // builds these from SwiftUI state, so this is a harness artifact rather than a product
    // bug. Do not "simplify" these back to synchronous tests.
    func testSkipSignInGoesAnonymousAndRemembers() async {
        let manager = makeManager()

        manager.skipSignIn()

        XCTAssertEqual(manager.state, .anonymous)
        XCTAssertTrue(defaults.bool(forKey: "auth.hasSkippedSignIn"))
    }

    /// Async for the same toolchain reason as above.
    func testPresentSignInReturnsAnAnonymousUserToLogin() async {
        let manager = makeManager()
        manager.skipSignIn()

        manager.presentSignIn()

        XCTAssertEqual(manager.state, .signedOut(nil))
    }

    func testAnonymousAndSignedInBothShowTheApp() {
        XCTAssertTrue(AuthState.anonymous.showsApp)
        XCTAssertTrue(AuthState.signedIn(makeProfile()).showsApp)
        XCTAssertFalse(AuthState.loading.showsApp)
        XCTAssertFalse(AuthState.signedOut(nil).showsApp)
    }

    // MARK: - Sign out

    func testSignOutClearsStateAndStorage() async {
        let store = InMemorySessionStore(initial: makeSession())
        let manager = makeManager(store: store)
        await manager.restoreSession()

        await manager.signOut()

        XCTAssertEqual(manager.state, .signedOut(nil))
        XCTAssertNil(store.peek)
        XCTAssertNil(manager.currentUser)
    }

    /// A sign-out that leaves a usable token behind because the network was down is a
    /// security bug, not a retryable failure.
    func testSignOutClearsLocalStateEvenWhenTheServerCallFails() async {
        let store = InMemorySessionStore(initial: makeSession())
        let manager = makeManager(
            service: InMemoryAuthService(behaviour: .fail(.network)),
            store: store
        )
        await manager.restoreSession()

        await manager.signOut()

        XCTAssertEqual(manager.state, .signedOut(nil))
        XCTAssertNil(store.peek, "Local credentials must be destroyed regardless of the server")
    }

    func testSignOutDoesNotFallBackIntoAnonymousMode() async {
        let manager = makeManager()
        manager.skipSignIn()
        await manager.handleAppleCredential(makeCredential())

        await manager.signOut()

        XCTAssertEqual(manager.state, .signedOut(nil),
                       "Signing out is an explicit choice to leave, not to go anonymous")
    }

    // MARK: - Apple credential revocation

    func testRevokedAppleCredentialSignsTheUserOut() async {
        let store = InMemorySessionStore()
        let manager = makeManager(store: store, credentialState: .revoked)
        await manager.handleAppleCredential(makeCredential())

        await manager.refreshAppleCredentialState()

        XCTAssertEqual(manager.state, .signedOut(.appleCredentialRevoked))
        XCTAssertNil(store.peek)
    }

    func testAuthorizedAppleCredentialLeavesTheSessionAlone() async {
        let manager = makeManager(credentialState: .authorized)
        await manager.handleAppleCredential(makeCredential())

        await manager.refreshAppleCredentialState()

        guard case .signedIn = manager.state else {
            return XCTFail("Expected to stay signed in, got \(manager.state)")
        }
    }

    func testCredentialCheckIsANoOpWhenSignedOut() async {
        let manager = makeManager(credentialState: .revoked)
        await manager.restoreSession()

        await manager.refreshAppleCredentialState()

        XCTAssertEqual(manager.state, .signedOut(nil))
    }

    // MARK: - Unconfigured builds

    /// A build with no Supabase configuration must refuse sign-in rather than hand back a
    /// convincing fake session.
    func testUnconfiguredServiceRefusesSignIn() async {
        let store = InMemorySessionStore()
        let manager = makeManager(service: UnconfiguredAuthService(), store: store)

        await manager.handleAppleCredential(makeCredential())

        guard case .signedOut(let error) = manager.state else {
            return XCTFail("Expected to stay signed out, got \(manager.state)")
        }
        XCTAssertNotNil(error, "The failure must be visible, not silent")
        XCTAssertNil(store.peek, "Nothing may be persisted for a sign-in that did not happen")
        XCTAssertNil(manager.currentUser)
    }

    /// Anonymous use must survive a missing configuration — the app still works offline.
    func testUnconfiguredServiceStillAllowsAnonymousUse() async {
        let manager = makeManager(service: UnconfiguredAuthService())

        manager.skipSignIn()

        XCTAssertEqual(manager.state, .anonymous)
    }

    /// Sign-out must always clear local state, even with no backend to talk to.
    func testUnconfiguredServiceStillSignsOutCleanly() async {
        let store = InMemorySessionStore(initial: makeSession())
        let manager = makeManager(service: UnconfiguredAuthService(), store: store)
        await manager.restoreSession()

        await manager.signOut()

        XCTAssertEqual(manager.state, .signedOut(nil))
        XCTAssertNil(store.peek)
    }

    // MARK: - Error copy

    /// Distinguishing "no such account" from "wrong password" leaks which emails are
    /// registered. One case makes that structurally impossible.
    func testInvalidCredentialsCopyDoesNotRevealAccountExistence() {
        let message = AuthError.invalidCredentials.errorDescription ?? ""

        XCTAssertFalse(message.localizedCaseInsensitiveContains("no account"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("not found"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("incorrect password"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("wrong password"))
    }

    func testCancellationHasNoUserFacingMessage() {
        XCTAssertNil(AuthError.cancelled.errorDescription)
        XCTAssertTrue(AuthError.cancelled.isSilent)
        XCTAssertFalse(AuthError.network.isSilent)
    }
}
