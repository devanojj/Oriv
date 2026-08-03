//
//  HealthKitManagerStressTests.swift
//  OrivTests
//

import XCTest
@testable import Oriv

final class HealthKitManagerStressTests: XCTestCase {

    /// Test 1: Verify whether calling fetchAllMetrics() inside onDataUpdated callback causes a re-entrancy deadlock.
    func testReentrancyDeadlockInFetchAllMetrics() async {
        let manager = await HealthKitManager()
        let expectation = expectation(description: "Fetch completed without deadlocking")
        
        await MainActor.run {
            manager.onDataUpdated = {
                // Re-entrant call to fetchAllMetrics while already inside fetchAllMetrics!
                await manager.fetchAllMetrics()
            }
        }
        
        let task = Task {
            await manager.fetchAllMetrics()
            expectation.fulfill()
        }
        
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertEqual(result, .completed, "FAIL: fetchAllMetrics deadlocked when onDataUpdated triggered fetchAllMetrics!")
        
        task.cancel()
    }

    /// Test 2: Verify whether cancelling a task calling fetchAllMetrics permanently locks out subsequent calls.
    func testTaskCancellationPermanentLockout() async {
        let manager = await HealthKitManager()
        
        // Launch a fetch task and cancel it immediately while running
        let fetchTask = Task {
            await manager.fetchAllMetrics()
        }
        fetchTask.cancel()
        _ = await fetchTask.result
        
        // Now call fetchAllMetrics again on a fresh task.
        let expectation = expectation(description: "Subsequent fetch completes")
        let secondTask = Task {
            await manager.fetchAllMetrics()
            expectation.fulfill()
        }
        
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 3.0)
        XCTAssertEqual(result, .completed, "FAIL: Subsequent fetchAllMetrics call was permanently locked out after task cancellation!")
        
        secondTask.cancel()
    }
}
