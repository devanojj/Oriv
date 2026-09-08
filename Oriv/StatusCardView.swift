//
//  StatusCardView.swift
//  Oriv
//
//  The states where there is no score to show. Each one names the actual problem and,
//  where the user can do something about it, offers the action.
//

import SwiftUI
import UIKit

struct StatusCardView: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 96, height: 96)

                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 8)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(tint)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .orivCard()
    }
}

// MARK: - Concrete states

extension StatusCardView {

    /// HealthKit has never been asked for permission.
    static func needsAuthorization(onConnect: @escaping () -> Void) -> StatusCardView {
        StatusCardView(
            symbol: "heart.text.square",
            tint: Theme.good,
            title: "Connect Apple Health",
            message: "Oriv reads your HRV, resting heart rate, sleep, and active energy to work out how recovered you are each morning. Nothing leaves your device.",
            actionTitle: "Connect Health",
            action: onConnect
        )
    }

    /// We asked, and nothing came back. Could be denied permission, could be an empty
    /// Health app — HealthKit won't tell us which, so the copy has to cover both.
    static func noDataVisible(onOpenSettings: @escaping () -> Void) -> StatusCardView {
        StatusCardView(
            symbol: "eye.slash",
            tint: Theme.warning,
            title: "Can't See Your Health Data",
            message: "Oriv isn't receiving any readings. Check that HRV, Resting Heart Rate, Sleep, and Active Energy are switched on for Oriv in Settings — and that you're wearing your watch to bed.",
            actionTitle: "Open Settings",
            action: onOpenSettings
        )
    }

    /// Device can't do HealthKit at all.
    static func unavailable() -> StatusCardView {
        StatusCardView(
            symbol: "exclamationmark.triangle",
            tint: Theme.warning,
            title: "Health Data Unavailable",
            message: "This device doesn't support Apple Health, so Oriv can't calculate a readiness score."
        )
    }

    /// Baseline still being collected.
    static func buildingBaseline(message: String) -> StatusCardView {
        StatusCardView(
            symbol: "waveform.path.ecg",
            tint: Theme.warning,
            title: "Building Your Baseline",
            message: message
        )
    }

    /// Data exists but is too old to describe today.
    static func staleData(daysAgo: Int, onOpenSettings: @escaping () -> Void) -> StatusCardView {
        let dayText = daysAgo == 1 ? "1 day" : "\(daysAgo) days"
        return StatusCardView(
            symbol: "clock.badge.exclamationmark",
            tint: Theme.warning,
            title: "No Recent Readings",
            message: "Your most recent health data is \(dayText) old, so Oriv can't score today. Wear your watch overnight and your score will return automatically.",
            actionTitle: "Open Settings",
            action: onOpenSettings
        )
    }
}

// MARK: - Settings deep link

enum SettingsLink {
    /// Opens Oriv's page in Settings, where the Health permission toggles live.
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview("Needs authorization") {
    StatusCardView.needsAuthorization(onConnect: {})
        .padding()
        .background(Theme.canvas)
}

#Preview("No data visible") {
    StatusCardView.noDataVisible(onOpenSettings: {})
        .padding()
        .background(Theme.canvas)
}

#Preview("Stale data") {
    StatusCardView.staleData(daysAgo: 6, onOpenSettings: {})
        .padding()
        .background(Theme.canvas)
}
