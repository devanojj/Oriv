# Milestone 1 Implementation Strategy: HealthKit Background Observer & Delivery

## Executive Summary

This report establishes the complete, production-grade implementation strategy for **Milestone 1 (HealthKit Background Observer & Delivery in `HealthKitManager.swift`)** for **Oriv**. 

Milestone 1 transforms `HealthKitManager` from an on-demand manual fetch utility into an automated, background-reactive HealthKit manager. The implementation adds persistent `HKObserverQuery` observers, background delivery enablement with `.immediate` frequency for all 4 target biometrics, an explicit `fetchAllMetrics()` async method, task deduplication for overlapping updates, an `@MainActor` callback hook `onDataUpdated`, and safe thread-hopping for Swift 6 strict concurrency while guaranteeing deterministic invocation of HealthKit's background completion handlers.

---

## 1. Core Requirements & Interface Contracts (Milestone 1)

### Requirements Mapping (R1)
1. **Background Observer Queries**: Register `HKObserverQuery` for:
   - `.heartRateVariabilitySDNN` (Quantity Type)
   - `.restingHeartRate` (Quantity Type)
   - `.sleepAnalysis` (Category Type)
   - `.activeEnergyBurned` (Quantity Type)
2. **Background Delivery Enablement**: Enable background delivery via `healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate)` for all 4 sample types.
3. **Async Fetch Methods**: Expose `fetchAllMetrics() async` as the primary fetch API and retain `fetch90DayHealthData() async` as a backward-compatible wrapper/alias.
4. **Thread Hopping & Completion Handling**: Safely transition background observer callbacks to `@MainActor`, invoke `onDataUpdated?()`, and reliably call `completionHandler()` after query execution.

### Public Interface Contracts (`HealthKitManager.swift`)

```swift
@Observable
@MainActor
public final class HealthKitManager {
    // Reactive callback hook for AppViewModel (M2)
    public var onDataUpdated: (@MainActor () async -> Void)? = nil
    
    // Authorization & Background Management
    public func requestAuthorization() async throws
    public func startObservingBackgroundUpdates() async
    public func stopObservingBackgroundUpdates()
    
    // Async Metric Fetching APIs
    public func fetchAllMetrics() async
    public func fetch90DayHealthData() async
}
```

---

## 2. Detailed Technical Design & Architecture

### A. Sample Types & Metric Catalog
To keep the codebase DRY and maintainable, sample types are defined via a consolidated computed property:

```swift
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
```

### B. Observer Query Registration & Background Delivery
1. **Observer Storage**: `private var activeObserverQueries: [HKObserverQuery] = []` holds references to active queries on `@MainActor`.
2. **Teardown**: `stopObservingBackgroundUpdates()` iterates through `activeObserverQueries`, invokes `healthStore.stop(query)`, and clears the array.
3. **Registration Flow (`startObservingBackgroundUpdates() async`)**:
   - Checks `guard isAuthorized else { return }`.
   - Clears existing queries via `stopObservingBackgroundUpdates()`.
   - For each `sampleType` in `sampleTypesToObserve`:
     a. Attempts `healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate)` wrapped in a `do-catch` block (logs warnings if unsupported or failing on Simulator).
     b. Constructs an `HKObserverQuery`.
     c. Calls `healthStore.execute(query)` and appends to `activeObserverQueries`.

### C. Concurrency, Actor Isolation & Completion Handler Safety
- `HealthKitManager` is `@MainActor` isolated.
- `HKObserverQuery` update handlers execute on arbitrary background dispatch queues managed by iOS system processes (`healthd`).
- **Completion Handler Rule**: iOS allocates limited background runtime when delivering updates. The app **must** execute `completionHandler()` when background processing is complete. Failure to call it leads to background delivery throttling or process termination.
- **Actor-Hopping Pattern**:
  ```swift
  let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
      guard error == nil else {
          print("[HealthKitManager] Observer query callback error for \(sampleType.identifier): \(String(describing: error))")
          completionHandler()
          return
      }
      
      Task { @MainActor [weak self] in
          guard let self = self else {
              completionHandler()
              return
          }
          await self.fetchAllMetrics()
          completionHandler()
      }
  }
  ```
  This guarantees:
  - Error condition -> `completionHandler()` called immediately on background thread.
  - Deallocated instance (`self == nil`) -> `completionHandler()` called immediately on `@MainActor`.
  - Normal execution -> `completionHandler()` called on `@MainActor` **after** `await self.fetchAllMetrics()` finishes fetching data and calling `onDataUpdated?()`.

### D. In-Flight Fetch Task Deduplication
When multiple metrics update simultaneously (e.g., HRV and Resting HR delivered together by Apple Watch), multiple observer queries fire within milliseconds.
To prevent overlapping, redundant 90-day queries:
```swift
private var activeFetchTask: Task<Void, Never>? = nil

public func fetchAllMetrics() async {
    if let existingTask = activeFetchTask {
        await existingTask.value
        return
    }
    
    let task = Task { @MainActor in
        await self.performFetchAllMetrics()
    }
    self.activeFetchTask = task
    await task.value
    self.activeFetchTask = nil
}
```

---

## 3. Precise Code Blueprint for `HealthKitManager.swift`

Below is the complete code specification for `Health 26/HealthKitManager.swift`:

```swift
//
//  HealthKitManager.swift
//  Health 26
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
                    guard let self = self else {
                        completionHandler()
                        return
                    }
                    await self.fetchAllMetrics()
                    completionHandler()
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
        if let existingTask = activeFetchTask {
            await existingTask.value
            return
        }
        
        let task = Task { @MainActor in
            await self.performFetchAllMetrics()
        }
        self.activeFetchTask = task
        await task.value
        self.activeFetchTask = nil
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
            if let onDataUpdated = onDataUpdated {
                await onDataUpdated()
            }
            
        } catch {
            self.errorMessage = "Failed to fetch 90-day health data: \(error.localizedDescription)"
            print("[HealthKitManager ERROR] \(error.localizedDescription)")
        }
    }
    
    // MARK: - Query Methods
    
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
        
        return grouped.mapValues { values in
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / Double(values.count)
        }
    }
    
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
            let nightKey = calendar.startOfDay(for: sample.endDate)
            groupedSeconds[nightKey, default: 0] += durationSeconds
        }
        
        return groupedSeconds.mapValues { $0 / 3600.0 }
    }
    
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
```

---

## 4. Risk Analysis & Edge Case Mitigations

| Risk / Edge Case | Cause / Trigger | Technical Impact | Mitigation Strategy |
|---|---|---|---|
| **Background Completion Leak** | Exception or forgotten `completionHandler()` in async path | iOS halts future background delivery to app or kills process | `completionHandler()` called explicitly in error path, nil-self path, and post-fetch path |
| **Concurrent Query Throttling** | Multiple metric updates fire simultaneously | Multiple heavy 90-day queries run concurrently | `activeFetchTask` coalesces concurrent callers to single Task |
| **iOS Simulator Limitations** | Simulator does not generate background delivery events | `enableBackgroundDelivery` throws error | Wrap `enableBackgroundDelivery` in `do-catch` so queries execute regardless |
| **Authorization Revocation** | User revokes HealthKit permissions in Settings | Background queries fail or throw errors | Guard with `isAuthorized` check; clear active observers |

---

## 5. Verification & Test Plan

1. **Static Analysis & Compilation**:
   - Ensure clean compilation with `xcodebuild build -scheme "Health 26" -destination "generic/platform=iOS Simulator"` under Swift 6 strict concurrency checks.
2. **Unit Tests**:
   - Run `xcodebuild test -scheme "Health 26" -destination "platform=iOS Simulator,name=iPhone 16 Pro"` to ensure all 11 existing unit tests in `ReadinessEngineTests.swift` pass cleanly.
3. **Runtime & Background Verification**:
   - Verify `startObservingBackgroundUpdates()` registers 4 `HKObserverQuery` instances in `activeObserverQueries`.
   - Verify calling `fetchAllMetrics()` triggers `onDataUpdated` callback when set.
