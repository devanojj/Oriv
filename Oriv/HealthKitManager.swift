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

@Observable
@MainActor
public final class HealthKitManager {
    public private(set) var isAuthorized: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var errorMessage: String? = nil
    
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
    
    /// Request read authorization for required HealthKit types and automatically start background observers upon success.
    public func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            let msg = "HealthKit is not available on this device."
            self.errorMessage = msg
            throw HealthError.notAvailable
        }
        
        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            self.isAuthorized = true
            self.errorMessage = nil
            await startObservingBackgroundUpdates()
        } catch {
            self.isAuthorized = false
            self.errorMessage = "HealthKit authorization failed: \(error.localizedDescription)"
            throw error
        }
    }
    
    /// Enables background delivery and starts HKObserverQuery instances for all 4 metric types.
    public func startObservingBackgroundUpdates() async {
        guard isAuthorized else { return }
        stopObservingBackgroundUpdates()
        
        for sampleType in sampleTypesToObserve {
            do {
                try await healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate)
            } catch {
                print("[HealthKitManager] Warning: enableBackgroundDelivery failed for \(sampleType.identifier): \(error.localizedDescription)")
            }
            
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                guard error == nil else {
                    print("[HealthKitManager] Observer query callback error for \(sampleType.identifier): \(String(describing: error))")
                    completionHandler()
                    return
                }
                
                Task { @MainActor [weak self] in
                    defer {
                        completionHandler()
                    }
                    guard let self = self else { return }
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
    
    /// Legacy compatibility wrapper for `fetchAllMetrics()`.
    public func fetch90DayHealthData() async {
        await fetchAllMetrics()
    }
    
    /// Primary entry point: Triggers concurrent fetching for all 4 health metrics over the last 90 days.
    public func fetchAllMetrics() async {
        if isExecutingCallback {
            return
        }
        
        if let existingTask = activeFetchTask {
            await existingTask.value
            return
        }
        
        let task = Task { @MainActor in
            await self.performFetchAllMetrics()
        }
        self.activeFetchTask = task
        
        defer {
            self.activeFetchTask = nil
        }
        
        await task.value
    }
    
    private func performFetchAllMetrics() async {
        isLoading = true
        errorMessage = nil
        
        defer {
            isLoading = false
        }
        
        do {
            if !isAuthorized {
                try await requestAuthorization()
            }
            
            let calendar = Calendar.current
            let now = Date()
            let endOfToday = calendar.startOfDay(for: now).addingTimeInterval(86399)
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
            
            // Calculate Summary
            let generatedSummary = computeSummary(
                hrv: fetchedHRV,
                restingHR: fetchedRestingHR,
                sleep: fetchedSleep,
                activeEnergy: fetchedEnergy
            )
            self.summary = generatedSummary
            
            // Log to Xcode Console
            printSummaryToConsole(summary: generatedSummary)
            
            // Invoke reactive callback if set
            if !isExecutingCallback, let onDataUpdated = onDataUpdated {
                isExecutingCallback = true
                defer {
                    isExecutingCallback = false
                }
                await onDataUpdated()
            }
            
        } catch {
            self.errorMessage = "Failed to fetch 90-day health data: \(error.localizedDescription)"
            print("[HealthKitManager ERROR] \(error.localizedDescription)")
        }
    }
    
    // MARK: - Query Methods
    
    /// Fetch HRV (SDNN) samples in ms for the last 90 days.
    private func fetchHRV(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return [:]
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let samplePredicate = HKSamplePredicate.quantitySample(type: hrvType, predicate: predicate)
        let sampleDescriptor = HKSampleQueryDescriptor(
            predicates: [samplePredicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        
        let samples = try await sampleDescriptor.result(for: healthStore)
        let unit = HKUnit.secondUnit(with: .milli)
        
        var grouped: [Date: [Double]] = [:]
        let calendar = Calendar.current
        
        for sample in samples {
            let msValue = sample.quantity.doubleValue(for: unit)
            let dayKey = calendar.startOfDay(for: sample.startDate)
            grouped[dayKey, default: []].append(msValue)
        }
        
        // Daily average calculation
        return grouped.mapValues { values in
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
    }
    
    /// Fetch Resting Heart Rate daily samples (bpm) for the last 90 days.
    private func fetchRestingHR(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) else {
            return [:]
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let samplePredicate = HKSamplePredicate.quantitySample(type: rhrType, predicate: predicate)
        let sampleDescriptor = HKSampleQueryDescriptor(
            predicates: [samplePredicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        
        let samples = try await sampleDescriptor.result(for: healthStore)
        let unit = HKUnit.count().unitDivided(by: .minute())
        
        var grouped: [Date: [Double]] = [:]
        let calendar = Calendar.current
        
        for sample in samples {
            let bpmValue = sample.quantity.doubleValue(for: unit)
            let dayKey = calendar.startOfDay(for: sample.startDate)
            grouped[dayKey, default: []].append(bpmValue)
        }
        
        return grouped.mapValues { values in
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
    }
    
    /// Fetch Sleep duration (total sleep hours calculated per night) for the last 90 days.
    private func fetchSleepDuration(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let sleepType = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return [:]
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let samplePredicate = HKSamplePredicate.categorySample(type: sleepType, predicate: predicate)
        let sampleDescriptor = HKSampleQueryDescriptor(
            predicates: [samplePredicate],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        
        let samples = try await sampleDescriptor.result(for: healthStore)
        var groupedSeconds: [Date: Double] = [:]
        let calendar = Calendar.current
        
        for sample in samples {
            // Check for actual sleep stages / asleep values (filter out .inBed / .awake)
            let sleepValue = HKCategoryValueSleepAnalysis(rawValue: sample.value)
            let isAsleep: Bool
            if #available(iOS 16.0, *) {
                isAsleep = (sleepValue == .asleepUnspecified ||
                            sleepValue == .asleepCore ||
                            sleepValue == .asleepDeep ||
                            sleepValue == .asleepREM)
            } else {
                isAsleep = (sleepValue == .asleepUnspecified)
            }
            
            guard isAsleep else { continue }
            
            let durationSeconds = sample.endDate.timeIntervalSince(sample.startDate)
            // Group sleep by morning/wakeup day (endDate)
            let nightKey = calendar.startOfDay(for: sample.endDate)
            groupedSeconds[nightKey, default: 0] += durationSeconds
        }
        
        // Convert seconds to hours
        return groupedSeconds.mapValues { $0 / 3600.0 }
    }
    
    /// Fetch Active Energy Burned (daily active calorie totals in kcal) for the last 90 days.
    private func fetchActiveEnergy(from startDate: Date, to endDate: Date) async throws -> [Date: Double] {
        guard let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else {
            return [:]
        }
        
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let samplePredicate = HKSamplePredicate.quantitySample(type: energyType, predicate: predicate)
        let anchorDate = Calendar.current.startOfDay(for: startDate)
        let interval = DateComponents(day: 1)
        
        let queryDescriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: samplePredicate,
            options: .cumulativeSum,
            anchorDate: anchorDate,
            intervalComponents: interval
        )
        
        let collection = try await queryDescriptor.result(for: healthStore)
        var dailyCalories: [Date: Double] = [:]
        let kcalUnit = HKUnit.kilocalorie()
        let calendar = Calendar.current
        
        collection.enumerateStatistics(from: startDate, to: endDate) { statistics, _ in
            if let sum = statistics.sumQuantity() {
                let calories = sum.doubleValue(for: kcalUnit)
                let dayKey = calendar.startOfDay(for: statistics.startDate)
                dailyCalories[dayKey] = calories
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
        
        let sortedHRV = hrv.map { DateValue(date: $0.key, value: $0.value) }
            .sorted(by: { $0.date > $1.date })
        let sortedRHR = restingHR.map { DateValue(date: $0.key, value: $0.value) }
            .sorted(by: { $0.date > $1.date })
        let sortedSleep = sleep.map { DateValue(date: $0.key, value: $0.value) }
            .sorted(by: { $0.date > $1.date })
        let sortedEnergy = activeEnergy.map { DateValue(date: $0.key, value: $0.value) }
            .sorted(by: { $0.date > $1.date })
        
        return HealthSummary(
            hrvCount: hrv.count,
            restingHRCount: restingHR.count,
            sleepCount: sleep.count,
            activeEnergyCount: activeEnergy.count,
            avgHRV: avgHRV,
            avgRestingHR: avgRHR,
            recentHRV: Array(sortedHRV.prefix(3)),
            recentRestingHR: Array(sortedRHR.prefix(3)),
            recentSleepHours: Array(sortedSleep.prefix(3)),
            recentActiveEnergy: Array(sortedEnergy.prefix(3))
        )
    }
    
    private func printSummaryToConsole(summary: HealthSummary) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        
        print("==================================================")
        print("📊 [HEALTHKIT MANAGER] 90-DAY HEALTH DATA SUMMARY")
        print("==================================================")
        print("• Records Found (Days with Data):")
        print("  - HRV Samples:           \(summary.hrvCount) days")
        print("  - Resting HR Samples:    \(summary.restingHRCount) days")
        print("  - Sleep Analysis:        \(summary.sleepCount) days")
        print("  - Active Energy Burned:  \(summary.activeEnergyCount) days")
        print("--------------------------------------------------")
        if let avgHRV = summary.avgHRV {
            print("• Average 90-Day HRV (SDNN):      \(String(format: "%.2f", avgHRV)) ms")
        } else {
            print("• Average 90-Day HRV (SDNN):      No Data Available")
        }
        
        if let avgRHR = summary.avgRestingHR {
            print("• Average 90-Day Resting HR:      \(String(format: "%.1f", avgRHR)) bpm")
        } else {
            print("• Average 90-Day Resting HR:      No Data Available")
        }
        print("--------------------------------------------------")
        print("• Most Recent 3 Days - Raw Values:")
        
        print("  [HRV (ms)]")
        if summary.recentHRV.isEmpty { print("    (No data)") }
        for sample in summary.recentHRV {
            print("    - \(dateFormatter.string(from: sample.date)): \(String(format: "%.2f", sample.value)) ms")
        }
        
        print("  [Resting Heart Rate (bpm)]")
        if summary.recentRestingHR.isEmpty { print("    (No data)") }
        for sample in summary.recentRestingHR {
            print("    - \(dateFormatter.string(from: sample.date)): \(String(format: "%.1f", sample.value)) bpm")
        }
        
        print("  [Sleep Duration (hours)]")
        if summary.recentSleepHours.isEmpty { print("    (No data)") }
        for sample in summary.recentSleepHours {
            print("    - \(dateFormatter.string(from: sample.date)): \(String(format: "%.2f", sample.value)) hrs")
        }
        
        print("  [Active Energy (kcal)]")
        if summary.recentActiveEnergy.isEmpty { print("    (No data)") }
        for sample in summary.recentActiveEnergy {
            print("    - \(dateFormatter.string(from: sample.date)): \(String(format: "%.0f", sample.value)) kcal")
        }
        print("==================================================")
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
            return "Failed to calculate 90-day date range."
        }
    }
}
