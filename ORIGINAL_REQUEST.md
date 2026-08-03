# Original User Request

## Initial Request — 2026-08-03T09:44:21Z

Refactor Oriv to eliminate the manual "Refresh" button and establish an automatic, reactive HealthKit syncing architecture using background observer queries, scene phase lifecycle listeners, and native pull-to-refresh.

Working directory: /Users/devano/Documents/Projects/H24/Health 26
Integrity mode: development

## Requirements

### R1. HealthKit Background Observer & Delivery
- Implement HKObserverQuery observers in HealthKitManager.swift for HRV (.heartRateVariabilitySDNN), Resting Heart Rate (.restingHeartRate), Sleep Analysis (.sleepAnalysis), and Active Energy (.activeEnergyBurned).
- Enable background delivery via healthStore.enableBackgroundDelivery(for:frequency: .immediate) for all 4 types.
- Expose an async method fetchAllMetrics() / fetch90DayHealthData() that is triggered on launch, background updates, and manual refresh requests.

### R2. AppViewModel Reactive Synchronization & Concurrency
- Refactor AppViewModel.swift (@Observable @MainActor) to subscribe to HealthKit observer updates and automatically recalculate readiness whenever new data arrives.
- Enforce strict Swift 6 actor isolation and thread-safety.

### R3. SwiftUI Reactive View Architecture
- Remove the manual "Refresh Health Data" button from ContentView.swift.
- Implement .task modifier for automatic launch fetching.
- Implement .onChange(of: scenePhase) to re-fetch when transitioning back to .active.
- Maintain native .refreshable { await viewModel.loadAndCalculateReadiness() } pull-to-refresh support.

## Acceptance Criteria

### Functional Sync & Concurrency
- [ ] No manual refresh buttons exist in the UI.
- [ ] Background observer queries and background delivery are enabled for all 4 HealthKit metrics.
- [ ] Transitioning scenePhase to .active or launching the app automatically triggers a data sync.
- [ ] Native pull-to-refresh (.refreshable) works smoothly.
- [ ] Codebase compiles cleanly with xcodebuild build without Swift 6 concurrency warnings.
- [ ] All 11 existing unit tests in ReadinessEngineTests.swift pass with xcodebuild test.
