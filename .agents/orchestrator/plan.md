# Orchestration Plan: Oriv Health App Update

## Objective
Implement R1 (HealthKit Background Observer & Delivery), R2 (AppViewModel Reactive Synchronization), and R3 (SwiftUI Reactive View Architecture) in Oriv codebase and verify using xcodebuild.

## Phases
1. **Phase 0: Survey & Mapping**
   - Spawn 3 parallel `teamwork_preview_explorer` agents to survey existing codebase and read `ORIGINAL_REQUEST.md`.
   - Synthesize findings into `PROJECT.md`.

2. **Phase 1: Decomposition & Interface Contracts**
   - Define milestones for R1, R2, R3, and test suite.
   - Establish interface contracts and file boundaries.

3. **Phase 2: Execution Loop (Explorer -> Worker -> Reviewer -> Challenger -> Auditor -> Gate)**
   - Execute implementation for R1, R2, R3.
   - Run verification via workers running `xcodebuild build` and `xcodebuild test`.

4. **Phase 3: Verification & Reporting**
   - Final audit and test pass.
   - Send completion message to parent (Sentinel).
