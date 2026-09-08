//
//  VitalsGridCardView.swift
//  Oriv
//
//  2x2 modular vitals grid — HRV, Resting HR, Sleep, Active Energy.
//

import SwiftUI

struct VitalsGridCardView: View {
    let breakdown: [MetricBreakdown]
    let recencies: [MetricRecency]
    let healthKitManager: HealthKitManager

    private var hrvValue: String {
        latest(healthKitManager.hrvData).map { String(format: "%.0f", $0) } ?? "—"
    }

    private var rhrValue: String {
        latest(healthKitManager.restingHRData).map { String(format: "%.0f", $0) } ?? "—"
    }

    private var sleepValue: String {
        guard let sample = latest(healthKitManager.sleepData) else { return "—" }
        let totalMinutes = Int((sample * 60).rounded())
        return "\(totalMinutes / 60)h \(totalMinutes % 60)m"
    }

    private var energyValue: String {
        latest(healthKitManager.activeEnergyData).map { String(format: "%.0f", $0) } ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TODAY'S VITALS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Theme.textTertiary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                VitalCell(
                    label: "HRV",
                    value: hrvValue,
                    unit: "ms",
                    subscore: subscore(for: "HRV"),
                    recency: recency(for: "HRV")
                )

                VitalCell(
                    label: "RESTING HR",
                    value: rhrValue,
                    unit: "bpm",
                    subscore: subscore(for: "Resting HR"),
                    recency: recency(for: "Resting HR")
                )

                VitalCell(
                    label: "SLEEP",
                    value: sleepValue,
                    unit: "",
                    subscore: subscore(for: "Sleep"),
                    recency: recency(for: "Sleep")
                )

                VitalCell(
                    label: "TRAINING",
                    value: energyValue,
                    unit: "kcal",
                    subscore: subscore(for: "Training Load"),
                    recency: nil
                )
            }
        }
        .padding(20)
        .orivCard()
    }

    private func subscore(for name: String) -> Int? {
        breakdown.first { $0.name == name }?.subscore
    }

    private func recency(for name: String) -> MetricRecency? {
        recencies.first { $0.name == name }
    }

    private func latest(_ data: [Date: Double]) -> Double? {
        let calendar = Calendar.current
        let todayKey = calendar.startOfDay(for: Date())
        return data
            .filter { calendar.startOfDay(for: $0.key) <= todayKey && $0.value.isFinite }
            .max { $0.key < $1.key }?
            .value
    }
}

// MARK: - Individual Vital Cell

private struct VitalCell: View {
    let label: String
    let value: String
    let unit: String
    let subscore: Int?
    let recency: MetricRecency?

    private var subscoreColor: Color {
        guard let subscore else { return Theme.textQuaternary }
        return Theme.color(forSubscore: subscore)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Theme.textTertiary)

                Spacer()

                if let recency, recency.daysAgo > 0 {
                    Text("\(recency.daysAgo)d")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.warning.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())

                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if let subscore {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.track)
                            .frame(height: 4)

                        Capsule()
                            .fill(subscoreColor)
                            .frame(width: max(0, geo.size.width * CGFloat(subscore) / 100.0), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(14)
        .background(Theme.cardInset)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
