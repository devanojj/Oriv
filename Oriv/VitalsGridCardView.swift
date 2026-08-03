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
        if let sample = findLatestSample(from: healthKitManager.hrvData) {
            return String(format: "%.0f", sample)
        }
        return "—"
    }
    
    private var rhrValue: String {
        if let sample = findLatestSample(from: healthKitManager.restingHRData) {
            return String(format: "%.0f", sample)
        }
        return "—"
    }
    
    private var sleepValue: String {
        if let sample = findLatestSample(from: healthKitManager.sleepData) {
            let hours = Int(sample)
            let minutes = Int((sample - Double(hours)) * 60)
            return "\(hours)h \(minutes)m"
        }
        return "—"
    }
    
    private var energyValue: String {
        if let sample = findLatestSample(from: healthKitManager.activeEnergyData) {
            return String(format: "%.0f", sample)
        }
        return "—"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TODAY'S VITALS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
            
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
                    subscore: subscoreFor("HRV"),
                    recency: recencyFor("HRV"),
                    accentColor: Color(red: 0.16, green: 0.78, blue: 0.64)
                )
                
                VitalCell(
                    label: "RESTING HR",
                    value: rhrValue,
                    unit: "bpm",
                    subscore: subscoreFor("Resting HR"),
                    recency: recencyFor("Resting HR"),
                    accentColor: Color(red: 0.92, green: 0.38, blue: 0.36)
                )
                
                VitalCell(
                    label: "SLEEP",
                    value: sleepValue,
                    unit: "",
                    subscore: subscoreFor("Sleep"),
                    recency: recencyFor("Sleep"),
                    accentColor: Color(red: 0.42, green: 0.38, blue: 0.82)
                )
                
                VitalCell(
                    label: "TRAINING",
                    value: energyValue,
                    unit: "kcal",
                    subscore: subscoreFor("Training Load"),
                    recency: nil,
                    accentColor: Color(red: 0.96, green: 0.62, blue: 0.16)
                )
            }
        }
        .padding(20)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
    
    private func subscoreFor(_ name: String) -> Int? {
        breakdown.first(where: { $0.name == name })?.subscore
    }
    
    private func recencyFor(_ name: String) -> MetricRecency? {
        recencies.first(where: { $0.name == name })
    }
    
    private func findLatestSample(from data: [Date: Double]) -> Double? {
        let calendar = Calendar.current
        let todayKey = calendar.startOfDay(for: Date())
        let validEntries = data.filter { calendar.startOfDay(for: $0.key) <= todayKey && !$0.value.isNaN }
        return validEntries.max(by: { $0.key < $1.key })?.value
    }
}

// MARK: - Individual Vital Cell

private struct VitalCell: View {
    let label: String
    let value: String
    let unit: String
    let subscore: Int?
    let recency: MetricRecency?
    let accentColor: Color
    
    private var subscoreColor: Color {
        guard let s = subscore else { return Color(uiColor: .quaternaryLabel) }
        switch s {
        case 75...100: return Color(red: 0.16, green: 0.78, blue: 0.64)
        case 50...74:  return Color(red: 0.24, green: 0.56, blue: 0.98)
        case 30...49:  return Color(red: 0.96, green: 0.68, blue: 0.20)
        default:       return Color(red: 0.92, green: 0.30, blue: 0.28)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Label row
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                
                Spacer()
                
                if let recency = recency, recency.daysAgo > 0 {
                    Text("\(recency.daysAgo)d")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
            
            // Value
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(uiColor: .label))
                    .contentTransition(.numericText())
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
            
            // Subscore bar
            if let s = subscore {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(uiColor: .systemFill))
                            .frame(height: 4)
                        
                        Capsule()
                            .fill(subscoreColor)
                            .frame(width: max(0, geo.size.width * CGFloat(s) / 100.0), height: 4)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(14)
        .background(Color(red: 0.97, green: 0.97, blue: 0.98))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
