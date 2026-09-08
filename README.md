# Oriv — Daily Readiness Score for iOS

Oriv is a native iOS app (SwiftUI / HealthKit) that reads HRV, Resting Heart Rate, Sleep, and Active Energy from Apple Health and computes a **daily readiness score (0–100)** with recovery bands, sub-scores, and a training recommendation. Zero third-party dependencies.

---

## Quick Facts

| Key | Value |
|-----|-------|
| **Platform** | iOS 18.0+ |
| **Devices** | iPhone (`TARGETED_DEVICE_FAMILY = 1`) — no watchOS target |
| **Language** | Swift 5 language mode, with `@MainActor` isolation and `async`/`await` throughout |
| **UI** | SwiftUI (`@Observable`, `@MainActor`), light and dark mode |
| **Data** | HealthKit, read-only, 90-day rolling fetch |
| **Bundle ID** | `com.oriv.health` |
| **Version** | 1.0 (build 1) |
| **Dependencies** | None — Apple frameworks only |

> **Note on concurrency:** the project builds in Swift 5 language mode (`SWIFT_VERSION = 5.0`) and does not set `SWIFT_STRICT_CONCURRENCY`. The code is written to be actor-correct — `HealthKitManager` and `AppViewModel` are `@MainActor`, and the scoring types are `Sendable` — but Swift 6 strict-concurrency checking is **not** enforced by the compiler. Turning it on is a separate piece of work.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                   SwiftUI Layer                      │
│  ContentView ──┬── ReadinessHeroView                 │
│                ├── VitalsGridCardView                │
│                └── StatusCardView (empty states)     │
│       │                                              │
│       ▼                                              │
│  AppViewModel  (@Observable @MainActor)              │
│   • baseline statistics                              │
│   • freshness gating                                 │
│   • training-load windows                            │
│       │               │                              │
│       ▼               ▼                              │
│  HealthKitManager    ReadinessEngine                 │
│  (queries, observer   (pure scoring —                │
│   queries, access     no HealthKit, no dates)        │
│   state)                                             │
└──────────────────────────────────────────────────────┘
```

`ReadinessEngine` imports only `Foundation`. Everything it needs arrives in a `ReadinessInput`, which is what makes the scoring unit-testable without a health store.

### Reactive syncing (no manual refresh button)

| Trigger | Mechanism |
|---------|-----------|
| App launch | `.task { await viewModel.loadAndCalculateReadiness() }` |
| Return to foreground | `.onChange(of: scenePhase)` when `.active` |
| Pull-to-refresh | `.refreshable { … }` |
| Background HealthKit update | `HKObserverQuery` → `onDataUpdated` → recalculate |

---

## Readiness scoring

### Per-metric z-scores

Each metric is compared against **your own** recent baseline:

| Metric | Weight | Direction |
|--------|--------|-----------|
| HRV (SDNN) | 35% | Higher is better |
| Resting Heart Rate | 25% | Lower is better (inverted) |
| Sleep Duration | 25% | Higher is better |
| Training Load (ACWR) | 15% | Closer to 1.0 is better |

Individual z-scores are clamped to ±3σ so one freak reading can't dominate. Metrics without enough history, or without a fresh sample, are dropped and the remaining weights renormalise.

### Baseline construction

The baseline is what "normal" means for you, and it is deliberately not a flat average of everything on file:

- **Rolling 60-day window** — shorter than the 90-day fetch, so a fitness change three months ago doesn't anchor today's score.
- **Exponential recency weighting**, 14-day half-life — the baseline tracks who you are now.
- **Outlier trimming** at 3.5 modified z-scores (median absolute deviation) — one bad night doesn't permanently widen σ and flatten every future score.
- **The scored day is never in its own baseline** — including it pins the z-score at zero.
- **Minimum 7 days** of usable history per metric before it may contribute.

### Composite: variance correction

A weighted average of *correlated* z-scores has a smaller spread than the individual z-scores do — averaging pulls everything toward the middle. Left uncorrected, nearly every day lands in a narrow band and the top of the 0–100 range is unreachable.

So the composite z is divided by its own expected standard deviation:

```
sd = sqrt( Σwᵢ² + ρ·(1 − Σwᵢ²) )        ρ = 0.35 assumed inter-metric correlation
score = 70 + 15 · (compositeZ / sd)
```

**The centre is 70, not 50.** On a statistically average day you are in fact recovered enough to train normally, so an average day should read "Good", not a failing grade. With a spread of 15 points per corrected sigma, the bands land at roughly:

| Band | Score | Share of days |
|------|-------|---------------|
| **Ready** | 80–100 | ~25% |
| **Good** | 60–79 | ~50% |
| **Fair** | 40–59 | ~23% |
| **Poor** | 0–39 | ~2% |

That keeps "Poor — prioritize rest" rare enough to mean something when it appears.

All calibration constants live in `ReadinessEngine.Tuning`.

### Guardrails

Applied after the composite; they only ever lower the score.

- Capped at **55** if sleep < 4 hours.
- Capped at **60** if today's HRV is more than 30% below yesterday's.

### Training load

Acute (3-day) and chronic (28-day) average active energy, **both windows ending yesterday**. Today is excluded because it is a partial day: including it makes the acute average artificially low in the morning, which reads as under-training and *inflates* the score, then decays over the day for reasons unrelated to recovery.

Active energy is a loose proxy for training load — it can't distinguish a long walk from an interval session. This is a known limitation.

---

## States

Oriv shows exactly one of these:

| State | When | Action offered |
|-------|------|----------------|
| **Connect Apple Health** | Permission never requested | Presents the HealthKit sheet |
| **Can't See Your Health Data** | Asked, but zero samples returned | Deep link to Settings |
| **Health Data Unavailable** | Device has no HealthKit | — |
| **Building Your Baseline** | Fewer than 7 usable days | — |
| **No Recent Readings** | Freshest core sample older than 1 day | Deep link to Settings |
| **Score** | Everything above satisfied | — |

### On the permission state

HealthKit **never reports read-authorization status** — asking would leak whether a user is hiding a condition. `requestAuthorization` succeeds identically whether the user granted everything or denied everything.

Oriv therefore does not claim to be authorized just because the prompt completed. It tracks whether the sheet has been presented (`statusForAuthorizationRequest`) and whether any data actually came back, and shows *Can't See Your Health Data* when the answer is "asked, but nothing arrived". That state covers both possible causes — denied permission and a genuinely empty Health app — because the framework gives no way to tell them apart.

### On stale data

Readiness is a claim about *today*. If the freshest core reading is more than a day old, Oriv refuses to score rather than presenting an old day's number under today's date. Individual metrics older than the freshness window are dropped from the composite even when other metrics are current.

---

## File map

### Source (`Oriv/`)

| File | Purpose |
|------|---------|
| `OrivApp.swift` | `@main` entry point |
| `Theme.swift` | Semantic colour tokens (light + dark defined together) and card chrome |
| `HealthKitManager.swift` | Authorization state, observer queries, background delivery, 90-day fetching |
| `AppViewModel.swift` | Baseline statistics, freshness gating, training-load windows |
| `ReadinessEngine.swift` | Pure scoring — z-scores, variance correction, guardrails, bands |
| `ContentView.swift` | Dashboard host and state selection |
| `ReadinessHeroView.swift` | Score gauge, band badge, recommendation |
| `VitalsGridCardView.swift` | 2×2 vitals grid with sub-score bars |
| `StatusCardView.swift` | The no-score states and the Settings deep link |
| `Oriv.entitlements` | HealthKit + background delivery |

### Tests (`OrivTests/`)

| File | Purpose |
|------|---------|
| `ReadinessEngineTests.swift` | Scoring, bands, guardrails, staleness, calibration, numerical edges |
| `BaselineStatisticsTests.swift` | Baseline window, recency weighting, outlier trimming, training-load windows |
| `ThemeContrastTests.swift` | Resolves every colour token in both schemes and asserts WCAG contrast |
| `HealthKitManagerStressTests.swift` | Re-entrancy and cancellation of `fetchAllMetrics()` |

---

## Build & test

```bash
xcodebuild build -project Oriv.xcodeproj -scheme Oriv \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

```bash
xcodebuild test -project Oriv.xcodeproj -scheme Oriv \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:OrivTests
```

41 tests, 2 of them skipped by design (see below).

`HealthKitManagerStressTests` drives a real `HKHealthStore`. On a simulator that has never been asked for Health permission, those two tests **skip** rather than block on the system permission sheet — which would otherwise hang the whole run unattended.

---

## Privacy

| Key | Value |
|-----|-------|
| `NSHealthShareUsageDescription` | "Oriv reads your HRV, Resting HR, Sleep, and Active Energy to compute your daily readiness score." |

Read-only access. No data leaves the device, and there is no networking code in the project.

The entitlements request `com.apple.developer.healthkit` and `…healthkit.background-delivery` only. Oriv does **not** request `health-records` (clinical records) — it has no use for it, and requesting an entitlement you don't use invites App Store review questions you can't answer.

`NSHealthUpdateUsageDescription` is likewise absent: the app calls `requestAuthorization(toShare: [], …)` and never writes.

---

## Known limitations

- Active energy is a weak proxy for training load (see above).
- No history or trend view — the app shows today only.
- No widget or watch complication.
- No onboarding beyond the permission card.
- Swift 6 strict concurrency is not enabled.
