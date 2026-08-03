# Handoff Report: AppViewModel & R2 Requirements Survey

## 1. Observation
- **`AppViewModel.swift` (`Health 26/AppViewModel.swift`)**:
  - Class annotated with `@Observable` and `@MainActor` (lines 24-25).
  - Holds `calculatedResult: ReadinessResult?`, `metricRecencies: [MetricRecency]`, and `recencyNote: String?`.
  - Exposes `loadAndCalculateReadiness() async` (lines 43-46) and `processHealthData()` (lines 49-137).
- **`HealthKitManager.swift` (`Health 26/HealthKitManager.swift`)**:
  - Class annotated with `@Observable` and `@MainActor` (lines 38-39).
  - Implements `fetch90DayHealthData() async` executing 4 concurrent queries (`async let`) for HRV, Resting HR, Sleep Analysis, and Active Energy.
  - **Currently lacks background observer queries** (`HKObserverQuery`) and `enableBackgroundDelivery`.
- **`ContentView.swift` (`Health 26/ContentView.swift`)**:
  - Contains explicit "Refresh Health Data" button at lines 125-142.
  - Contains `.task` modifier (lines 150-154) and `.refreshable` (lines 147-149).
  - Lacks `.onChange(of: scenePhase)` transition listener.
- **Unit Tests (`Health 26Tests/ReadinessEngineTests.swift`)**:
  - 11 unit tests testing calculation logic, guardrails, fallback behavior, and weight renormalization.
  - Test execution result: 9 tests passed, 2 failed (`testNewUserInsufficientData`, `testPartialBaseline`).
  - Discrepancy observed: `ReadinessEngine.swift:218` checks `daysOfBaselineData >= 1` instead of `daysOfBaselineData >= 7` expected by unit tests.

## 2. Logic Chain
1. Requirement R2 mandates refactoring `AppViewModel` to subscribe to HealthKit background observer updates and automatically recalculate readiness when new biometrics arrive, strictly conforming to Swift 6 actor isolation.
2. `HealthKitManager` must instantiate 4 `HKObserverQuery` observers and call `enableBackgroundDelivery(for:frequency: .immediate)` for HRV, Resting HR, Sleep, and Active Energy.
3. HealthKit background observer query callbacks run on arbitrary non-isolated background threads. Direct mutation or non-isolated calling of `@MainActor` state in `HealthKitManager` or `AppViewModel` would violate Swift 6 actor isolation.
4. Wrapping observer update processing in `Task { @MainActor in defer { completionHandler() }; await fetch90DayHealthData(); await onDataUpdated?() }` guarantees thread-safety, proper MainActor hopping, and correct iOS background completion timing.
5. `AppViewModel` binding to `HealthKitManager.onDataUpdated` ensures immediate invocation of `processHealthData()` on `@MainActor`, updating `@Observable` properties (`calculatedResult`, `metricRecencies`, `recencyNote`) and triggering automatic SwiftUI view re-renders.
6. Aligning `isMetricValid` in `ReadinessEngine.swift` from `>= 1` to `>= 7` days of baseline data will fix the 2 failing unit tests, achieving 100% test pass rate (11/11).

## 3. Caveats
- `HKObserverQuery` background delivery requires real HealthKit authorization and device/simulator support with proper entitlements (`Health 26.entitlements`).
- On iOS Simulator, background observer delivery may be throttled or simulated via Xcode HealthKit background event triggers.
- No code modifications were performed in the app source code during this phase, as this is a read-only investigation.

## 4. Conclusion
The current `AppViewModel` and `HealthKitManager` architecture is well-structured with modern `@Observable` and `@MainActor` annotations. Adding background reactive sync requires:
1. Adding background delivery and `HKObserverQuery` handlers to `HealthKitManager.swift`.
2. Exposing an `@MainActor` callback `onDataUpdated` on `HealthKitManager` connected to `AppViewModel.processHealthData()`.
3. Removing the manual refresh button in `ContentView.swift` and adding `.onChange(of: scenePhase)` for active foreground sync.
4. Adjusting `ReadinessEngine.isMetricValid` baseline check from `>= 1` to `>= 7` so all 11 unit tests pass.

## 5. Verification Method
- **Build Verification**:
  ```bash
  xcodebuild build -project "Health 26.xcodeproj" -scheme "Health 26" -destination 'platform=iOS Simulator,name=iPhone 17'
  ```
- **Test Verification**:
  ```bash
  xcodebuild test -project "Health 26.xcodeproj" -scheme "Health 26" -destination 'platform=iOS Simulator,name=iPhone 17'
  ```
- **File Inspection**:
  - Check `analysis.md` at `/Users/devano/Documents/Projects/Health App/Oriv/.agents/teamwork_preview_explorer_survey_2/analysis.md`.
