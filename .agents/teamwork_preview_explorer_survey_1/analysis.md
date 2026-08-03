# HealthKit Manager & R1 Requirements Analysis

## Executive Summary
This report presents a thorough analysis of the HealthKit integration in **Oriv** (`Health 26`), specifically targeting **Requirement 1 (R1: HealthKit Background Observer & Delivery)**.

Currently, `HealthKitManager.swift` implements manual, on-demand 90-day fetching for 4 biometrics (`.heartRateVariabilitySDNN`, `.restingHeartRate`, `.sleepAnalysis`, `.activeEnergyBurned`). **Background observer queries (`HKObserverQuery`) and background delivery configuration (`enableBackgroundDelivery(for:frequency:)`) are completely absent.**

To satisfy R1, `HealthKitManager` must be enhanced with background delivery setup, persistent `HKObserverQuery` instances for all 4 metric types with `.immediate` delivery frequency, an explicit `fetchAllMetrics()` async API, re-entrancy protection, and proper thread-safe callback handling compatible with Swift 6 strict concurrency.

---

## 1. Existing HealthKit Integration Architecture

### File Location & Annotations
- **File**: `Health 26/HealthKitManager.swift`
- **Declaration**: `@Observable @MainActor public final class HealthKitManager`
- **Core Dependencies**: `Foundation`, `HealthKit`, `Observation`
- **Internal Health Store**: `private let healthStore = HKHealthStore()`

### Current State Properties
| Property | Type | Description |
|---|---|---|
| `isAuthorized` | `Bool` | Tracks read authorization status |
| `isLoading` | `Bool` | Indicates whether a 90-day fetch query is in progress |
| `errorMessage` | `String?` | Holds user-facing error message |
| `hrvData` | `[Date: Double]` | Map of start-of-day date to daily average HRV (ms SDNN) |
| `restingHRData` | `[Date: Double]` | Map of start-of-day date to daily average Resting HR (bpm) |
| `sleepData` | `[Date: Double]` | Map of start-of-day date to daily total asleep duration (hours) |
| `activeEnergyData` | `[Date: Double]` | Map of start-of-day date to daily active energy sum (kcal) |
| `summary` | `HealthSummary?` | Container with 90-day verification summary & recent samples |

---

## 2. Analysis of Metric Types & Querying Implementation

`HealthKitManager` handles 4 specific metric types configured in `readTypes`:

```swift
private var readTypes: Set<HKObjectType> {
    var types = Set<HKObjectType>()
    if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.insert(hrv) }
    if let rhr = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { types.insert(rhr) }
    if let energy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(energy) }
    if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
    return types
}
```

### Querying Strategies Breakdown

1. **Heart Rate Variability (`.heartRateVariabilitySDNN`)**
   - **Descriptor**: `HKSampleQueryDescriptor`
   - **Predicate**: `HKQuery.predicateForSamples(withStart:startDate, end:endDate, options: .strictStartDate)`
   - **Unit**: `HKUnit.secondUnit(with: .milli)` (ms)
   - **Aggregation**: Groups raw sample values by `calendar.startOfDay(for: sample.startDate)`, calculates arithmetic mean for each day.

2. **Resting Heart Rate (`.restingHeartRate`)**
   - **Descriptor**: `HKSampleQueryDescriptor`
   - **Predicate**: `HKQuery.predicateForSamples(withStart:startDate, end:endDate, options: .strictStartDate)`
   - **Unit**: `HKUnit.count().unitDivided(by: .minute())` (bpm)
   - **Aggregation**: Groups raw sample values by `calendar.startOfDay(for: sample.startDate)`, calculates arithmetic mean for each day.

3. **Sleep Analysis (`.sleepAnalysis`)**
   - **Descriptor**: `HKSampleQueryDescriptor`
   - **Predicate**: `HKQuery.predicateForSamples(withStart:startDate, end:endDate, options: .strictStartDate)`
   - **Category Values Filtered**:
     - iOS 16+: `.asleepUnspecified`, `.asleepCore`, `.asleepDeep`, `.asleepREM` (excludes `.inBed` and `.awake`).
     - Legacy iOS: `.asleepUnspecified`.
   - **Aggregation**: Groups duration (`endDate.timeIntervalSince(startDate)`) by wake-up morning key (`calendar.startOfDay(for: sample.endDate)`), sums duration, converts to hours (`/ 3600.0`).

4. **Active Energy Burned (`.activeEnergyBurned`)**
   - **Descriptor**: `HKStatisticsCollectionQueryDescriptor`
   - **Options**: `.cumulativeSum`
   - **Unit**: `HKUnit.kilocalorie()` (kcal)
   - **Interval**: 1 day (`DateComponents(day: 1)`)
   - **Aggregation**: Enumerates statistics from start to end date, extracts `statistics.sumQuantity()`.

### Current Fetch Workflow
- Executed via `fetch90DayHealthData() async`.
- Uses `async let` for concurrent retrieval of all 4 datasets across a 90-day window (`startDate` to `endOfToday`).
- Sets `isLoading = true` at entry, `isLoading = false` in `defer` / completion.

---

## 3. Gap Analysis for Requirement 1 (R1)

### What Is Missing
1. **Background Observer Queries (`HKObserverQuery`)**: No observer queries are instantiated or executed on `HKHealthStore`.
2. **Background Delivery Enablement**: No calls to `healthStore.enableBackgroundDelivery(for:type, frequency: .immediate)`.
3. **Unified `fetchAllMetrics()` Method**: The current public API is named `fetch90DayHealthData()`. R1 specifies exposing `fetchAllMetrics() / fetch90DayHealthData()`.
4. **Observer Storage & Lifecycle**: `HealthKitManager` does not maintain active `HKObserverQuery` references.
5. **Data Update Callback / Notification**: `HealthKitManager` does not notify downstream listeners (like `AppViewModel`) when background observer queries fetch new data.

---

## 4. Specification for `fetchAllMetrics()` & `fetch90DayHealthData()`

### API Specification
To satisfy R1 requirements cleanly:
- `public func fetchAllMetrics() async` should be added as the primary async entry point.
- `fetch90DayHealthData()` can delegate directly to `fetchAllMetrics()` or act as an alias to maintain backward compatibility with existing tests and callers.

```swift
/// Triggers concurrent fetching for all 4 health metrics over the last 90 days.
public func fetchAllMetrics() async {
    await fetch90DayHealthDataInternal()
}

public func fetch90DayHealthData() async {
    await fetchAllMetrics()
}
```

### Trigger Points for `fetchAllMetrics()`
1. **App Launch**: SwiftUI `.task` in `ContentView`.
2. **Background Updates**: Triggered inside `HKObserverQuery` update handlers when new HealthKit samples are written by iOS / WatchOS.
3. **Foreground Activation**: `scenePhase == .active` transition in `ContentView`.
4. **Manual Refresh**: SwiftUI `.refreshable` pull-to-refresh.

---

## 5. Background Delivery & Observer Implementation Design

### Detailed Implementation Details

#### 1. Background Delivery Setup
For each of the 4 types (`.heartRateVariabilitySDNN`, `.restingHeartRate`, `.sleepAnalysis`, `.activeEnergyBurned`), background delivery must be enabled upon authorization:

```swift
public func enableBackgroundDelivery() async {
    guard isAuthorized else { return }
    let sampleTypes: [HKSampleType?] = [
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
        HKObjectType.quantityType(forIdentifier: .restingHeartRate),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
    ]
    
    for type in sampleTypes.compactMap({ $0 }) {
        do {
            try await healthStore.enableBackgroundDelivery(for: type, frequency: .immediate)
        } catch {
            print("[HealthKitManager] Failed to enable background delivery for \(type): \(error.localizedDescription)")
        }
    }
}
```

#### 2. Observer Queries Setup
For each sample type, construct an `HKObserverQuery` and execute it on `healthStore`:

```swift
private var activeObserverQueries: [HKObserverQuery] = []

public func startObservingBackgroundUpdates() {
    guard isAuthorized else { return }
    stopObservingBackgroundUpdates()
    
    let sampleTypes: [HKSampleType?] = [
        HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
        HKObjectType.quantityType(forIdentifier: .restingHeartRate),
        HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
        HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
    ]
    
    for sampleType in sampleTypes.compactMap({ $0 }) {
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
            guard error == nil else {
                completionHandler()
                return
            }
            Task { @MainActor [weak self] in
                await self?.fetchAllMetrics()
                completionHandler()
            }
        }
        healthStore.execute(query)
        activeObserverQueries.append(query)
    }
}

public func stopObservingBackgroundUpdates() {
    for query in activeObserverQueries {
        healthStore.stop(query)
    }
    activeObserverQueries.removeAll()
}
```

#### 3. Automatic Authorization & Observation Workflow
In `requestAuthorization()`:
1. Request HealthKit read permission.
2. If granted (`isAuthorized = true`), automatically call `enableBackgroundDelivery()` and `startObservingBackgroundUpdates()`.

---

## 6. Swift 6 Concurrency & Actor Isolation

- `HealthKitManager` is `@MainActor`.
- `HKObserverQuery` update handlers execute on background queue dispatches from `HKHealthStore`.
- The completion closure must safely transition to `@MainActor` via `Task { @MainActor [weak self] in ... }`.
- **CRITICAL**: HealthKit requires calling `completionHandler()` after background query processing completes. In the async `Task`, `completionHandler()` must be called upon completion to inform iOS that background processing is finished, avoiding background delivery throttling or process termination.

---

## 7. Dependencies, Risk Factors & Edge Cases

| Risk Factor / Edge Case | Impact | Mitigation Strategy |
|---|---|---|
| **Completion Handler Leak** | iOS halts background delivery for the app | Ensure `completionHandler()` is called in all execution paths (success, error, nil self). |
| **Concurrent Fetch Throttling** | Multiple observers or scene phase triggers overlapping queries | Implement task deduplication or re-entrancy guard in `fetchAllMetrics()` using an active `Task<Void, Never>?`. |
| **Simulator Background Limitation** | `enableBackgroundDelivery` does not trigger automatically on iOS Simulator | Test foreground manual refresh and scene phase triggers on Simulator; verify background observer logic via real hardware or Xcode HealthKit simulation tools. |
| **Un-authorized Background Attempt** | Exception or error when calling `enableBackgroundDelivery` prior to user grant | Always check `isAuthorized` and wrap background delivery setup in `try-catch`. |

---

## Conclusion & Proposed Action Plan for R1

1. **Update `HealthKitManager.swift`**:
   - Add `public func fetchAllMetrics() async`.
   - Add background observer query storage (`activeObserverQueries`).
   - Implement `enableBackgroundDelivery()` with `.immediate` frequency for all 4 types.
   - Implement `startObservingBackgroundUpdates()` with `HKObserverQuery`.
   - Call background setup during `requestAuthorization()`.
2. **Integration with `AppViewModel` (R2)**:
   - Ensure `AppViewModel` listens to metric updates or triggers `processHealthData()` whenever `fetchAllMetrics()` finishes.
3. **Integration with SwiftUI Views (R3)**:
   - Wire `.task` and `.onChange(of: scenePhase)` to invoke sync.
