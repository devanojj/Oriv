# Milestone 1 Implementation Strategy: HealthKit Background Observer & Delivery

## Executive Summary

This report formulates a precise, production-grade implementation strategy for **Milestone 1 (HealthKit Background Observer & Delivery)** in `HealthKitManager.swift`. 

Milestone 1 transforms `HealthKitManager` from an on-demand, pull-only manager into a reactive, background-enabled data source. The strategy specifically addresses:
1. **Swift 6 Strict Concurrency & Actor Isolation**: Safe background thread-hopping to `@MainActor`, memory management (`[weak self]`), deterministic HealthKit `completionHandler()` execution, and fetch task deduplication (`activeFetchTask`).
2. **`HKObserverQuery` Lifecycle Management**: Persistent array storage, background delivery configuration with `.immediate` frequency across all 4 target metrics, robust error recovery, and clean teardown (`stopObservingBackgroundUpdates()`).
3. **Public Interface & Backward Compatibility**: Introducing `fetchAllMetrics() async`, bridging `fetch90DayHealthData() async`, and adding `onDataUpdated: (@MainActor () async -> Void)?` callback hook for Milestone 2 (`AppViewModel`).

---

## 1. Swift 6 Concurrency & Actor Isolation Strategy

### Context & Problem Statement
- `HealthKitManager` is annotated `@Observable @MainActor public final class HealthKitManager`.
- HealthKit background delivery triggers observer query update handlers on arbitrary background dispatch queues managed by system services (`healthd`).
- Swift 6 strict concurrency (`-strict-concurrency=complete`) enforces strict isolation boundaries. Passing non-isolated closures that access `@MainActor` state results in compile-time isolation errors.
- **Critical System Constraint**: iOS tracks background runtime granted to apps upon receiving background observer notifications. The app **must** call the provided `completionHandler()` once processing finishes. Failure to call `completionHandler()` causes iOS to penalize or terminate the background process and disable future background notifications.

### Design Patterns & Solutions

#### A. Actor-Hopping Task Closure
In the `HKObserverQuery` update handler closure, we capture `[weak self]` and construct an explicit `@MainActor` isolated `Task`:

```swift
let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
    guard error == nil else {
        print("[HealthKitManager] Observer query error for \(sampleType.identifier): \(String(describing: error))")
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

#### B. Guaranteed `completionHandler()` Execution Path
- **Error path**: Called immediately on the background callback thread if `error != nil`.
- **Deallocated instance path**: Called immediately if `self == nil` when `@MainActor` task starts.
- **Success path**: Called at the conclusion of `await self.fetchAllMetrics()`, ensuring that 90-day metric fetching and `onDataUpdated` notifications finish before reporting completion back to HealthKit.

#### C. In-Flight Fetch Deduplication (`activeFetchTask`)
When multiple HealthKit metrics update simultaneously (e.g. HRV and Resting Heart Rate written at the same time by Apple Watch), multiple `HKObserverQuery` callbacks may fire concurrently.
To prevent overlapping 90-day queries, `HealthKitManager` maintains an in-flight fetch task reference:

```swift
private var activeFetchTask: Task<Void, Never>? = nil

public func fetchAllMetrics() async {
    // If a fetch operation is already running, await its completion instead of launching a duplicate query
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

## 2. `HKObserverQuery` Lifecycle & Background Delivery Strategy

### Target Metrics Catalog
Background delivery and observer queries will be enabled for the 4 core biometrics required by `Oriv`:
1. **HRV**: `HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)`
2. **Resting Heart Rate**: `HKQuantityType.quantityType(forIdentifier: .restingHeartRate)`
3. **Sleep Analysis**: `HKCategoryType.categoryType(forIdentifier: .sleepAnalysis)`
4. **Active Energy Burned**: `HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)`

### Storage & State Management
- Storage Property: `private var activeObserverQueries: [HKObserverQuery] = []` on `@MainActor`.
- Registration Method: `public func startObservingBackgroundUpdates() async`
  1. Calls `stopObservingBackgroundUpdates()` to clear stale queries.
  2. Iterates over all 4 sample types.
  3. Calls `healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate)`.
  4. Instantiates `HKObserverQuery` for the sample type.
  5. Executes `healthStore.execute(query)` and stores reference in `activeObserverQueries`.
- Teardown Method: `public func stopObservingBackgroundUpdates()`
  Iterates over `activeObserverQueries`, calls `healthStore.stop(query)`, and clears `activeObserverQueries.removeAll()`.

### Automatic Registration Flow
In `requestAuthorization()`:
```swift
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
```

---

## 3. Public Interface & Backward Compatibility Strategy

### API Contracts

| Interface Component | Signature / Details | Purpose & Compatibility |
|---|---|---|
| Primary Fetch Entry Point | `public func fetchAllMetrics() async` | Primary async metric fetch trigger for launch, observer callbacks, and scene phase transitions. |
| Legacy Fetch Alias | `public func fetch90DayHealthData() async` | Delegates to `fetchAllMetrics()`. Retains 100% compatibility with existing callers. |
| Reactive Callback Hook | `public var onDataUpdated: (@MainActor () async -> Void)?` | Callback invoked at the end of `fetchAllMetrics()` to notify `AppViewModel` (M2). |
| Background Observers Start | `public func startObservingBackgroundUpdates() async` | Enables background delivery and starts `HKObserverQuery` instances. |
| Background Observers Stop | `public func stopObservingBackgroundUpdates()` | Stops and clears active observer queries. |

### Interaction Flow Diagram

```
[HKObserverQuery Callback / Scene Phase / Manual Refresh]
                       │
                       ▼
            healthKitManager.fetchAllMetrics()
                       │
         ┌─────────────┴─────────────┐
         ▼                           ▼
[Active Fetch Exists?]    [No Active Fetch]
         │                           │
  Await Existing Task    Create & Store activeFetchTask
         │                           │
         │                  Perform 90-Day Fetch
         │                           │
         │                Update Properties & Summary
         │                           │
         │              Invoke onDataUpdated Callback
         │                           │
         └─────────────┬─────────────┘
                       │
                       ▼
        Call HKObserverQuery Completion Handler
```

---

## 4. Detailed Code Specification for `HealthKitManager.swift`

Below is the complete, proposed blueprint for `HealthKitManager.swift`:

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
    
    /// Callback invoked on @MainActor whenever new health metrics are fetched via background observers or manual requests.
    public var onDataUpdated: (@MainActor () async -> Void)? = nil
    
    private let healthStore = HKHealthStore()
    private var activeObserverQueries: [HKObserverQuery] = []
    private var activeFetchTask: Task<Void, Never>? = nil
    
    // Required read types
    private var readTypes: Set<HKObjectType> {
        Set(sampleTypesToObserve)
    }
    
    private var sampleTypesToObserve: [HKSampleType] {
        var types: [HKSampleType] = []
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.append(hrv) }
        if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.append(rhr) }
        if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.append(energy) }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }
        return types
    }
    
    public init() {}
    
    /// Request read authorization for required HealthKit types and start background observation upon success.
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
    
    /// Enables background delivery and starts HKObserverQuery instances for all 4 metrics.
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
            
            let generatedSummary = computeSummary(
                hrv: fetchedHRV,
                restingHR: fetchedRestingHR,
                sleep: fetchedSleep,
                activeEnergy: fetchedEnergy
            )
            self.summary = generatedSummary
            
            printSummaryToConsole(summary: generatedSummary)
            
            if let onDataUpdated = onDataUpdated {
                await onDataUpdated()
            }
            
        } catch {
            self.errorMessage = "Failed to fetch 90-day health data: \(error.localizedDescription)"
            print("[HealthKitManager ERROR] \(error.localizedDescription)")
        }
    }
    
    // MARK: - Query Methods (fetchHRV, fetchRestingHR, fetchSleepDuration, fetchActiveEnergy remain unchanged)
...
```

---

## 5. Risk Assessment & Edge Cases

1. **iOS Simulator Limitations**: `enableBackgroundDelivery` may throw an error on iOS Simulator because background updates are not simulated by default. Wrapping `enableBackgroundDelivery` in `do-catch` ensures `HKObserverQuery` is still executed and functions for foreground/background changes in simulator testing.
2. **Background Processing Timeout**: iOS caps background task execution time. The task deduplication mechanism (`activeFetchTask`) ensures concurrent observer triggers collapse into a single 90-day fetch operation, avoiding background timeout penalties.
3. **Authorization Revocation**: If authorization is revoked, `startObservingBackgroundUpdates()` guards on `isAuthorized`, preventing invalid query execution.

---

## Conclusion & Actionable Next Steps

This strategy provides a complete, thread-safe solution for Milestone 1:
- `HealthKitManager.swift` gains `fetchAllMetrics()`, `onDataUpdated`, `startObservingBackgroundUpdates()`, and background delivery enablement.
- `fetch90DayHealthData()` is preserved for 100% backward compatibility.
- Swift 6 strict concurrency compliance is guaranteed.
