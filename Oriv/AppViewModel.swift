//
//  AppViewModel.swift
//  Oriv
//

import Foundation
import Observation

public struct MetricRecency: Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let daysAgo: Int
    public let sampleDate: Date
    public let formattedText: String
    
    public init(name: String, daysAgo: Int, sampleDate: Date, formattedText: String) {
        self.name = name
        self.daysAgo = daysAgo
        self.sampleDate = sampleDate
        self.formattedText = formattedText
    }
}

@Observable
@MainActor
public final class AppViewModel {
    public let healthKitManager: HealthKitManager
    public private(set) var calculatedResult: ReadinessResult? = nil
    public private(set) var metricRecencies: [MetricRecency] = []
    public private(set) var recencyNote: String? = nil
    
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()
    
    public init(healthKitManager: HealthKitManager? = nil) {
        let manager = healthKitManager ?? HealthKitManager()
        self.healthKitManager = manager
        
        // Automatically recalculate readiness score whenever HealthKitManager receives background updates
        manager.onDataUpdated = { [weak self] in
            self?.processHealthData()
        }
    }
    
    /// Requests HealthKit authorization (if needed), fetches 90-day data, and calculates readiness score.
    public func loadAndCalculateReadiness() async {
        await healthKitManager.fetch90DayHealthData()
        processHealthData()
    }
    
    /// Converts raw HealthKit 90-day data into ReadinessInput using unrestricted sample lookups if today's sample is missing.
    public func processHealthData() {
        let calendar = Calendar.current
        let todayKey = calendar.startOfDay(for: Date())
        guard let yesterdayKey = calendar.date(byAdding: .day, value: -1, to: todayKey) else { return }
        
        var recencyList: [MetricRecency] = []
        
        // 1. HRV with Unrestricted 90-Day Fallback
        let hrvSample = findMostRecentSample(in: healthKitManager.hrvData, todayKey: todayKey, calendar: calendar)
        let hrvBaseline = computeBaselineStats(
            from: healthKitManager.hrvData,
            referenceDate: hrvSample?.date ?? todayKey,
            calendar: calendar
        )
        let hrvMetric = MetricInput(
            todayValue: hrvSample?.value,
            baselineMean: hrvBaseline.mean,
            baselineStdDev: hrvBaseline.stdDev,
            daysOfBaselineData: hrvBaseline.count
        )
        if let sample = hrvSample {
            let recencyText = formatRecencyText(name: "HRV", daysAgo: sample.daysAgo, date: sample.date)
            recencyList.append(MetricRecency(name: "HRV", daysAgo: sample.daysAgo, sampleDate: sample.date, formattedText: recencyText))
        }
        
        // Yesterday's HRV (relative to yesterday)
        let yesterdayHRV = healthKitManager.hrvData[yesterdayKey]
        
        // 2. Resting Heart Rate with Unrestricted 90-Day Fallback
        let rhrSample = findMostRecentSample(in: healthKitManager.restingHRData, todayKey: todayKey, calendar: calendar)
        let rhrBaseline = computeBaselineStats(
            from: healthKitManager.restingHRData,
            referenceDate: rhrSample?.date ?? todayKey,
            calendar: calendar
        )
        let rhrMetric = MetricInput(
            todayValue: rhrSample?.value,
            baselineMean: rhrBaseline.mean,
            baselineStdDev: rhrBaseline.stdDev,
            daysOfBaselineData: rhrBaseline.count
        )
        if let sample = rhrSample {
            let recencyText = formatRecencyText(name: "Resting HR", daysAgo: sample.daysAgo, date: sample.date)
            recencyList.append(MetricRecency(name: "Resting HR", daysAgo: sample.daysAgo, sampleDate: sample.date, formattedText: recencyText))
        }
        
        // 3. Sleep Duration with Unrestricted 90-Day Fallback
        let sleepSample = findMostRecentSample(in: healthKitManager.sleepData, todayKey: todayKey, calendar: calendar)
        let sleepBaseline = computeBaselineStats(
            from: healthKitManager.sleepData,
            referenceDate: sleepSample?.date ?? todayKey,
            calendar: calendar
        )
        let sleepMetric = MetricInput(
            todayValue: sleepSample?.value,
            baselineMean: sleepBaseline.mean,
            baselineStdDev: sleepBaseline.stdDev,
            daysOfBaselineData: sleepBaseline.count
        )
        if let sample = sleepSample {
            let recencyText = formatRecencyText(name: "Sleep", daysAgo: sample.daysAgo, date: sample.date)
            recencyList.append(MetricRecency(name: "Sleep", daysAgo: sample.daysAgo, sampleDate: sample.date, formattedText: recencyText))
        }
        
        // 4. Acute & Chronic Training Load
        let (acuteLoad, chronicLoad) = computeTrainingLoad(from: healthKitManager.activeEnergyData, todayKey: todayKey, calendar: calendar)
        
        // 5. Construct ReadinessInput and Calculate Score
        let readinessInput = ReadinessInput(
            hrv: hrvMetric,
            restingHeartRate: rhrMetric,
            sleepHours: sleepMetric,
            acuteLoad: acuteLoad,
            chronicLoad: chronicLoad,
            yesterdayHRV: yesterdayHRV
        )
        
        self.calculatedResult = ReadinessEngine.calculate(from: readinessInput)
        self.metricRecencies = recencyList
        
        // 6. Build UI Recency Note for data status line
        let fallbackMetrics = recencyList.filter { $0.daysAgo > 0 }
        if let primaryFallback = fallbackMetrics.max(by: { $0.daysAgo < $1.daysAgo }) {
            let dateStr = Self.shortDateFormatter.string(from: primaryFallback.sampleDate)
            self.recencyNote = "Based on \(primaryFallback.name) from \(dateStr)"
        } else {
            self.recencyNote = nil
        }
    }
    
    // MARK: - Unrestricted 90-Day Sample Search Helper
    
    /// Finds the single most recent valid sample in the 90-day dataset.
    public func findMostRecentSample(
        in data: [Date: Double],
        todayKey: Date,
        calendar: Calendar
    ) -> (value: Double, date: Date, daysAgo: Int)? {
        let validEntries = data.filter { calendar.startOfDay(for: $0.key) <= todayKey && !$0.value.isNaN }
        guard let latest = validEntries.max(by: { $0.key < $1.key }) else { return nil }
        let sampleDate = calendar.startOfDay(for: latest.key)
        let daysAgo = calendar.dateComponents([.day], from: sampleDate, to: todayKey).day ?? 0
        return (value: latest.value, date: sampleDate, daysAgo: daysAgo)
    }
    
    // MARK: - Helpers
    
    private func formatRecencyText(name: String, daysAgo: Int, date: Date) -> String {
        switch daysAgo {
        case 0:
            return "Updated today"
        case 1:
            return "Updated yesterday"
        default:
            let dateStr = Self.shortDateFormatter.string(from: date)
            return "\(dateStr) (\(daysAgo)d ago)"
        }
    }
    
    private func computeBaselineStats(
        from data: [Date: Double],
        referenceDate: Date,
        calendar: Calendar
    ) -> (mean: Double?, stdDev: Double?, count: Int) {
        let refKey = calendar.startOfDay(for: referenceDate)
        
        // Baseline includes historical samples prior to the reference sample date
        let baselineEntries = data.filter { calendar.startOfDay(for: $0.key) < refKey }
        let values = baselineEntries.values.filter { !$0.isNaN }
        
        let count = values.count
        guard count > 0 else {
            // Fallback: if no prior entries exist, compute mean/stdDev across all entries
            let allValues = data.values.filter { !$0.isNaN }
            guard !allValues.isEmpty else { return (nil, nil, 0) }
            let mean = allValues.reduce(0.0, +) / Double(allValues.count)
            let sumSquared = allValues.reduce(0.0) { $0 + pow($1 - mean, 2) }
            let stdDev = sqrt(sumSquared / Double(allValues.count))
            return (mean, stdDev, allValues.count)
        }
        
        let sum = values.reduce(0.0, +)
        let mean = sum / Double(count)
        
        let sumSquaredDiffs = values.reduce(0.0) { $0 + pow($1 - mean, 2) }
        let variance = sumSquaredDiffs / Double(count)
        let stdDev = sqrt(variance)
        
        return (mean, stdDev, count)
    }
    
    private func computeTrainingLoad(
        from energyData: [Date: Double],
        todayKey: Date,
        calendar: Calendar
    ) -> (acuteLoad: Double?, chronicLoad: Double?) {
        guard !energyData.isEmpty else { return (nil, nil) }
        
        // Trailing 3 days
        var acuteValues: [Double] = []
        for dayOffset in 0..<3 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: todayKey),
               let val = energyData[date] {
                acuteValues.append(val)
            }
        }
        
        // Trailing 28 days
        var chronicValues: [Double] = []
        for dayOffset in 0..<28 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: todayKey),
               let val = energyData[date] {
                chronicValues.append(val)
            }
        }
        
        let acuteLoad = acuteValues.isEmpty ? nil : acuteValues.reduce(0.0, +) / Double(acuteValues.count)
        let chronicLoad = chronicValues.isEmpty ? nil : chronicValues.reduce(0.0, +) / Double(chronicValues.count)
        
        return (acuteLoad, chronicLoad)
    }
}
