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

/// Mean / standard deviation / usable-day-count describing a metric's personal baseline.
public struct BaselineStats: Sendable, Equatable {
    public let mean: Double?
    public let stdDev: Double?
    public let count: Int

    public static let empty = BaselineStats(mean: nil, stdDev: nil, count: 0)
}

@Observable
@MainActor
public final class AppViewModel {
    public let healthKitManager: HealthKitManager
    public private(set) var calculatedResult: ReadinessResult? = nil
    public private(set) var metricRecencies: [MetricRecency] = []
    public private(set) var recencyNote: String? = nil

    // MARK: - Baseline tuning

    /// How far back a baseline may reach. Shorter than the 90-day fetch window on purpose:
    /// a baseline should describe who you are now, not who you were three months ago.
    static let baselineWindowDays: Int = 60

    /// Exponential recency weighting. A reading this many days old counts half as much as
    /// one from yesterday, so the baseline tracks fitness changes instead of being anchored
    /// by an unweighted average over the whole window.
    static let recencyHalfLifeDays: Double = 14.0

    /// Modified z-score cutoff for outlier rejection, in median-absolute-deviations. One
    /// bad night (a watch that slipped, a fever) otherwise permanently widens the standard
    /// deviation, which compresses every future z-score toward zero.
    static let outlierMADThreshold: Double = 3.5

    /// A metric's newest sample may be at most this old to describe today.
    static let maxSampleAgeDays: Int = ReadinessEngine.Tuning.maxDataAgeDays

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

    public init(healthKitManager: HealthKitManager? = nil) {
        let manager = healthKitManager ?? HealthKitManager()
        self.healthKitManager = manager

        // Recalculate whenever HealthKit reports new data via background delivery.
        manager.onDataUpdated = { [weak self] in
            self?.processHealthData()
        }
    }

    /// Requests HealthKit authorization (if needed), fetches 90-day data, and calculates readiness.
    public func loadAndCalculateReadiness() async {
        await healthKitManager.refreshAccessState()
        await healthKitManager.fetch90DayHealthData()
        processHealthData()
    }

    /// Presents the HealthKit permission sheet, then reloads.
    public func requestHealthAccess() async {
        try? await healthKitManager.requestAuthorization()
        await healthKitManager.fetch90DayHealthData()
        processHealthData()
    }

    /// Converts raw HealthKit data into a `ReadinessInput` and scores it.
    public func processHealthData() {
        let calendar = Calendar.current
        let todayKey = calendar.startOfDay(for: Date())
        guard let yesterdayKey = calendar.date(byAdding: .day, value: -1, to: todayKey) else { return }

        var recencyList: [MetricRecency] = []

        /// Resolves one core metric: newest sample, a freshness gate, and a baseline
        /// computed strictly from days *before* the sample being scored.
        func resolve(
            name: String,
            data: [Date: Double]
        ) -> (metric: MetricInput, newest: (value: Double, date: Date, daysAgo: Int)?) {
            let newest = Self.findMostRecentSample(in: data, todayKey: todayKey, calendar: calendar)

            // A reading older than the freshness window can't describe today, so it is
            // dropped from scoring entirely. The weights of the remaining metrics
            // redistribute to compensate.
            let fresh = newest.flatMap { $0.daysAgo <= Self.maxSampleAgeDays ? $0 : nil }

            let baseline = Self.computeBaseline(
                from: data,
                before: fresh?.date ?? todayKey,
                calendar: calendar
            )

            if let newest {
                recencyList.append(MetricRecency(
                    name: name,
                    daysAgo: newest.daysAgo,
                    sampleDate: newest.date,
                    formattedText: Self.recencyText(daysAgo: newest.daysAgo, date: newest.date)
                ))
            }

            return (
                MetricInput(
                    todayValue: fresh?.value,
                    baselineMean: baseline.mean,
                    baselineStdDev: baseline.stdDev,
                    daysOfBaselineData: baseline.count
                ),
                newest
            )
        }

        let (hrvMetric, hrvNewest) = resolve(name: "HRV", data: healthKitManager.hrvData)
        let (rhrMetric, rhrNewest) = resolve(name: "Resting HR", data: healthKitManager.restingHRData)
        let (sleepMetric, sleepNewest) = resolve(name: "Sleep", data: healthKitManager.sleepData)

        let yesterdayHRV = healthKitManager.hrvData[yesterdayKey]

        let (acuteLoad, chronicLoad) = Self.computeTrainingLoad(
            from: healthKitManager.activeEnergyData,
            todayKey: todayKey,
            calendar: calendar
        )

        // Age of the freshest core reading. Drives the engine's staleness gate.
        let dataAgeInDays = [hrvNewest, rhrNewest, sleepNewest]
            .compactMap { $0?.daysAgo }
            .min()

        let readinessInput = ReadinessInput(
            hrv: hrvMetric,
            restingHeartRate: rhrMetric,
            sleepHours: sleepMetric,
            acuteLoad: acuteLoad,
            chronicLoad: chronicLoad,
            yesterdayHRV: yesterdayHRV,
            dataAgeInDays: dataAgeInDays
        )

        self.calculatedResult = ReadinessEngine.calculate(from: readinessInput)
        self.metricRecencies = recencyList

        // Note shown under the score when a contributing metric isn't from today.
        let staleContributors = recencyList.filter { $0.daysAgo > 0 && $0.daysAgo <= Self.maxSampleAgeDays }
        if let oldest = staleContributors.max(by: { $0.daysAgo < $1.daysAgo }) {
            let dateStr = Self.shortDateFormatter.string(from: oldest.sampleDate)
            self.recencyNote = "Based on \(oldest.name) from \(dateStr)"
        } else {
            self.recencyNote = nil
        }
    }

    // MARK: - Sample lookup

    /// Finds the single most recent sample at or before `todayKey`. Applies no freshness
    /// limit — callers decide what counts as fresh enough for their purpose.
    public static func findMostRecentSample(
        in data: [Date: Double],
        todayKey: Date,
        calendar: Calendar
    ) -> (value: Double, date: Date, daysAgo: Int)? {
        let validEntries = data.filter { calendar.startOfDay(for: $0.key) <= todayKey && $0.value.isFinite }
        guard let latest = validEntries.max(by: { $0.key < $1.key }) else { return nil }
        let sampleDate = calendar.startOfDay(for: latest.key)
        let daysAgo = calendar.dateComponents([.day], from: sampleDate, to: todayKey).day ?? 0
        return (value: latest.value, date: sampleDate, daysAgo: daysAgo)
    }

    // MARK: - Baseline statistics

    /// Builds a recency-weighted, outlier-trimmed baseline from the days strictly *before*
    /// `scoredDate`.
    ///
    /// The value being scored is never part of its own baseline — including it drags the
    /// mean toward the observation and pins the z-score near zero, which is exactly what
    /// the previous "no prior entries, use everything" fallback did.
    static func computeBaseline(
        from data: [Date: Double],
        before scoredDate: Date,
        calendar: Calendar
    ) -> BaselineStats {
        let refKey = calendar.startOfDay(for: scoredDate)
        guard let windowStart = calendar.date(byAdding: .day, value: -baselineWindowDays, to: refKey) else {
            return .empty
        }

        // Strictly earlier than the scored day, and within the rolling window.
        var entries: [(date: Date, value: Double)] = data.compactMap { key, value in
            let day = calendar.startOfDay(for: key)
            guard day < refKey, day >= windowStart, value.isFinite else { return nil }
            return (day, value)
        }

        guard !entries.isEmpty else { return .empty }

        entries = trimOutliers(entries)
        guard entries.count >= ReadinessEngine.Tuning.minBaselineDays else {
            return BaselineStats(mean: nil, stdDev: nil, count: entries.count)
        }

        // Exponential recency weights.
        let decay = log(2.0) / recencyHalfLifeDays
        let weighted: [(value: Double, weight: Double)] = entries.map { entry in
            let ageDays = Double(calendar.dateComponents([.day], from: entry.date, to: refKey).day ?? 0)
            return (entry.value, exp(-decay * max(ageDays, 0)))
        }

        let v1 = weighted.reduce(0.0) { $0 + $1.weight }
        let v2 = weighted.reduce(0.0) { $0 + $1.weight * $1.weight }
        guard v1 > 0 else { return .empty }

        let mean = weighted.reduce(0.0) { $0 + $1.value * $1.weight } / v1

        // Unbiased weighted variance for reliability weights.
        let denominator = v1 - (v2 / v1)
        guard denominator > 0 else {
            return BaselineStats(mean: mean, stdDev: nil, count: entries.count)
        }

        let sumSquares = weighted.reduce(0.0) { $0 + $1.weight * pow($1.value - mean, 2) }
        let stdDev = sqrt(sumSquares / denominator)

        return BaselineStats(mean: mean, stdDev: stdDev, count: entries.count)
    }

    /// Drops points more than `outlierMADThreshold` median-absolute-deviations from the
    /// median. MAD is used rather than standard deviation because the standard deviation
    /// is itself distorted by the outliers we're trying to find.
    static func trimOutliers(_ entries: [(date: Date, value: Double)]) -> [(date: Date, value: Double)] {
        guard entries.count >= 4 else { return entries }

        let values = entries.map(\.value)
        guard let med = median(of: values) else { return entries }

        let deviations = values.map { abs($0 - med) }
        guard let mad = median(of: deviations), mad > 1e-9 else { return entries }

        // 1.4826 scales MAD to be a consistent estimator of sigma for normal data.
        let cutoff = outlierMADThreshold * 1.4826 * mad
        let kept = entries.filter { abs($0.value - med) <= cutoff }

        // Never trim away so much that nothing meaningful is left.
        return kept.count >= 3 ? kept : entries
    }

    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2.0 : sorted[mid]
    }

    // MARK: - Training load

    /// Acute (3-day) and chronic (28-day) average active energy.
    ///
    /// Both windows end yesterday. Today is deliberately excluded: it is a partial day, so
    /// including it makes the acute average artificially low in the morning — which reads
    /// as under-training and *inflates* the score — then decays over the course of the day
    /// for reasons that have nothing to do with recovery.
    static func computeTrainingLoad(
        from energyData: [Date: Double],
        todayKey: Date,
        calendar: Calendar
    ) -> (acuteLoad: Double?, chronicLoad: Double?) {
        guard !energyData.isEmpty else { return (nil, nil) }

        func average(overTrailingDays days: Int) -> Double? {
            var values: [Double] = []
            for offset in 1...days {
                if let date = calendar.date(byAdding: .day, value: -offset, to: todayKey),
                   let value = energyData[date], value.isFinite {
                    values.append(value)
                }
            }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        return (average(overTrailingDays: 3), average(overTrailingDays: 28))
    }

    // MARK: - Formatting

    static func recencyText(daysAgo: Int, date: Date) -> String {
        switch daysAgo {
        case 0:  return "Updated today"
        case 1:  return "Updated yesterday"
        default: return "\(shortDateFormatter.string(from: date)) (\(daysAgo)d ago)"
        }
    }
}
