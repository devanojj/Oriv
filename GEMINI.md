# Oriv — Agent Rules

## Project Identity

- **App Name:** Oriv
- **Bundle Identifier:** `com.oriv.health`
- **Platform:** Native iOS (SwiftUI, HealthKit, Swift Charts)
- **Target Devices:** iPhone + Apple Watch SE 2
- **Minimum Deployment:** iOS 18.0

## Hard Rules

1. **No third-party dependencies.** Use only Apple frameworks (SwiftUI, HealthKit, Foundation, Swift Charts). Never suggest CocoaPods, SPM packages, or any external library.

2. **Swift 6 strict concurrency.** All ViewModels must be `@Observable @MainActor`. All data types crossing isolation boundaries must be `Sendable`. Never use `@unchecked Sendable` without explicit justification.

3. **No manual refresh buttons.** The app uses a fully reactive syncing architecture:
   - `.task` for launch fetching
   - `.onChange(of: scenePhase)` for foreground sync
   - `.refreshable` for pull-to-refresh
   - `HKObserverQuery` + `enableBackgroundDelivery` for background updates
   
   Do not add manual "Refresh" or "Sync" buttons.

4. **HealthKit is read-only.** The app only reads health data — never write to HealthKit unless explicitly requested.

5. **ReadinessEngine is pure logic.** `ReadinessEngine.swift` is a stateless `enum` with static methods. It must have zero dependencies on HealthKit, SwiftUI, or any framework beyond Foundation. Keep it testable in isolation.

6. **Keep unit tests passing.** There are 11 unit tests in `OrivTests/ReadinessEngineTests.swift`. Any change to `ReadinessEngine.swift` or `AppViewModel.swift` must not break existing tests. Run `xcodebuild test` to verify.

7. **Preserve entitlements.** Do not modify `Oriv.entitlements` unless adding a new capability. The following must remain enabled:
   - `com.apple.developer.healthkit`
   - `com.apple.developer.healthkit.background-delivery`

## Architecture Overview

```
OrivApp (@main)
  └─ ContentView
       ├─ ReadinessHeroView (animated score gauge)
       └─ VitalsGridCardView (2×2 metric grid)
       
ContentView owns:
  └─ AppViewModel (@Observable @MainActor)
       ├─ HealthKitManager (@Observable @MainActor)
       │    └─ HKObserverQuery × 4 metrics
       │    └─ enableBackgroundDelivery × 4 metrics
       └─ ReadinessEngine (pure static scoring)
```

## Key Files

| File | Role | Isolation |
|------|------|-----------|
| `Oriv/OrivApp.swift` | Entry point | — |
| `Oriv/ContentView.swift` | Dashboard host | `@MainActor` |
| `Oriv/AppViewModel.swift` | State management | `@Observable @MainActor` |
| `Oriv/HealthKitManager.swift` | HealthKit queries & observers | `@Observable @MainActor` |
| `Oriv/ReadinessEngine.swift` | Pure scoring algorithm | None (stateless enum) |
| `Oriv/ReadinessHeroView.swift` | Score gauge UI | — |
| `Oriv/VitalsGridCardView.swift` | Vitals grid UI | — |
| `OrivTests/ReadinessEngineTests.swift` | 11 unit tests | — |

## HealthKit Metrics

| Metric | HKQuantityType / HKCategoryType | Query Pattern |
|--------|---------------------------------|---------------|
| HRV (SDNN) | `.heartRateVariabilitySDNN` | `HKSampleQueryDescriptor` (most recent per day) |
| Resting Heart Rate | `.restingHeartRate` | `HKSampleQueryDescriptor` (most recent per day) |
| Sleep Duration | `.sleepAnalysis` | `HKSampleQuery` (category samples, filtered for `.inBed` / `.asleep`) |
| Active Energy | `.activeEnergyBurned` | `HKStatisticsCollectionQueryDescriptor` (daily sum) |

All queries use a **90-day rolling window**. Background delivery is set to `.immediate` for all four types.

## Scoring Algorithm

Composite readiness score (0–100) from four weighted sub-scores:
- **HRV:** 35% — z-score (higher = better)
- **Resting HR:** 25% — inverted z-score (lower = better)  
- **Sleep:** 25% — z-score (higher = better)
- **Training Load (ACWR):** 15% — acute-to-chronic workload ratio (closer to 1.0 = better)

**Guardrails:** Sleep < 4h → cap 55. HRV drop > 30% → cap 60.
**Bands:** Ready (75–100), Good (55–74), Fair (35–54), Poor (0–34).

## Design Direction

- **Light aesthetic:** Warm off-white background (`#F7F7FA`), soft shadows, rounded corners
- **Premium feel:** Animated ring gauge, numeric text transitions, colour-coded subscore bars
- **Typography:** System fonts with weight variation (not custom fonts yet)

## Build & Test Commands

```bash
# Build
xcodebuild -project Oriv.xcodeproj -scheme Oriv \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Test
xcodebuild test -project Oriv.xcodeproj -scheme Oriv \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
