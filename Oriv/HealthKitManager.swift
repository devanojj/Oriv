//
//  HealthKitManager.swift
//  Oriv
//

import Foundation
import HealthKit
import Observation

/// Represents a single metric reading with date and numerical value.
public struct DateValue: Identifiable, Sendable, Equatable {
    public var id: Date { date }
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Summary metrics container for 90-day HealthKit verification output.
public struct HealthSummary: Sendable {
    public let hrvCount: Int
    public let restingHRCount: Int
    public let sleepCount: Int
    public let activeEnergyCount: Int

    public let avgHRV: Double?
    public let avgRestingHR: Double?

    public let recentHRV: [DateValue]
    public let recentRestingHR: [DateValue]
    public let recentSleepHours: [DateValue]
    public let recentActiveEnergy: [DateValue]
}

/// What the app can actually see, as opposed to what it asked for.
///
/// HealthKit deliberately never reports read-authorization status — asking would leak
/// that the user is hiding a condition. `requestAuthorization` therefore succeeds
/// identically whether the user granted everything or tapped "Don't Allow" on all of it.
/// The only honest signal available is: have we asked yet, and did any data come back?
public enum HealthAccessState: Sendable, Equatable {
    /// Haven't determined anything yet.
    case unknown
    /// Device has no HealthKit (iPad without Health, Simulator variants).
    case unavailable
    /// We have never presented the permission sheet.
    case needsAuthorization
    /// We asked, but zero samples came back across every type. Either the user denied
    /// read access, or they genuinely have no recorded health data. We cannot tell which,
    /// so the UI has to address both.
    case noDataVisible
    /// We asked and data is flowing.
    case authorized
}

@Observable
@MainActor
public final class HealthKitManager {
    public private(set) var accessState: HealthAccessState = .unknown
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String? = nil

    /// Retained for call sites that only care whether data is usable.
    public var isAuthorized: Bool { accessState == .authorized }

    // Aggregated 90-Day Datasets (Date -> Double)
    public private(set) var hrvData: [Date: Double] = [:]
    public private(set) var restingHRData: [Date: Double] = [:]
    public private(set) var sleepData: [Date: Double] = [:]
    public private(set) var activeEnergyData: [Date: Double] = [:]

    public private(set) var summary: HealthSummary? = nil

    /// Callback invoked on @MainActor whenever health metrics update via background observers or manual requests.
    public var onDataUpdated: (@MainActor () async -> Void)? = nil

    private let healthStore = HKHealthStore()
    private var activeObserverQueries: [HKObserverQuery] = []
    private var activeFetchTask: Task<Void, Never>? = nil
    private var isExecutingCallback: Bool = false
    private var hasRequestedAuthorization: Bool = false

    /// Nap rejection window. A sleep segment that *begins* inside these hours is treated
    /// as a daytime nap and excluded from the night's total, so an afternoon nap doesn't
    /// silently inflate last night's sleep.
    private static let napWindow: Range<Int> = 10..<20

    /// A sleep segment ending at or after this hour is attributed to the *following*
    /// night rather than the night that just ended.
    private static let nightRolloverHour: Int = 20

    // Required sample types to observe and read
    private var sampleTypesToObserve: [HKSampleType] {
        var types: [HKSampleType] = []
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.append(hrv) }
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.append(rhr) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.append(energy) }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }
        return types
    }

    private var readTypes: Set<HKObjectType> {
        Set(sampleTypesToObserve)
    }

    public init() {}

    // MARK: - Authorization

    /// Determines whether the permission sheet still needs to be shown, without presenting it.
    public func refreshAccessState() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            accessState = .unavailable
            return
        }

        do {
            let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: readTypes)
            switch status {
            case .shouldRequest:
                hasRequestedAuthorization = false
                if accessState == .unknown { accessState = .needsAuthorization }
            case .unnecessary:
                // Every type has been presented to the user at least once. Whether they
                // said yes is still unknowable; the fetch result decides.
                hasRequestedAuthorization = true
            case .unknown:
                break
            @unknown default:
                break
            }
        } catch {
            // A failure here is not fatal — fall through and let the fetch decide.
            hasRequestedAuthorization = true
        }
    }

    /// Request read authorization for required HealthKit types and start background observers.
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            accessState = .unavailable
            throw HealthError.notAvailable
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            // Note: this succeeds whether or not the user granted anything. We do NOT
            // set `.authorized` here — only the presence of returned data can justify that.
            hasRequestedAuthorization = true
            errorMessage = nil
            await startObservingBackgroundUpdates()
        } catch {
            errorMessage = "HealthKit authorization failed: \(error.localizedDescription)"
            throw error
        }
    }

    /// Enables background delivery and starts HKObserverQuery instances for all 4 metric types.
    public func startObservingBackgroundUpdates() async {
        guard HKHealthStore.isHealthDataAvailable(), hasRequestedAuthorization else { return }
        stopObservingBackgroundUpdates()

        for sampleType in sampleTypesToObserve {
            do {
                try await healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate)
            } catch {
                log("enableBackgroundDelivery failed for \(sampleType.identifier): \(error.localizedDescription)")
            }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                guard error == nil else {
                    completionHandler()
                    return
                }

                Task { @MainActor [weak self] in
                    defer { completionHandler() }
                    guard let self else { return }
                    await self.fetchAllMetrics()
                }
            }

            healthStore.execute(query)
            activeObserverQueries.append(query)
        }
    }

    /// Stops all active observer queries and resets observer storage.
    public func stopObservingBackgroundUpdates() {
        for query in activeObserverQueries {
            healthStore.stop(query)
        }
        activeObserverQueries.removeAll()
    }

    // MARK: - Fetching

    /// Legacy compatibility wrapper for `fetchAllMetrics()`.
    public func fetch90DayHealthData() async {
        await fetchAllMetrics()
    }

    /// Primary entry point: Triggers concurrent fetching for all 4 health metrics over the last 90 days.
    public func fetchAllMetrics() async {
        if isExecutingCallback { return }

        if let existingTask = activeFetchTask {
            await existingTask.value
            return
        }

        let task = Task { @MainActor in
            await self.performFetchAllMetrics()
        }
        self.activeFetchTask = task

        defer { self.activeFetchTask = nil }

        await task.value
    }

    private func performFetchAllMetrics() async {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            guard HKHealthStore.isHealthDataAvailable() else {
                accessState = .unavailable
                throw HealthError.notAvailable
            }

            if !hasRequestedAuthorization {
                try await requestAuthorization()
            }

            let calendar = Calendar.current
            let now = Date()
            let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(86_399)
            guard let startDate = calendar.date(byAdding: .day, value: -90, to: calendar.startOfDay(for: now)) else {
                throw HealthError.dateCalculationFailed
            }

            // Execute all 4 queries concurrently using async let
            async let hrvTask = fetchHRV(from: startDate, to: endOfToday)
            async let restingHRTask = fetchRestingHR(from: startDate, to: endOfToday)
            async let sleepTask = fetchSleepDuration(from: startDate, to: endOfToday)
            async let energyTask = fetchActiveEnergy(from: startDate, to: endOfToday)

            let (fetchedHRV, fetchedRestingHR, fetchedSleep, fetchedEnergy) = try await (
                hrvTask, restingHRTask, sleepTask, energyTask
            )

            self.hrvData = fetchedHRV
            self.restingHRData = fetchedRestingHR
            self.sleepData = fetchedSleep
            self.activeEnergyData = fetchedEnergy

            let sawAnything = !fetchedHRV.isEmpty
                || !fetchedRestingHR.isEmpty
                || !fetchedSleep.isEmpty
                || !fetchedEnergy.isEmpty

            accessState = sawAnything ? .authorized : .noDataVisible

            let generatedSummary = computeSummary(
                hrv: fetchedHRV,
                restingHR: fetchedRestingHR,
                sleep: fetchedSleep,
                activeEnergy: fetchedEnergy
            )
            self.summary = generatedSummary
            logSummary(generatedSummary)

            // Invoke reactive callback if set
            if !isExecutingCallback, let onDataUpdated {
                isExecutingCallback = true
                defer { isExecutingCallback = false }
                await onDataUpdated()
            }

        } catch {
            self.errorMessage = "Failed to fetch health data: \(error.localizedDescription)"
            log("fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Query Methods

    /// Fetch HRV (SDNN) samples in ms for the last 90 days.
    private func fetchHRV(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return [:]
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sampleDescriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: hrvType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let samples = try await sampleDescriptor.result(for: healthStore)
        let unit = HKUnit.secondUnit(with: .milli)
        let calendar = Calendar.current

        var grouped: [Date: [Double]] = [:]
        for sample in samples {
            let dayKey = calendar.startOfDay(for: sample.startDate)
            grouped[dayKey, default: []].append(sample.quantity.doubleValue(for: unit))
        }

        return grouped.compactMapValues { values in
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    /// Fetch Resting Heart Rate daily samples (bpm) for the last 90 days.
    private func fetchRestingHR(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            return [:]
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sampleDescriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: rhrType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let samples = try await sampleDescriptor.result(for: healthStore)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let calendar = Calendar.current

        var grouped: [Date: [Double]] = [:]
        for sample in samples {
            let dayKey = calendar.startOfDay(for: sample.startDate)
            grouped[dayKey, default: []].append(sample.quantity.doubleValue(for: unit))
        }

        return grouped.compactMapValues { values in
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    /// Fetch nightly sleep duration (hours) for the last 90 days.
    ///
    /// Segments are attributed to the night they belong to rather than simply the calendar
    /// day they end on, and daytime naps are excluded — otherwise a 3pm nap is added to
    /// last night's total and reads as a good night's sleep.
    private func fetchSleepDuration(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return [:]
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sampleDescriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )

        let samples = try await sampleDescriptor.result(for: healthStore)
        let calendar = Calendar.current
        var groupedSeconds: [Date: Double] = [:]

        for sample in samples {
            // Only true sleep stages count — .inBed and .awake are excluded.
            let sleepValue = HKCategoryValueSleepAnalysis(rawValue: sample.value)
            let isAsleep = sleepValue == .asleepUnspecified
                || sleepValue == .asleepCore
                || sleepValue == .asleepDeep
                || sleepValue == .asleepREM
            guard isAsleep else { continue }

            // Exclude daytime naps.
            let startHour = calendar.component(.hour, from: sample.startDate)
            guard !Self.napWindow.contains(startHour) else { continue }

            guard let nightKey = nightKey(forSegmentEndingAt: sample.endDate, calendar: calendar) else { continue }

            let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
            guard durationSeconds > 0 else { continue }

            groupedSeconds[nightKey, default: 0] += durationSeconds
        }

        return groupedSeconds.mapValues { $0 / 3600.0 }
    }

    /// Which night a sleep segment belongs to. A segment that ends in the morning belongs
    /// to that day; one that ends late in the evening belongs to the night now beginning.
    private func nightKey(forSegmentEndingAt endDate: Date, calendar: Calendar) -> Date? {
        let day = calendar.startOfDay(for: endDate)
        let hour = calendar.component(.hour, from: endDate)
        guard hour >= Self.nightRolloverHour else { return day }
        return calendar.date(byAdding: .day, value: 1, to: day)
    }

    /// Fetch Active Energy Burned (daily active calorie totals in kcal) for the last 90 days.
    private func fetchActiveEnergy(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return [:]
        }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let anchorDate = Calendar.current.startOfDay(for: startDate)

        let queryDescriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: energyType, predicate: predicate),
            options: .cumulativeSum,
            anchorDate: anchorDate,
            intervalComponents: DateComponents(day: 1)
        )

        let collection = try await queryDescriptor.result(for: healthStore)
        let kcalUnit = HKUnit.kilocalorie()
        let calendar = Calendar.current
        var dailyCalories: [Date: Double] = [:]

        collection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
            if let sum = statistics.sumQuantity() {
                let dayKey = calendar.startOfDay(for: statistics.startDate)
                dailyCalories[dayKey] = sum.doubleValue(for: kcalUnit)
            }
        }

        return dailyCalories
    }

    // MARK: - Helpers

    private func computeSummary(
        hrv: [Date: Double],
        restingHR: [Date: Double],
        sleep: [Date: Double],
        activeEnergy: [Date: Double]
    ) -> HealthSummary {
        let avgHRV = hrv.isEmpty ? nil : hrv.values.reduce(0, +) / Double(hrv.count)
        let avgRHR = restingHR.isEmpty ? nil : restingHR.values.reduce(0, +) / Double(restingHR.count)

        func mostRecent(_ data: [Date: Double], _ limit: Int = 3) -> [DateValue] {
            Array(
                data.map { DateValue(date: $0.key, value: $0.value) }
                    .sorted { $0.date > $1.date }
                    .prefix(limit)
            )
        }

        return HealthSummary(
            hrvCount: hrv.count,
            restingHRCount: restingHR.count,
            sleepCount: sleep.count,
            activeEnergyCount: activeEnergy.count,
            avgHRV: avgHRV,
            avgRestingHR: avgRHR,
            recentHRV: mostRecent(hrv),
            recentRestingHR: mostRecent(restingHR),
            recentSleepHours: mostRecent(sleep),
            recentActiveEnergy: mostRecent(activeEnergy)
        )
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[HealthKitManager] \(message)")
        #endif
    }

    private func logSummary(_ summary: HealthSummary) {
        #if DEBUG
        print("""
        [HealthKitManager] 90-day fetch complete — \
        HRV \(summary.hrvCount)d, RHR \(summary.restingHRCount)d, \
        Sleep \(summary.sleepCount)d, Energy \(summary.activeEnergyCount)d
        """)
        #endif
    }
}

public enum HealthError: LocalizedError {
    case notAvailable
    case dateCalculationFailed

    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device."
        case .dateCalculationFailed:
            return "Failed to calculate the 90-day date range."
        }
    }
}
