# Project: Oriv Health App

## Architecture
- Framework: SwiftUI, HealthKit, Swift Observation (`@Observable`)
- Concurrency Model: `@MainActor` isolation with `async/await` and `Task`. Builds in Swift 5
  language mode; `SWIFT_STRICT_CONCURRENCY` is **not** enabled, so Swift 6 checking is not enforced.
- Project Structure: Xcode Project `Oriv.xcodeproj`, Scheme `Oriv`
  - `HealthKitManager.swift`: Encapsulates HealthKit store, background observers, background delivery, and metric fetching.
  - `AppViewModel.swift`: Main ViewModel (`@Observable @MainActor`) managing state and reactive synchronization with `HealthKitManager`.
  - `ContentView.swift`: Main SwiftUI view observing `AppViewModel`, with reactive lifecycle modifiers (`.task`, `.refreshable`, `.onChange(of: scenePhase)`).
  - `ReadinessEngine.swift`: Pure scoring engine — z-scores, variance-corrected composite, guardrails, bands.
  - `Theme.swift`: Semantic colour tokens; light and dark defined together.
  - `StatusCardView.swift`: The no-score states (permission, no data, stale, building baseline).
  - `Auth/`: Authentication (see [AUTH_DESIGN.md](AUTH_DESIGN.md)). `AuthManager` (`@Observable @MainActor`)
    mirrors `HealthKitManager`'s shape; `RootView` gates on `AuthState` and `ContentView` sits
    beneath it unchanged. Backed by `InMemoryAuthService` until Supabase is wired.
  - `OrivTests/`: `ReadinessEngineTests`, `BaselineStatisticsTests`, `ThemeContrastTests`,
    `AuthManagerTests`, `AppleSignInTests`, `HealthKitManagerStressTests`.

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
- `public var onDataUpdated: (@MainActor () async -> Void)?`: Invoked on `@MainActor` after a successful fetch, including fetches triggered by background delivery.
- `public private(set) var accessState: HealthAccessState`: `.unknown` / `.unavailable` / `.needsAuthorization` / `.noDataVisible` / `.authorized`. Drives which screen `ContentView` shows.
- `public var isAuthorized: Bool`: Computed — true only when `accessState == .authorized`.
- `public func refreshAccessState() async`: Determines whether the permission sheet is still needed, without presenting it.
- `public func requestAuthorization() async throws`: Presents the HealthKit sheet and starts observers. Does **not** imply access was granted — HealthKit never reports read status.
- `public func fetchAllMetrics() async`: Fetches all four metrics over 90 days concurrently and publishes them. Returns `Void`; results land on the manager's `hrvData` / `restingHRData` / `sleepData` / `activeEnergyData`.
- `public func fetch90DayHealthData() async`: Compatibility wrapper for `fetchAllMetrics()`.
- `public func startObservingBackgroundUpdates() async`: Sets up `HKObserverQuery` plus `enableBackgroundDelivery(for:frequency: .immediate)` for the 4 sample types.
- `public func stopObservingBackgroundUpdates()`: Stops and clears all observer queries.

### AppViewModel ↔ SwiftUI Views
- `@Observable @MainActor final class AppViewModel`: Publishes `calculatedResult`, `metricRecencies`, `recencyNote`. Loading and error state live on `healthKitManager` (`isLoading`, `errorMessage`).
- `public func loadAndCalculateReadiness() async`: Refreshes access state, fetches, then scores.
- `public func requestHealthAccess() async`: Presents the permission sheet, then fetches and scores.
- `public func processHealthData()`: Converts the manager's raw data into a `ReadinessInput` and scores it.

### ReadinessEngine
- `public static func calculate(from: ReadinessInput) -> ReadinessResult`: Pure. Imports only `Foundation`.
- `ReadinessResult.status`: `.scored` / `.insufficientBaseline` / `.staleData(daysAgo:)`. `insufficientData` is a computed convenience meaning "not `.scored`".
- `ReadinessEngine.Tuning`: All calibration constants (weights, 7-day baseline minimum, ±3σ clamp, correlation, centre 70 / spread 15, guardrail caps, 1-day freshness window).

## Code Layout
- `Oriv/HealthKitManager.swift`
- `Oriv/AppViewModel.swift`
- `Oriv/ContentView.swift`
- `OrivTests/ReadinessEngineTests.swift`
- `Oriv.xcodeproj`
