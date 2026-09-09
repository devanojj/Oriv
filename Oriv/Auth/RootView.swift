//
//  RootView.swift
//  Oriv
//
//  The auth gate. `ContentView` and the readiness pipeline beneath it are unchanged and
//  have no knowledge that authentication exists — the only coupling is lifecycle, owned here.
//

import SwiftUI

struct RootView: View {
    @State private var auth = AuthManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                SplashView()

            case .signedOut(let error):
                LoginView(auth: auth, error: error)

            case .anonymous, .signedIn:
                ContentView(auth: auth)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.state)
        .task {
            await auth.restoreSession()
            await auth.refreshAppleCredentialState()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Catches access revoked in iOS Settings while the app was backgrounded.
            guard newPhase == .active else { return }
            Task { await auth.refreshAppleCredentialState() }
        }
    }
}

// MARK: - Splash

struct SplashView: View {
    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(Theme.good)

                ProgressView()
                    .controlSize(.regular)
                    .tint(Theme.textTertiary)
            }
        }
        .accessibilityLabel("Loading Oriv")
    }
}

#Preview("Splash") {
    SplashView()
}
