# Project: Oriv Health App

## Architecture
- Framework: SwiftUI, HealthKit, Swift Observation (`@Observable`)
- Concurrency Model: Swift 6 strict concurrency (`@MainActor`, `async/await`, `Task`)
- Project Structure: Xcode Project `Health 26.xcodeproj`, Scheme `Health 26`
  - `HealthKitManager.swift`: Encapsulates HealthKit store, background observers, background delivery, and metric fetching.
  - `AppViewModel.swift`: Main ViewModel (`@Observable @MainActor`) managing state and reactive synchronization with `HealthKitManager`.
  - `ContentView.swift`: Main SwiftUI view observing `AppViewModel`, with reactive lifecycle modifiers (`.task`, `.refreshable`, `.onChange(of: scenePhase)`).
  - `ReadinessEngineTests.swift`: Unit test suite in `Health 26Tests`.

## Feature Inventory
| # | Feature | Description | Milestone | Source |
|---|---------|-------------|-----------|--------|
| 1 | HealthKit Observer Queries | Register `HKObserverQuery` for `.heartRateVariabilitySDNN`, `.restingHeartRate`, `.sleepAnalysis`, `.activeEnergyBurned` | M1 | R1 |
| 2 | Background Delivery | Call `enableBackgroundDelivery(for:frequency: .immediate)` for all 4 metric types | M1 | R1 |
| 3 | Async Metric Fetching | Expose `fetchAllMetrics()` and `fetch90DayHealthData()` async methods on `HealthKitManager` | M1 | R1 |
| 4 | MainActor Thread Hopping | Ensure observer query callbacks safely hop to `@MainActor` and call completion handlers | M1 | R1 / R2 |
| 5 | Reactive Sync Callback | Expose `onDataUpdated` callback on `HealthKitManager` for ViewModel reactive sync | M1 / M2 | R2 |
| 6 | ViewModel Reactive Sync | `AppViewModel` (`@Observable @MainActor`) subscribes to `onDataUpdated` and auto-syncs state | M2 | R2 |
| 7 | Swift 6 Isolation | Strict actor isolation in `AppViewModel` and `HealthKitManager` without concurrency warnings | M2 | R2 |
| 8 | Remove Refresh Button | Remove manual "Refresh Health Data" button from `ContentView.swift` | M3 | R3 |
| 9 | Lifecycle Reactive Modifiers | Retain `.task` and `.refreshable` in `ContentView.swift` | M3 | R3 |
| 10 | ScenePhase Foreground Sync | Add `@Environment(\.scenePhase)` and `.onChange(of: scenePhase)` for foreground sync on `.active` | M3 | R3 |
| 11 | Build & Test Verification | Validate with `xcodebuild build` and `xcodebuild test` (`ReadinessEngineTests.swift`) | M4 | R4 |

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| M1 | HealthKit Background Observer & Delivery | Implement background delivery, observer queries, `fetchAllMetrics()`, `@MainActor` callback bridge in `HealthKitManager.swift` | None | PLANNED |
| M2 | AppViewModel Reactive Synchronization | Refactor `AppViewModel.swift` with `@Observable @MainActor`, subscribe to `onDataUpdated`, strict Swift 6 isolation | M1 | PLANNED |
| M3 | SwiftUI Reactive View Architecture | Update `ContentView.swift`: remove manual button, keep `.task`/`.refreshable`, add `.onChange(of: scenePhase)` | M2 | PLANNED |
| M4 | E2E & Unit Test Verification | Build and run `ReadinessEngineTests.swift` via `xcodebuild` | M1, M2, M3 | PLANNED |

## Interface Contracts
### HealthKitManager ↔ AppViewModel
- `public var onDataUpdated: (@MainActor () async -> Void)?`: Callback invoked on `@MainActor` when background delivery or query updates occur.
- `public func fetchAllMetrics() async -> HealthDataPackage`: Alias/wrapper for fetching all 90-day health metrics.
- `public func fetch90DayHealthData() async -> HealthDataPackage`: Returns full health data.
- `public func enableBackgroundObservers()`: Sets up `HKObserverQuery` and `enableBackgroundDelivery(for:frequency: .immediate)` for 4 sample types.

### AppViewModel ↔ SwiftUI Views
- `@Observable @MainActor final class AppViewModel`: Publishes `calculatedResult`, `metricRecencies`, `recencyNote`, `isLoading`, `errorMessage`.
- `public func loadData() async`: Invokes `healthKitManager.fetchAllMetrics()` and runs `processHealthData()`.

## Code Layout
- `Health 26/HealthKitManager.swift`
- `Health 26/AppViewModel.swift`
- `Health 26/ContentView.swift`
- `Health 26Tests/ReadinessEngineTests.swift`
- `Health 26.xcodeproj`
