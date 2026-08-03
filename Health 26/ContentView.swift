//
//  ContentView.swift
//  Health 26
//

import SwiftUI

struct ContentView: View {
    @State private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Header / Error Banner
                    if let errorMessage = viewModel.healthKitManager.errorMessage {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    
                    if let result = viewModel.calculatedResult {
                        if result.insufficientData {
                            // Insufficient Data View
                            VStack(spacing: 16) {
                                Image(systemName: "clock.arrow.2.circlepath")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.orange)
                                
                                Text("Building Your Baseline")
                                    .font(.title2.bold())
                                
                                Text(result.recommendation)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            .padding(28)
                            .frame(maxWidth: .infinity)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else if let score = result.score, let band = result.band {
                            // Main Readiness Gauge Card
                            VStack(spacing: 20) {
                                GaugeView(score: score, band: band)
                                
                                // Recency Status Line (e.g., "Based on HRV from July 23")
                                if let recencyNote = viewModel.recencyNote {
                                    HStack(spacing: 6) {
                                        Image(systemName: "calendar")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        Text(recencyNote)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                                
                                // Recommendation Banner
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("DAILY RECOMMENDATION")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text(band.rawValue)
                                            .font(.caption.weight(.bold))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .background(color(for: band).opacity(0.15))
                                            .foregroundStyle(color(for: band))
                                            .clipShape(Capsule())
                                    }
                                    
                                    Text(result.recommendation)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                }
                                .padding()
                                .background(Color(.systemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .padding(20)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            
                            // Metric Subscores Breakdown Section
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Metric Breakdown")
                                    .font(.title3.bold())
                                
                                LazyVStack(spacing: 12) {
                                    ForEach(result.breakdown) { metric in
                                        let recency = viewModel.metricRecencies.first(where: { $0.name == metric.name })
                                        MetricRowView(metric: metric, recency: recency)
                                    }
                                }
                            }
                        }
                    } else if viewModel.healthKitManager.isLoading {
                        VStack(spacing: 16) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Analyzing 90-Day Biometrics...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(40)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Oriv")
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
    
    private func color(for band: ReadinessBand) -> Color {
        switch band {
        case .ready: return .green
        case .good:  return .blue
        case .fair:  return .orange
        case .poor:  return .red
        }
    }
}

// MARK: - Gauge View

private struct GaugeView: View {
    let score: Int
    let band: ReadinessBand
    
    private var bandColor: Color {
        switch band {
        case .ready: return .green
        case .good:  return .blue
        case .fair:  return .orange
        case .poor:  return .red
        }
    }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(bandColor.opacity(0.15), lineWidth: 16)
            
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100.0)
                .stroke(
                    bandColor,
                    style: StrokeStyle(lineWidth: 16, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 1.0), value: score)
            
            VStack(spacing: 4) {
                Text("\(score)")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                
                Text(band.rawValue.uppercased())
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(bandColor)
                    .tracking(1.2)
            }
        }
        .frame(width: 190, height: 190)
        .padding(.vertical, 8)
    }
}

// MARK: - Metric Row View

private struct MetricRowView: View {
    let metric: MetricBreakdown
    let recency: MetricRecency?
    
    private var subscoreColor: Color {
        switch metric.subscore {
        case 80...100: return .green
        case 60...79:  return .blue
        case 40...59:  return .orange
        default:       return .red
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(metric.name)
                    .font(.headline)
                
                if let recency = recency, recency.daysAgo > 0 {
                    Text("\(recency.daysAgo)d ago")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                
                Spacer()
                
                Text("\(metric.subscore)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(subscoreColor)
                Text("/ 100")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 8)
                    
                    Capsule()
                        .fill(subscoreColor)
                        .frame(width: max(0, geometry.size.width * CGFloat(metric.subscore) / 100.0), height: 8)
                }
            }
            .frame(height: 8)
            
            HStack {
                Text(metric.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let recency = recency {
                    Text(recency.formattedText)
                        .font(.caption2)
                        .foregroundStyle(recency.daysAgo > 0 ? Color.orange : Color.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

#Preview {
    ContentView()
}
