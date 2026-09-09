//
//  LoginView.swift
//  Oriv
//
//  M1 offers Sign in with Apple and a skip path. Google (M4) and email/password (M3) slot
//  in below the Apple button — placed there deliberately: Apple's HIG requires the Sign in
//  with Apple button to appear above other sign-in options, and Guideline 4.8 requires it
//  to be offered at all once Google is added.
//

import SwiftUI
import AuthenticationServices

struct LoginView: View {
    let auth: AuthManager
    var error: AuthError?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 48)

                    header

                    Spacer(minLength: 40)

                    if let message = error?.errorDescription {
                        errorBanner(message)
                            .padding(.bottom, 16)
                    }

                    signInControls

                    Spacer(minLength: 32)

                    footer
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.good.opacity(0.12))
                    .frame(width: 88, height: 88)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(Theme.good)
            }

            VStack(spacing: 8) {
                Text("Oriv")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                Text("Your daily readiness score, from the health data your devices already collect.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
    }

    private var signInControls: some View {
        VStack(spacing: 14) {
            SignInWithAppleButton(
                .signIn,
                onRequest: auth.prepareAppleRequest,
                onCompletion: { result in
                    Task { await auth.completeAppleSignIn(result) }
                }
            )
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .disabled(auth.isBusy)

            Button {
                auth.skipSignIn()
            } label: {
                Text("Skip for now")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    // `orivCard`, not `cardInset`: this button sits directly on the canvas,
                    // and cardInset is identical to the canvas in light mode.
                    .orivCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)
            .disabled(auth.isBusy)

            Text("Oriv works without an account. Signing in will let you keep your history across devices.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 2)
        }
    }

    private var footer: some View {
        // TODO(M2): point these at the published policy and terms URLs. Both are required
        // before release — see AUTH_DESIGN.md §10.
        HStack(spacing: 4) {
            Text("By continuing you agree to our")
            Text("Terms").underline()
            Text("and")
            Text("Privacy Policy").underline()
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.textTertiary)
        .multilineTextAlignment(.center)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.poor)

            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.poor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview("Login") {
    LoginView(auth: AuthManager(service: InMemoryAuthService(), sessionStore: InMemorySessionStore()))
}

#Preview("Login — session expired, dark") {
    LoginView(
        auth: AuthManager(service: InMemoryAuthService(), sessionStore: InMemorySessionStore()),
        error: .sessionExpired
    )
    .preferredColorScheme(.dark)
}
