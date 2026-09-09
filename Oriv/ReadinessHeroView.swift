//
//  ReadinessHeroView.swift
//  Oriv
//
//  Readiness score hero card.
//

import SwiftUI

struct ReadinessHeroView: View {
    let result: ReadinessResult
    let recencyNote: String?

    @State private var animatedProgress: CGFloat = 0
    @State private var animatedScore: Int = 0

    private var score: Int { result.score ?? 0 }
    private var band: ReadinessBand { result.band ?? .fair }
    private var bandColor: Color { Theme.color(for: band) }

    var body: some View {
        VStack(spacing: 28) {
            // Score gauge
            ZStack {
                Circle()
                    .stroke(bandColor.opacity(0.14), lineWidth: 14)

                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(
                        Theme.gradient(for: band),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 2) {
                    Text("\(animatedScore)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())

                    Text(band.rawValue.uppercased())
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(bandColor)
                }
            }
            .frame(width: 180, height: 180)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Readiness score")
            .accessibilityValue("\(score) out of 100, \(band.rawValue)")

            VStack(spacing: 10) {
                Text(result.recommendation)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)

                if let recencyNote {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .font(.system(size: 10, weight: .semibold))
                        Text(recencyNote)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(bandColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(bandColor.opacity(0.12))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .orivCard()
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

#Preview("Ready") {
    ReadinessHeroView(
        result: ReadinessResult(
            score: 88,
            band: .ready,
            breakdown: [],
            recommendation: "You're well recovered. Heavy training and high intensity work are fair game today.",
            status: .scored
        ),
        recencyNote: nil
    )
    .padding()
    .background(Theme.canvas)
}

#Preview("Poor — dark") {
    ReadinessHeroView(
        result: ReadinessResult(
            score: 31,
            band: .poor,
            breakdown: [],
            recommendation: "Recovery is poor. Prioritize rest, sleep, and light movement today.",
            status: .scored
        ),
        recencyNote: "Based on Sleep from September 7"
    )
    .padding()
    .background(Theme.canvas)
    .preferredColorScheme(.dark)
}
