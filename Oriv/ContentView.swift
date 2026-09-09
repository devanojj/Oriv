//
//  ContentView.swift
//  Oriv
//
//  Dashboard host. Chooses which of the mutually exclusive states to present.
//

import SwiftUI

struct ContentView: View {
    let auth: AuthManager

    @State private var viewModel = AppViewModel()
    @State private var isShowingProfile = false
    @Environment(\.scenePhase) private var scenePhase

    /// One of these, and only one, is on screen at a time.
    private enum Screen: Equatable {
        case loading
        case unavailable
        case needsAuthorization
        case noDataVisible
        case buildingBaseline(String)
        case stale(daysAgo: Int)
        case score(ReadinessResult)
    }

    private var screen: Screen {
        switch viewModel.healthKitManager.accessState {
        case .unavailable:
            return .unavailable
        case .needsAuthorization:
            return .needsAuthorization
        case .noDataVisible:
            return .noDataVisible
        case .unknown, .authorized:
            break
        }

        guard let result = viewModel.calculatedResult else {
            return .loading
        }

        switch result.status {
        case .scored:
            return .score(result)
        case .insufficientBaseline:
            return .buildingBaseline(result.recommendation)
        case .staleData(let daysAgo):
            return .stale(daysAgo: daysAgo)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    dateHeader

                    if let errorMessage = viewModel.healthKitManager.errorMessage {
                        errorBanner(errorMessage)
                    }

                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Theme.canvas)
            .scrollContentBackground(.hidden)
            .navigationTitle("Oriv")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingProfile = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityLabel("Account")
                }
            }
            .sheet(isPresented: $isShowingProfile) {
                ProfileView(auth: auth)
            }
            .refreshable {
                await viewModel.loadAndCalculateReadiness()
            }
            .task {
                if viewModel.calculatedResult == nil {
                    await viewModel.loadAndCalculateReadiness()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await viewModel.loadAndCalculateReadiness() }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .loading:
            loadingView

        case .unavailable:
            StatusCardView.unavailable()

        case .needsAuthorization:
            StatusCardView.needsAuthorization {
                Task { await viewModel.requestHealthAccess() }
            }

        case .noDataVisible:
            StatusCardView.noDataVisible(onOpenSettings: SettingsLink.open)

        case .buildingBaseline(let message):
            StatusCardView.buildingBaseline(message: message)

        case .stale(let daysAgo):
            StatusCardView.staleData(daysAgo: daysAgo, onOpenSettings: SettingsLink.open)

        case .score(let result):
            ReadinessHeroView(result: result, recencyNote: viewModel.recencyNote)

            VitalsGridCardView(
                breakdown: result.breakdown,
                recencies: viewModel.metricRecencies,
                healthKitManager: viewModel.healthKitManager
            )
        }
    }

    // MARK: - Subviews

    private var dateHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)

                Text(Date.now, format: .dateTime.month(.wide).day())
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.top, 4)
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

    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.textTertiary)

            Text("Analyzing biometrics…")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity)
        .orivCard()
    }
}

private func previewAuth() -> AuthManager {
    AuthManager(service: InMemoryAuthService(), sessionStore: InMemorySessionStore())
}

#Preview("Light") {
    ContentView(auth: previewAuth())
}

#Preview("Dark") {
    ContentView(auth: previewAuth())
        .preferredColorScheme(.dark)
}
