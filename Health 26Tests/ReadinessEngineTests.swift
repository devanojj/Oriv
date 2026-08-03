//
//  ReadinessEngineTests.swift
//  Health 26Tests
//

import XCTest
@testable import Health_26

final class ReadinessEngineTests: XCTestCase {

    // Test 1: Average day: all today's values equal baseline mean, loadRatio ≈ 1.0 -> score ≈ 50, band .fair.
    func testAverageDay() {
        let hrvInput = MetricInput(todayValue: 50.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30)
        let rhrInput = MetricInput(todayValue: 60.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)
        let sleepInput = MetricInput(todayValue: 7.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertFalse(result.insufficientData)
        XCTAssertNotNil(result.score)
        if let score = result.score {
            XCTAssertEqual(score, 50, accuracy: 2)
        }
        XCTAssertEqual(result.band, .fair)
    }

    // Test 2: Strong recovery: HRV +2σ, RHR -2σ, sleep +1.5σ, loadRatio ≈ 1.0 -> score 80+, band .ready.
    func testStrongRecovery() {
        let hrvInput = MetricInput(todayValue: 70.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30) // +2.0 stdDev
        let rhrInput = MetricInput(todayValue: 50.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)  // -2.0 stdDev (good)
        let sleepInput = MetricInput(todayValue: 9.0, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)  // +1.5 stdDev
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 68.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertFalse(result.insufficientData)
        XCTAssertNotNil(result.score)
        if let score = result.score {
            XCTAssertGreaterThanOrEqual(score, 80)
        }
        XCTAssertEqual(result.band, .ready)
    }

    // Test 3: Poor recovery: HRV -2σ, RHR +2σ, sleep -2σ -> score in the 20s–30s, band .poor.
    func testPoorRecovery() {
        let hrvInput = MetricInput(todayValue: 30.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30) // -2.0 stdDev
        let rhrInput = MetricInput(todayValue: 70.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)  // +2.0 stdDev (poor)
        let sleepInput = MetricInput(todayValue: 5.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)  // -2.0 stdDev
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 31.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertFalse(result.insufficientData)
        XCTAssertNotNil(result.score)
        if let score = result.score {
            XCTAssertGreaterThanOrEqual(score, 10)
            XCTAssertLessThanOrEqual(score, 39)
        }
        XCTAssertEqual(result.band, .poor)
    }

    // Test 4: Sleep guardrail: sleepHours.todayValue = 3.0 with excellent HRV/RHR -> final score capped at ≤55.
    func testSleepGuardrail() {
        let hrvInput = MetricInput(todayValue: 80.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30) // +3.0 stdDev
        let rhrInput = MetricInput(todayValue: 45.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)  // -3.0 stdDev
        let sleepInput = MetricInput(todayValue: 3.0, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)  // 3.0 hrs triggers guardrail (< 4.0)
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 80.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertNotNil(result.score)
        if let score = result.score {
            XCTAssertLessThanOrEqual(score, 55)
        }
    }

    // Test 5: Acute HRV-crash guardrail: today's HRV 40% below yesterday's -> final score capped at ≤60.
    func testAcuteHrvCrashGuardrail() {
        let hrvInput = MetricInput(todayValue: 50.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30)
        let rhrInput = MetricInput(todayValue: 50.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)
        let sleepInput = MetricInput(todayValue: 8.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 100.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertNotNil(result.score)
        if let score = result.score {
            XCTAssertLessThanOrEqual(score, 60)
        }
    }

    // Test 6: New user: HRV, RHR, and Sleep all have daysOfBaselineData < 7 -> insufficientData == true, score == nil.
    func testNewUserInsufficientData() {
        let hrvInput = MetricInput(todayValue: 50.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 3)
        let rhrInput = MetricInput(todayValue: 60.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 4)
        let sleepInput = MetricInput(todayValue: 7.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 2)
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: nil
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertTrue(result.insufficientData)
        XCTAssertNil(result.score)
        XCTAssertNil(result.band)
        XCTAssertTrue(result.breakdown.isEmpty)
        XCTAssertEqual(result.recommendation, "Still learning your baseline — check back in a few days")
    }

    // Test 7: Partial baseline: HRV and RHR have 15+ days of data, sleep only has 3 -> sleep excluded, weights redistribute; NOT insufficientData.
    func testPartialBaseline() {
        let hrvInput = MetricInput(todayValue: 50.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 20)
        let rhrInput = MetricInput(todayValue: 60.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 20)
        let sleepInput = MetricInput(todayValue: 7.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 3) // Excluded (< 7)
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertFalse(result.insufficientData)
        XCTAssertNotNil(result.score)
        XCTAssertEqual(result.score, 50)
        XCTAssertFalse(result.breakdown.contains(where: { $0.name == "Sleep" }))
    }

    // Test 8: Missing single-day value: sleep todayValue is nil -> gracefully excluded, no crash, weights redistribute.
    func testMissingSingleDayValue() {
        let hrvInput = MetricInput(todayValue: 50.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30)
        let rhrInput = MetricInput(todayValue: 60.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)
        let sleepInput = MetricInput(todayValue: nil, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30) // nil todayValue
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertFalse(result.insufficientData)
        XCTAssertNotNil(result.score)
        XCTAssertEqual(result.score, 50)
        XCTAssertFalse(result.breakdown.contains(where: { $0.name == "Sleep" }))
    }

    // Test 9: Training load spike: acuteLoad is 2x chronicLoad -> load subscore penalized, composite pulled down.
    func testTrainingLoadSpike() {
        let hrvInput = MetricInput(todayValue: 50.0, baselineMean: 50.0, baselineStdDev: 10.0, daysOfBaselineData: 30)
        let rhrInput = MetricInput(todayValue: 60.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)
        let sleepInput = MetricInput(todayValue: 7.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)
        
        let inputNormal = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )
        
        let inputSpike = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 1000.0, // 2x spike
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )
        
        let resultNormal = ReadinessEngine.calculate(from: inputNormal)
        let resultSpike = ReadinessEngine.calculate(from: inputSpike)
        
        XCTAssertNotNil(resultNormal.score)
        XCTAssertNotNil(resultSpike.score)
        if let scoreNormal = resultNormal.score, let scoreSpike = resultSpike.score {
            XCTAssertLessThan(scoreSpike, scoreNormal)
        }
        
        if let loadBreakdown = resultSpike.breakdown.first(where: { $0.name == "Training Load" }) {
            XCTAssertEqual(loadBreakdown.subscore, 20)
        } else {
            XCTFail("Training Load breakdown missing")
        }
    }

    // Test 10: Extreme input: baselineStdDev near zero producing very large z-score -> subscore clamps correctly 0-100, no crash.
    func testExtremeInputStdDevNearZero() {
        let hrvInput = MetricInput(todayValue: 100.0, baselineMean: 50.0, baselineStdDev: 0.00001, daysOfBaselineData: 30)
        let rhrInput = MetricInput(todayValue: 60.0, baselineMean: 60.0, baselineStdDev: 5.0, daysOfBaselineData: 30)
        let sleepInput = MetricInput(todayValue: 7.5, baselineMean: 7.5, baselineStdDev: 1.0, daysOfBaselineData: 30)
        
        let input = ReadinessInput(
            hrv: hrvInput,
            restingHeartRate: rhrInput,
            sleepHours: sleepInput,
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 100.0
        )
        
        let result = ReadinessEngine.calculate(from: input)
        
        XCTAssertFalse(result.insufficientData)
        XCTAssertNotNil(result.score)
        if let score = result.score {
            XCTAssertGreaterThanOrEqual(score, 0)
            XCTAssertLessThanOrEqual(score, 100)
        }
        if let hrvBreakdown = result.breakdown.first(where: { $0.name == "HRV" }) {
            XCTAssertEqual(hrvBreakdown.subscore, 100)
        }
    }

    // Test 11: Unrestricted 90-day sample lookup (e.g. 10 days ago / July 23)
    @MainActor
    func testUnrestrictedNinetyDayFallbackInAppViewModel() {
        let viewModel = AppViewModel()
        let calendar = Calendar.current
        let todayKey = calendar.startOfDay(for: Date())
        let tenDaysAgoKey = calendar.date(byAdding: .day, value: -10, to: todayKey)!
        
        // Data missing for today through 9 days ago, but present 10 days ago (July 23)
        let sampleData: [Date: Double] = [tenDaysAgoKey: 58.0]
        
        let result = viewModel.findMostRecentSample(in: sampleData, todayKey: todayKey, calendar: calendar)
        
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.value, 58.0)
        XCTAssertEqual(result?.daysAgo, 10)
    }
}
