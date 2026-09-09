# Design: Oriv Authentication

Status: **M1 IMPLEMENTED** (backend pending) · M2–M5 proposed.
M1 shipped against `InMemoryAuthService`; the Supabase project and `SupabaseAuthService`
are the remaining work. See §17.
Companion to [PROJECT.md](PROJECT.md). Covers accounts, sign-in, sign-out, and account deletion.

---

## 1. Context and motivation

Oriv today is entirely local: no networking, no backend, no data leaving the device. That is a
genuine feature for a health app, and adding accounts gives it up. This document assumes accounts
are being added to enable **cross-device sync and history beyond the 90-day HealthKit window**. If
that is not the goal, the cheapest correct design is to add no auth at all.

Everything below follows from that assumption. If the goal changes, revisit §2.

### Non-goals

- Multi-user support on a single device (see §9.1 — HealthKit makes this incoherent).
- Social features, sharing, or coach/athlete relationships.
- Offline-first conflict resolution. Phase 1 is auth only; sync is deferred to M5.
- Server-side recomputation of readiness. `ReadinessEngine` stays on-device.

---

## 2. Decision: Supabase

**Chosen: Supabase Auth + Postgres**, EU region.

| Reason | Detail |
|--------|--------|
| One system, three methods | Apple, Google, and email/password without three separate integrations. |
| Postgres underneath | Needed anyway for sync. Row-Level Security maps directly onto "a user sees only their rows". |
| Data residency | Region is selectable at project creation — matters for health data under GDPR. |
| Exit path | Open source and self-hostable. |
| Owns the dangerous parts | Password hashing, reset emails, verification, JWT issuance and rotation. |

> **Region is fixed at project creation.** Choose the EU region up front; migrating later means a
> full project migration.

### Alternatives considered

| Option | Why not |
|--------|---------|
| **Firebase Auth** | Fine for auth itself. Rejected because Firestore is awkward for time-series health data, per-read pricing is unpredictable, and data residency is less controllable. |
| **Sign in with Apple + CloudKit** | No backend, no password storage, no server bill, data stays in the user's own iCloud. Rejected because it forecloses Google sign-in and non-Apple platforms. ⚠️ Also **verify Apple's current position on storing HealthKit-derived data in iCloud** before ever revisiting this — historically restricted. |
| **Auth0 / Clerk / Cognito** | Auth0 costs escalate; Clerk is web-first; Cognito's DX is poor. None bring the database we need. |
| **Roll our own passwords** | Hashing, rate limiting, reset-token expiry, user enumeration, breach response. Large security surface for something that is not our product. |

### Dependency consequence

Adding `supabase-swift` **ends the project's zero-dependency property.** README and PROJECT.md must
be updated when this lands — the claim currently appears in both.

This changes one earlier calculation: since a dependency is being added regardless, the argument for
hand-rolling Google OAuth to avoid the GoogleSignIn SDK weakens. See §4.2 for the resolution.

---

## 3. Architecture

Auth is a **gate wrapping the existing app**. The readiness pipeline does not learn that auth exists.

```
┌─────────────────────────────────────────────────────────┐
│ OrivApp                                                 │
│   └── RootView          ← switches on AuthState         │
│         ├── .loading    → SplashView                    │
│         ├── .signedOut  → LoginView                     │
│         ├── .anonymous  → ContentView  (UNCHANGED)      │
│         └── .signedIn   → ContentView  (UNCHANGED)      │
│                              └── Screen enum, as today  │
│                                                         │
│   AuthManager (@Observable @MainActor)                  │
│     ├── AuthService      (Supabase / InMemory)          │
│     ├── SessionStoring   (Keychain)                     │
│     └── AppleCredentialStateProviding                   │
└─────────────────────────────────────────────────────────┘
```

`AuthManager` deliberately mirrors `HealthKitManager`: `@Observable`, `@MainActor`, owns one external
system, publishes one state enum that a view switches on. The existing `Screen` enum in
`ContentView` is untouched and simply nests under `.signedIn`.

### 3.1 State machine

```swift
enum AuthState: Equatable {
    case loading                  // restoring a session from Keychain at launch
    case anonymous                // "Skip for now" — the app works exactly as before accounts
    case signedOut(AuthError?)    // includes the reason, so LoginView can explain itself
    case signedIn(UserProfile)
}
```

`.anonymous` exists because §15.2 was resolved in its favour: M1 adds nothing a user can
see, so a hard signup wall would remove functionality for zero benefit.

Transitions:

| From | Event | To |
|------|-------|-----|
| `.loading` | Valid session restored | `.signedIn` |
| `.loading` | No session, never skipped | `.signedOut(nil)` |
| `.loading` | No session, previously skipped | `.anonymous` |
| `.signedOut` | Any sign-in succeeds | `.signedIn` |
| `.signedOut` | "Skip for now" | `.anonymous` |
| `.anonymous` | Taps Sign In in ProfileView | `.signedOut(nil)` |
| `.signedIn` | User signs out | `.signedOut(nil)` — never `.anonymous` |
| `.signedIn` | Refresh token rejected | `.signedOut(.sessionExpired)` |
| `.signedIn` | Apple credential revoked | `.signedOut(.appleCredentialRevoked)` |
| `.signedIn` | Account deleted | `.signedOut(nil)` |

`.loading` must be **bounded** — cap session restore at ~5s and fall through to `.signedOut` rather
than leaving users on a splash screen forever when the network is bad.

---

## 4. Sign-in methods

### 4.1 Sign in with Apple

Native, via `AuthenticationServices` → `supabase.auth.signInWithIdToken(.apple, idToken:, nonce:)`.

Two failure modes that catch nearly everyone:

1. **Name and email arrive only on the first authorization.** Every subsequent sign-in returns `nil`
   for both. They must be persisted to `profiles` on first success or they are gone permanently.
   There is no API to retrieve them later.
2. **Nonce direction.** Generate a random nonce; send its **SHA256 hash** to Apple in
   `request.nonce`; send the **raw** nonce to Supabase. Reversing these fails with an unhelpful
   error.

Also required:
- "Sign in with Apple" capability in `Oriv.entitlements` and the Developer portal.
- Bundle ID registered as an authorized client ID in Supabase's Apple provider config.
- `getCredentialState(forUserID:)` checked on launch and on foreground, to catch users who revoked
  access in iOS Settings. On `.revoked` or `.notFound`, sign out locally.
- Handle **private relay addresses** (`@privaterelay.appleid.com`). Never assume the email is
  reachable by anything other than Apple's relay, and never key user identity on email — key on the
  Supabase user UUID.

### 4.2 Google

**Use `supabase.auth.signInWithOAuth(provider: .google)`**, which runs the flow through
`ASWebAuthenticationSession`. No GoogleSignIn SDK.

Rationale: it avoids a second large dependency, and Supabase already owns the OAuth dance. The
tradeoff is a web consent sheet rather than the native Google account picker — slightly worse UX,
materially less to maintain. Revisit only if sign-in conversion measurably suffers.

Requires:
- A custom URL scheme (`com.oriv.health://auth-callback`) registered in `Info.plist`.
- That URL added to Supabase's redirect allowlist.
- `ASWebAuthenticationSession` presented with a `presentationContextProvider`; treat user
  cancellation as a non-error.

### 4.3 Email and password

`signUp(email:password:)` / `signIn(email:password:)` / `resetPasswordForEmail(_:)`.

- **Email verification required** before the account is usable. Enable "Confirm email" in Supabase.
- Password rules: minimum 8 characters, checked client-side for immediate feedback and server-side
  as the actual gate.
- Use `.textContentType(.newPassword)` on sign-up and `.password` on sign-in so iOS offers to
  generate and store a strong password in Keychain.
- Rely on Supabase's built-in auth rate limits; do not add a bespoke lockout.
- Error copy must **not** distinguish "no such account" from "wrong password" — that is a user
  enumeration leak.

### 4.4 App Store Guideline 4.8

Offering Google obliges us to also offer a login service that limits data collection to name and
email, allows email masking, and does not track. **Sign in with Apple satisfies this.**

Per Apple's HIG, the Sign in with Apple button is displayed **above** the other options.

---

## 5. Session and token handling

- Session lives in the **Keychain**, never `UserDefaults`.
- Supply a custom `AuthLocalStorage` to the Supabase client so the accessibility attribute can be
  set to **`kSecAttrAccessibleAfterFirstUnlock`**.
  > This is not optional. With the default `WhenUnlocked`, background HealthKit delivery cannot read
  > the token on a locked device, and background sync dies silently once M5 lands.
- Access token ~1 hour, refresh token long-lived; the SDK rotates automatically.
- Subscribe to `auth.authStateChanges` and map it onto `AuthState` — this is what catches token
  revocation and sign-out from another device.
- On refresh failure: transition to `.signedOut(.sessionExpired)` and show a specific message. Do
  not retry indefinitely.

---

## 6. Data model

Phase 1 needs exactly one table. Everything else is deferred.

### `profiles` (M1)

| Column | Type | Notes |
|--------|------|-------|
| `id` | `uuid` PK | FK → `auth.users.id`, `ON DELETE CASCADE` |
| `email` | `text` | May be an Apple private relay address |
| `display_name` | `text` NULL | Captured on first Apple authorization; never available again |
| `created_at` | `timestamptz` | |
| `updated_at` | `timestamptz` | |

Populated by a Postgres trigger on `auth.users` insert, so a profile row cannot be missed.

**RLS on, with `auth.uid() = id`** for select/update. No delete policy — deletion goes through §8.

### `readiness_scores` (M5, deferred)

`id`, `user_id`, `date`, `score`, `band`, `subscores jsonb`, `computed_at`.
Unique on `(user_id, date)`. RLS `auth.uid() = user_id`.

⚠️ This table stores **health-derived data**. It triggers privacy-label obligations (§10) and is the
reason the EU region matters. Do not create it before the sync design exists.

---

## 7. Screens

### LoginView

Logo → one-line value proposition → **Sign in with Apple** → **Continue with Google** → "or"
divider → email and password fields → primary button → "Forgot password?" → toggle to sign-up.
Terms and Privacy Policy links at the bottom.

Built from existing `Theme` tokens and `orivCard()`. `ThemeContrastTests` already enforces contrast
for any new colour token, so no new colours should be introduced outside `Theme`.

States: idle, submitting (buttons disabled, spinner), error (inline, not an alert).

### ProfileView (sheet)

Reached from a new toolbar button in `ContentView`. There is no settings screen today; this is it.

Email · sign-in method · member since · **Sign Out** · **Delete Account** (destructive role).

### Sign out

Confirmation dialog → `supabase.auth.signOut()` → clear Keychain → `stopObservingBackgroundUpdates()`
→ `.signedOut`.

Local HealthKit caches need no wiping in Phase 1: they are re-read from HealthKit on every launch
and never persisted. Once M5 caches server data locally, sign-out must clear that cache.

---

## 8. Account deletion — mandatory

**App Store Guideline 5.1.1(v): an app supporting account creation must let users initiate deletion
from within the app.** "Email support to delete" is a rejection. This is one of the most common
rejection reasons for apps adding accounts.

Deleting a Supabase auth user requires the `service_role` key, which **must never ship in the app**.
So deletion runs server-side:

```
ProfileView → confirm (type-to-confirm or two-step)
  → invoke Edge Function `delete-account` with the user's JWT
      → function verifies the JWT and extracts the caller's uid
      → deletes auth.users row (profiles cascades)
  → client clears Keychain → .signedOut
```

The Edge Function must derive the user id **from the verified JWT**, never from a request body
parameter — otherwise any user can delete any account.

Confirmation copy names what is destroyed and states that Health data on the device is unaffected.

### Data export (GDPR)

Ship alongside deletion: an Edge Function returning the user's rows as JSON. Cheap while the schema
is one table; painful to retrofit later.

---

## 9. HealthKit-specific consequences

### 9.1 HealthKit permission is device-level, not account-level

If two people sign into the same phone, both see the **same** Health data — the phone owner's.
Accounts do not partition health data, and no amount of app logic changes this.

**Decision: Oriv is single-user-per-device.** On sign-in with a *different* user id than the
previously stored one, wipe all locally cached derived data. Without this, user B sees user A's
cached scores, which is a real data leak between accounts.

### 9.2 Observer queries must be gated on auth

`HKObserverQuery` and background delivery currently run regardless of auth state. That is harmless
today. From M5, a background HealthKit update triggers a server upload, so the observer callback
must check for a valid session first and skip the upload otherwise — not attempt it with a dead
token.

`startObservingBackgroundUpdates()` should be called on entering `.signedIn` and
`stopObservingBackgroundUpdates()` on leaving it.

### 9.3 Guideline 5.1.3

HealthKit data may not be used for advertising, marketing, or data mining, nor disclosed to third
parties for those purposes. Relevant to any future analytics SDK — this rules out sending health
metrics to a general-purpose analytics provider.

---

## 10. Compliance and disclosure changes

Accounts change what Oriv can honestly claim. All of these must land **with** M1, not after:

- [ ] Privacy nutrition label in App Store Connect: now collecting email and user ID, and (from M5)
      linking health data to identity.
- [ ] Published privacy policy URL — required once data is collected. Linked from LoginView.
- [ ] Terms of service.
- [ ] **README's "No data leaves the device" and "Zero dependencies" claims are both now false** and
      must be rewritten.
- [ ] PROJECT.md architecture section updated with `supabase-swift`.
- [ ] Account deletion implemented and reachable (§8).
- [ ] Sign in with Apple offered alongside Google (§4.4).

---

## 11. Interface Contracts

### AuthManager ↔ SwiftUI Views

- `@Observable @MainActor final class AuthManager`
- `public private(set) var state: AuthState`: `.loading` / `.signedOut(AuthError?)` / `.signedIn(UserProfile)`. Drives `RootView`.
- `public var currentUser: UserProfile?`: Computed convenience; non-nil only when `.signedIn`.
- `public func restoreSession() async`: Called once at launch. Bounded by a timeout; always resolves out of `.loading`.
- `public func signInWithApple() async throws`: Presents `ASAuthorizationController`, exchanges the identity token, persists name/email on first authorization only.
- `public func signInWithGoogle() async throws`: Presents `ASWebAuthenticationSession` via Supabase OAuth. User cancellation is not an error.
- `public func signIn(email: String, password: String) async throws`
- `public func signUp(email: String, password: String) async throws`: Leaves the user unverified until the emailed link is followed.
- `public func resetPassword(email: String) async throws`
- `public func signOut() async`: Never throws — a failed network call must still clear local state.
- `public func deleteAccount() async throws`: Invokes the `delete-account` Edge Function, then signs out.
- `public func refreshAppleCredentialState() async`: Checks `getCredentialState`; signs out on revocation.

### AuthManager ↔ AppViewModel

The readiness pipeline has **no** dependency on `AuthManager`. The only coupling is lifecycle, owned
by `RootView`:

- Entering `.signedIn` → `AppViewModel.loadAndCalculateReadiness()` and `startObservingBackgroundUpdates()`.
- Leaving `.signedIn` → `stopObservingBackgroundUpdates()` and clear cached derived data (§9.1).

### AuthError

`.sessionExpired` · `.appleCredentialRevoked` · `.invalidCredentials` · `.emailNotVerified` ·
`.network` · `.cancelled` · `.server(String)`

`.invalidCredentials` must render identical copy for unknown-account and wrong-password (§4.3).

---

## 12. Feature Inventory

| # | Feature | Description | Milestone |
|---|---------|-------------|-----------|
| 1 | Supabase client | `supabase-swift` package, EU project, config via xcconfig — anon key only | M1 |
| 2 | Keychain session store | Custom `AuthLocalStorage`, `kSecAttrAccessibleAfterFirstUnlock` | M1 |
| 3 | AuthManager + AuthState | `@Observable @MainActor`, mirrors `HealthKitManager` shape | M1 |
| 4 | RootView gate | Switches on `AuthState`; `ContentView` unchanged beneath it | M1 |
| 5 | Sign in with Apple | Native, nonce-hashed, first-authorization name/email capture | M1 |
| 6 | `profiles` table + RLS | Trigger-populated, `auth.uid() = id` | M1 |
| 7 | Credential-state check | `getCredentialState` on launch and foreground | M1 |
| 8 | ProfileView + Sign Out | Toolbar entry point; the app's first settings surface | M1 |
| 9 | Account deletion | Edge Function deriving uid from the verified JWT | M2 |
| 10 | Data export | GDPR JSON export Edge Function | M2 |
| 11 | Email/password | Sign-up, verification, sign-in, reset | M3 |
| 12 | Google OAuth | `signInWithOAuth` via `ASWebAuthenticationSession` | M4 |
| 13 | Single-user-per-device | Wipe cached derived data on user-id change | M4 |
| 14 | Score sync | `readiness_scores`, auth-gated observer uploads | M5 |

## 13. Milestones

| # | Name | Scope | Dependencies | Status |
|---|------|-------|--------------|--------|
| M1 | Auth foundation + Apple | Keychain store, `AuthManager`, `RootView`, Sign in with Apple, `profiles` migration, ProfileView with sign-out. Smallest App Store-compliant slice: one method, no password storage, no 4.8 obligation. | None | **DONE**, except the Supabase client (§17) |
| M2 | Deletion and export | `delete-account` and `export-data` Edge Functions, in-app entry points. **Required before any public release with accounts.** | M1 | PLANNED |
| M3 | Email and password | Sign-up, email verification, sign-in, password reset | M1 | PLANNED |
| M4 | Google | OAuth via `ASWebAuthenticationSession`; 4.8 already satisfied by M1 | M1 | PLANNED |
| M5 | Score sync | `readiness_scores`, auth-gated background upload, local cache invalidation | M1–M4 | PLANNED |

Compliance items in §10 land with M1 and M2, not at the end.

## 14. Testing

`AuthManager` must be testable without a live Supabase project — put the client behind a protocol
and inject a fake, the same way `ReadinessEngine` is testable without a health store.

| Area | Cases |
|------|-------|
| State machine | Every transition in §3.1, including bounded `.loading` timeout |
| Apple first-auth | Name/email persisted on first authorization; absent on the second and not overwritten with `nil` |
| Nonce | Hashed nonce to Apple, raw nonce to Supabase |
| Sign-out | Clears Keychain even when the network call fails |
| User change | Cached derived data wiped when the user id differs (§9.1) |
| Error copy | Unknown-account and wrong-password produce identical messages |
| Deletion | Edge Function rejects a body-supplied uid that does not match the JWT |

## 15. Open questions

1. **What justifies the account?** §1 assumes sync and history. Confirm before M5, because M5 is
   where the cost lands.
2. ~~**Is anonymous use still possible?**~~ **Resolved: yes.** "Skip for now" is implemented and
   remembered across launches; a successful sign-in supersedes it, and signing out returns to the
   login screen rather than to anonymous mode.
3. **HealthKit data in iCloud** — resolve definitively if the CloudKit path is ever reconsidered (§2).
4. **Sync conflict policy** for M5: last-write-wins on `(user_id, date)` is probably sufficient
   given scores are deterministically recomputed from HealthKit, but confirm.

## 16. Code Layout

Auth lives in one folder rather than being split across `Auth/` and `Views/` as originally
sketched — the existing views are flat in `Oriv/`, and a half-migrated `Views/` folder would
have been worse than cohesion by feature.

```
Oriv/Auth/
  AuthModels.swift        # UserProfile, AuthSession, AuthError, AuthState
  AuthService.swift       # protocol + InMemoryAuthService
  SessionStore.swift      # SessionStoring, KeychainSessionStore, InMemorySessionStore
  AppleSignIn.swift       # AppleCredential, Nonce, credential-state provider
  AuthManager.swift       # @Observable @MainActor
  RootView.swift          # the gate + SplashView
  LoginView.swift
  ProfileView.swift
OrivTests/
  AuthManagerTests.swift
  AppleSignInTests.swift
supabase/migrations/
  0001_profiles.sql
```

---

## 17. Outstanding for M1

Everything above is built, tested and running. What remains needs a Supabase project:

1. Create the project — **EU region**, which cannot be changed later (§2).
2. Run `supabase/migrations/0001_profiles.sql`.
3. Configure the Apple provider: bundle id `com.oriv.health` as an authorized client id.
4. Add the `supabase-swift` SPM package.
5. Write `SupabaseAuthService: AuthService` — three methods, and the existing
   `AuthManagerTests` already pin the contract it must satisfy.
6. Swap `AuthManager.makeDefaultService()` to return it. A Release build currently emits a
   `#warning` until this is done.
7. Enable the **Sign in with Apple** capability for the App ID in the Developer portal. The
   entitlement is already in `Oriv.entitlements`; without the portal side, device signing
   will fail.

Only after step 6 does data leave the device — so the README's "no data leaves the device"
and "zero dependencies" claims are still accurate today, and must be rewritten as part of
that step (§10).
