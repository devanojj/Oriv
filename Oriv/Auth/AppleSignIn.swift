//
//  AppleSignIn.swift
//  Oriv
//
//  Sign in with Apple support types.
//
//  `ASAuthorizationAppleIDCredential` cannot be constructed outside the framework, so the
//  testable boundary is drawn at `AppleCredential`: the view converts the framework type
//  into one of these, and everything downstream — nonce pairing, first-authorization name
//  capture, error mapping — is ordinary testable code.
//

import Foundation
import AuthenticationServices
import CryptoKit

// MARK: - Credential

public nonisolated struct AppleCredential: Sendable, Equatable {
    /// Apple's stable per-app user identifier. This, not the email, is the identity.
    public let userID: String
    public let identityToken: String
    /// The **raw** nonce. Its SHA256 hash is what went to Apple; the raw value is what the
    /// backend needs in order to verify the token. See `Nonce`.
    public let rawNonce: String
    /// Present on the first authorization only.
    public let email: String?
    /// Present on the first authorization only, already formatted for display.
    public let fullName: String?

    public init(
        userID: String,
        identityToken: String,
        rawNonce: String,
        email: String?,
        fullName: String?
    ) {
        self.userID = userID
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.email = email
        self.fullName = fullName
    }
}

// MARK: - Nonce

/// Replay protection for the Apple identity token.
///
/// The direction matters and is easy to get backwards: Apple receives the **hash**, the
/// backend receives the **raw** value and checks that hashing it reproduces the `nonce`
/// claim inside the signed token. Swapping them fails with an opaque server error.
public nonisolated enum Nonce {

    /// Cryptographically random, URL-safe.
    public static func random(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

        var result = ""
        result.reserveCapacity(length)

        while result.count < length {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else {
                // SecRandomCopyBytes does not fail in practice; if it ever does, failing
                // loudly beats silently degrading to a predictable nonce.
                preconditionFailure("SecRandomCopyBytes failed: \(status)")
            }
            // Reject bytes above the largest exact multiple of the charset size, so the
            // distribution across characters stays uniform.
            if byte < (255 - (255 % UInt8(charset.count))) {
                result.append(charset[Int(byte) % charset.count])
            }
        }
        return result
    }

    /// Lowercase hex SHA256 — the form Apple expects in `ASAuthorizationAppleIDRequest.nonce`.
    public static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

// MARK: - Credential state

public nonisolated enum AppleCredentialState: Sendable, Equatable {
    case authorized
    case revoked
    case notFound
    case transferred
    case unknown
}

/// Wraps `ASAuthorizationAppleIDProvider.getCredentialState` so it can be faked in tests.
public nonisolated protocol AppleCredentialStateProviding: Sendable {
    func credentialState(forUserID userID: String) async -> AppleCredentialState
}

public nonisolated struct LiveAppleCredentialStateProvider: AppleCredentialStateProviding {
    public init() {}

    public func credentialState(forUserID userID: String) async -> AppleCredentialState {
        await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userID) { state, _ in
                let mapped: AppleCredentialState
                switch state {
                case .authorized:   mapped = .authorized
                case .revoked:      mapped = .revoked
                case .notFound:     mapped = .notFound
                case .transferred:  mapped = .transferred
                @unknown default:   mapped = .unknown
                }
                continuation.resume(returning: mapped)
            }
        }
    }
}

/// Test double.
public nonisolated struct StubAppleCredentialStateProvider: AppleCredentialStateProviding {
    private let state: AppleCredentialState

    public init(_ state: AppleCredentialState) {
        self.state = state
    }

    public func credentialState(forUserID userID: String) async -> AppleCredentialState {
        state
    }
}

// MARK: - Framework bridging

nonisolated extension AppleCredential {
    /// Converts the framework credential, pairing it with the raw nonce held by `AuthManager`.
    /// Returns `nil` when Apple hands back something unusable.
    static func from(
        _ authorization: ASAuthorization,
        rawNonce: String
    ) -> AppleCredential? {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let identityToken = String(data: tokenData, encoding: .utf8)
        else {
            return nil
        }

        return AppleCredential(
            userID: credential.user,
            identityToken: identityToken,
            rawNonce: rawNonce,
            email: credential.email,
            fullName: credential.fullName.flatMap(Self.formatted)
        )
    }

    /// Apple supplies structured name components; store a display string.
    static func formatted(_ components: PersonNameComponents) -> String? {
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
