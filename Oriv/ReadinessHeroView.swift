//
//  ReadinessHeroView.swift
//  Oriv
//
//  Premium light-mode readiness score hero card.
//

import SwiftUI

struct ReadinessHeroView: View {
    let result: ReadinessResult
    let recencyNote: String?
    
    @State private var animatedProgress: CGFloat = 0
    @State private var animatedScore: Int = 0
    
    private var score: Int { result.score ?? 0 }
    private var band: ReadinessBand { result.band ?? .fair }
    
    private var bandGradient: LinearGradient {
        switch band {
        case .ready:
            return LinearGradient(
                colors: [Color(red: 0.16, green: 0.78, blue: 0.64), Color(red: 0.10, green: 0.62, blue: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .good:
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.56, blue: 0.98), Color(red: 0.18, green: 0.42, blue: 0.88)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .fair:
            return LinearGradient(
                colors: [Color(red: 0.96, green: 0.68, blue: 0.20), Color(red: 0.92, green: 0.54, blue: 0.14)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .poor:
            return LinearGradient(
                colors: [Color(red: 0.92, green: 0.30, blue: 0.28), Color(red: 0.78, green: 0.18, blue: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
    
    private var bandColor: Color {
        switch band {
        case .ready: return Color(red: 0.16, green: 0.78, blue: 0.64)
        case .good:  return Color(red: 0.24, green: 0.56, blue: 0.98)
        case .fair:  return Color(red: 0.96, green: 0.68, blue: 0.20)
        case .poor:  return Color(red: 0.92, green: 0.30, blue: 0.28)
        }
    }
    
    private var bandAccentLight: Color {
        bandColor.opacity(0.10)
    }
    
    var body: some View {
        VStack(spacing: 28) {
            // Score Gauge
            ZStack {
                // Track
                Circle()
                    .stroke(bandColor.opacity(0.10), lineWidth: 14)
                
                // Fill ring
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        bandGradient,
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                
                // Score text
                VStack(spacing: 2) {
                    Text("\(animatedScore)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(uiColor: .label))
                        .contentTransition(.numericText())
                    
                    Text(band.rawValue.uppercased())
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(bandColor)
                }
            }
            .frame(width: 180, height: 180)
            
            // Recommendation
            VStack(spacing: 10) {
                Text(result.recommendation)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
                
                // Recency pill
                if let recencyNote = recencyNote {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text(recencyNote)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(bandColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(bandAccentLight)
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) {
                animatedProgress = CGFloat(score) / 100.0
            }
            withAnimation(.easeOut(duration: 0.8)) {
                animatedScore = score
            }
        }
        .onChange(of: result.score) { _, newScore in
            let s = newScore ?? 0
            withAnimation(.easeOut(duration: 0.6)) {
                animatedProgress = CGFloat(s) / 100.0
                animatedScore = s
            }
        }
    }
}

// MARK: - Insufficient Data Hero

struct InsufficientDataHeroView: View {
    let recommendation: String
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(0.12), lineWidth: 14)
                    .frame(width: 140, height: 140)
                
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.7))
            }
            
            VStack(spacing: 8) {
                Text("Building Your Baseline")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(uiColor: .label))
                
                Text(recommendation)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}
