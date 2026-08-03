# Oriv — Daily Readiness Score for iOS

Oriv is a native iOS app (Swift 6 / SwiftUI / HealthKit) that reads HRV, Resting Heart Rate, Sleep, and Active Energy from Apple Health and computes a **daily readiness score (0–100)** with recovery bands, sub-scores, and actionable recommendations. The app targets iPhone + Apple Watch SE 2 and uses **zero third-party dependencies**.

---

## Quick Facts

| Key | Value |
|-----|-------|
| **Platform** | iOS 18.0+ (iPhone + Apple Watch SE 2) |
| **Language** | Swift 5 / Swift 6 strict concurrency |
| **UI** | SwiftUI (`@Observable`, `@MainActor`) |
| **Data** | HealthKit (read-only, 90-day rolling window) |
| **Bundle ID** | `com.oriv.health` |
| **Tests** | 11 unit tests (`ReadinessEngineTests`) |
| **Dependencies** | None — pure Apple frameworks only |

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│                   SwiftUI Layer                      │
│  ContentView  ←  ReadinessHeroView                   │
│                  VitalsGridCardView                   │
│       │                                              │
│       ▼                                              │
│  AppViewModel  (@Observable @MainActor)              │
│       │               │                              │
│       ▼               ▼                              │
│  HealthKitManager    ReadinessEngine                  │
│  (HKObserverQuery    (pure scoring,                   │
│   background         z-scores,                        │
│   delivery)          ACWR, guardrails)                │
└──────────────────────────────────────────────────────┘
```

### Data Flow

1. **Launch / Foreground / Background update** → `HealthKitManager.fetchAllMetrics()` queries 90 days of HRV, Resting HR, Sleep, and Active Energy from HealthKit.
2. **`AppViewModel.processHealthData()`** converts raw samples into `ReadinessInput` (normalised baselines, training load ratios, most-recent-sample fallback).
3. **`ReadinessEngine.calculate(from:)`** produces a `ReadinessResult` with composite score, band, sub-scores, and recommendations.
4. **SwiftUI views** reactively render the hero gauge (`ReadinessHeroView`) and vitals grid (`VitalsGridCardView`).

### Reactive Syncing (no manual refresh button)

| Trigger | Mechanism |
|---------|-----------|
| App launch | `.task { await viewModel.loadData() }` |
| Return to foreground | `.onChange(of: scenePhase)` when `.active` |
| Pull-to-refresh | `.refreshable { await viewModel.loadAndCalculateReadiness() }` |
| Background HealthKit update | `HKObserverQuery` → `onDataUpdated` callback → auto re-fetch |

---

## File Map

### Source (`Oriv/`)

| File | Purpose |
|------|---------|
| `OrivApp.swift` | `@main` entry point — `WindowGroup { ContentView() }` |
| `HealthKitManager.swift` | HealthKit auth, background observers, background delivery, 90-day concurrent fetching (`async let`). `@Observable @MainActor`. |
| `AppViewModel.swift` | Presentation ViewModel — processes raw data, calculates readiness, manages recency state. `@Observable @MainActor`. |
| `ReadinessEngine.swift` | Pure static scoring engine — z-scores, ACWR load ratios, guardrails, dynamic weight redistribution. Stateless `enum`. |
| `ContentView.swift` | Main dashboard — date header, error banners, hero gauge, vitals grid. Reactive lifecycle modifiers. |
| `ReadinessHeroView.swift` | Animated circular score gauge, recovery band badge, recommendation text, recency pill. |
| `VitalsGridCardView.swift` | 2×2 `LazyVGrid` — live metric values, units, recency tags, colour-coded subscore bars. |
| `Oriv.entitlements` | HealthKit + background delivery entitlements. |
| `Assets.xcassets/` | App icon (1024×1024 PNG), accent colour. |

### Tests

| File | Purpose |
|------|---------|
| `OrivTests/ReadinessEngineTests.swift` | 11 unit tests covering scoring, guardrails, partial data, training load spikes, edge cases. |
| `OrivUITests/OrivUITests.swift` | UI test skeleton + launch performance metric. |

### Config

| File | Purpose |
|------|---------|
| `Oriv.xcodeproj/` | Xcode project bundle (scheme: `Oriv`). |
| `.gitignore` | Ignores build/, DerivedData/, xcuserdata/, .DS_Store, etc. |
| `PROJECT.md` | Detailed architecture doc with feature inventory, milestones, and interface contracts. |

---

## Readiness Scoring Algorithm

The `ReadinessEngine` computes a composite score from four sub-scores:

| Metric | Base Weight | Z-Score Direction |
|--------|-------------|-------------------|
| HRV (SDNN) | 35% | Higher = better |
| Resting Heart Rate | 25% | Lower = better (inverted) |
| Sleep Duration | 25% | Higher = better |
| Training Load (ACWR) | 15% | Closer to 1.0 = better |

**Guardrails:**
- Score capped at **55** if sleep < 4 hours.
- Score capped at **60** if today's HRV drops > 30% vs. yesterday.

**Bands:**
- `Ready` (75–100), `Good` (55–74), `Fair` (35–54), `Poor` (0–34), `Insufficient Data` (< 3 days baseline).

Missing metrics trigger **dynamic weight redistribution** — available weights are re-normalised so the score remains meaningful.

---

## Build & Test

```bash
# Build (simulator)
xcodebuild -project Oriv.xcodeproj -scheme Oriv \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build

# Run unit tests
xcodebuild test -project Oriv.xcodeproj -scheme Oriv \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

All 11 tests should pass with 0 failures.

---

## Privacy

| Key | Value |
|-----|-------|
| `NSHealthShareUsageDescription` | "Oriv reads your HRV, Resting HR, Sleep, and Active Energy to compute your daily readiness score." |
| `NSHealthUpdateUsageDescription` | "Oriv needs access to your health data." |

The app requests **read-only** access to HealthKit. No data leaves the device.

---

## Status

- ✅ HealthKit integration with background delivery
- ✅ Readiness scoring engine with guardrails
- ✅ Reactive UI — no manual refresh button
- ✅ 11/11 unit tests passing
- ✅ App icon (1024×1024)
- ✅ Privacy strings configured
- ✅ Project fully renamed from "Health 26" to "Oriv"
