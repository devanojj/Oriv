//
//  HealthKitManagerStressTests.swift
//  OrivTests
//
//  Concurrency behaviour of HealthKitManager.fetchAllMetrics().
//
//  These exercise a real HKHealthStore. On a clean simulator, `fetchAllMetrics()`
//  reaches `requestAuthorization()` and presents the system permission sheet, which
//  nothing dismisses in an unattended run — the whole test bundle then hangs rather
//  than failing. Each test therefore skips unless permission has already been
//  requested on this device, which keeps the suite safe to run in CI while still
//  covering the behaviour anywhere access is already granted.
//

import XCTest
import HealthKit
@testable import Oriv

final class HealthKitManagerStressTests: XCTestCase {

    /// Skips the test if running it would raise the HealthKit permission sheet.
    private func skipIfAuthorizationSheetWouldAppear() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw XCTSkip("HealthKit is unavailable on this device.")
        }

        let store = HKHealthStore()
        let readTypes: Set<HKObjectType> = Set(
            [
                HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
                HKObjectType.quantityType(forIdentifier: .restingHeartRate),
                HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)
            ].compactMap { $0 as HKObjectType? }
        )

        let status = try await store.statusForAuthorizationRequest(toShare: [], read: readTypes)
        if status == .shouldRequest {
            throw XCTSkip("HealthKit permission has not been requested on this device; "
                          + "running would block on the system permission sheet.")
        }
    }

    /// Calling fetchAllMetrics() from inside the onDataUpdated callback must not deadlock.
    func testReentrancyDeadlockInFetchAllMetrics() async throws {
        try await skipIfAuthorizationSheetWouldAppear()

        let manager = await HealthKitManager()
        let expectation = expectation(description: "Fetch completed without deadlocking")

        await MainActor.run {
            manager.onDataUpdated = {
                // Re-entrant call while already inside fetchAllMetrics.
                await manager.fetchAllMetrics()
            }
        }

        let task = Task {
            await manager.fetchAllMetrics()
            expectation.fulfill()
        }

        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10.0)
        XCTAssertEqual(result, .completed,
                       "fetchAllMetrics deadlocked when onDataUpdated triggered fetchAllMetrics")

        task.cancel()
    }

    /// Cancelling a fetch must not permanently lock out subsequent fetches.
    func testTaskCancellationPermanentLockout() async throws {
        try await skipIfAuthorizationSheetWouldAppear()

        let manager = await HealthKitManager()

        let fetchTask = Task { await manager.fetchAllMetrics() }
        fetchTask.cancel()
        _ = await fetchTask.result

        let expectation = expectation(description: "Subsequent fetch completes")
        let secondTask = Task {
            await manager.fetchAllMetrics()
            expectation.fulfill()
        }

        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 10.0)
        XCTAssertEqual(result, .completed,
                       "fetchAllMetrics was locked out after a cancelled call")

        secondTask.cancel()
    }
}
