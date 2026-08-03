//
//  ContentView.swift
//  Oriv
//
//  Oriv — Premium light-mode dashboard host.
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase
    
    // Soft warm off-white canvas
    private let canvasColor = Color(red: 0.97, green: 0.97, blue: 0.98)
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Date header
                    dateHeader
                    
                    // Error Banner
                    if let errorMessage = viewModel.healthKitManager.errorMessage {
                        errorBanner(errorMessage)
                    }
                    
                    // Main Content
                    if let result = viewModel.calculatedResult {
                        if result.insufficientData {
                            InsufficientDataHeroView(recommendation: result.recommendation)
                        } else {
                            ReadinessHeroView(
                                result: result,
                                recencyNote: viewModel.recencyNote
                            )
                            
                            VitalsGridCardView(
                                breakdown: result.breakdown,
                                recencies: viewModel.metricRecencies,
                                healthKitManager: viewModel.healthKitManager
                            )
                        }
                    } else if viewModel.healthKitManager.isLoading {
                        loadingView
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(canvasColor)
            .navigationTitle("Oriv")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(canvasColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .refreshable {
                await viewModel.loadAndCalculateReadiness()
            }
            .task {
                if viewModel.calculatedResult == nil {
                    await viewModel.loadAndCalculateReadiness()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await viewModel.loadAndCalculateReadiness()
                    }
                }
            }
        }
    }
    
    // MARK: - Subviews
    
    private var dateHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now, format: .dateTime.weekday(.wide))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .textCase(.uppercase)
                
                Text(Date.now, format: .dateTime.month(.wide).day())
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            Spacer()
        }
        .padding(.top, 4)
    }
    
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.92, green: 0.30, blue: 0.28))
            
            Text(message)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.92, green: 0.30, blue: 0.28).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    private var loadingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(Color(uiColor: .tertiaryLabel))
            
            Text("Analyzing biometrics…")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(48)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}

#Preview {
    ContentView()
}
