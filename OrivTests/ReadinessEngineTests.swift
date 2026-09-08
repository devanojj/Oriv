//
//  ReadinessEngineTests.swift
//  OrivTests
//

import XCTest
@testable import Oriv

final class ReadinessEngineTests: XCTestCase {

    // MARK: - Helpers

    /// A metric with enough baseline history to be counted.
    private func metric(
        today: Double?,
        mean: Double?,
        stdDev: Double?,
        days: Int = 30
    ) -> MetricInput {
        MetricInput(todayValue: today, baselineMean: mean, baselineStdDev: stdDev, daysOfBaselineData: days)
    }

    // MARK: - Core scoring

    // Test 1: Average day. All metrics sit exactly on baseline, load ratio 1.0.
    //
    // Scores 70, not 50: the engine centres an average day at 70 because on a
    // statistically ordinary day you are in fact recovered enough to train normally.
    func testAverageDay() {
        let input = ReadinessInput(
            hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 60.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: 7.5, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertFalse(result.insufficientData)
        XCTAssertEqual(result.status, .scored)
        XCTAssertEqual(result.score, 70)
        XCTAssertEqual(result.band, .good)
    }

    // Test 2: Strong recovery: HRV +2σ, RHR -2σ, sleep +1.5σ -> band .ready.
    func testStrongRecovery() {
        let input = ReadinessInput(
            hrv: metric(today: 70.0, mean: 50.0, stdDev: 10.0),          // +2.0σ
            restingHeartRate: metric(today: 50.0, mean: 60.0, stdDev: 5.0),  // -2.0σ (good)
            sleepHours: metric(today: 9.0, mean: 7.5, stdDev: 1.0),      // +1.5σ
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 68.0
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertFalse(result.insufficientData)
        XCTAssertGreaterThanOrEqual(result.score ?? 0, 80)
        XCTAssertEqual(result.band, .ready)
    }

    // Test 3: Poor recovery: HRV -2σ, RHR +2σ, sleep -2σ -> band .poor.
    func testPoorRecovery() {
        let input = ReadinessInput(
            hrv: metric(today: 30.0, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 70.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: 5.5, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 31.0
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertFalse(result.insufficientData)
        XCTAssertLessThan(result.score ?? 100, 40)
        XCTAssertEqual(result.band, .poor)
    }

    // MARK: - Guardrails

    // Test 4: Sleep under 4h caps the score at 55 even with excellent HRV and RHR.
    func testSleepGuardrail() {
        let input = ReadinessInput(
            hrv: metric(today: 80.0, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 45.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: 3.0, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 80.0
        )

        let result = ReadinessEngine.calculate(from: input)
        XCTAssertLessThanOrEqual(result.score ?? 100, 55)
    }

    // Test 5: HRV more than 30% below yesterday caps the score at 60.
    func testAcuteHrvCrashGuardrail() {
        let input = ReadinessInput(
            hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 50.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: 8.5, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 100.0
        )

        let result = ReadinessEngine.calculate(from: input)
        XCTAssertLessThanOrEqual(result.score ?? 100, 60)
    }

    // MARK: - Data sufficiency

    // Test 6: Every core metric below the 7-day baseline minimum -> no score.
    func testNewUserInsufficientData() {
        let input = ReadinessInput(
            hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0, days: 3),
            restingHeartRate: metric(today: 60.0, mean: 60.0, stdDev: 5.0, days: 4),
            sleepHours: metric(today: 7.5, mean: 7.5, stdDev: 1.0, days: 2),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: nil
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertTrue(result.insufficientData)
        XCTAssertEqual(result.status, .insufficientBaseline)
        XCTAssertNil(result.score)
        XCTAssertNil(result.band)
        XCTAssertTrue(result.breakdown.isEmpty)
        XCTAssertEqual(result.recommendation, "Still learning your baseline — check back in a few days")
    }

    // Test 6b: Exactly 7 days of baseline is enough; 6 is not.
    func testBaselineMinimumBoundary() {
        func scoreWithBaselineDays(_ days: Int) -> ReadinessResult {
            ReadinessEngine.calculate(from: ReadinessInput(
                hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0, days: days),
                restingHeartRate: metric(today: nil, mean: nil, stdDev: nil, days: 0),
                sleepHours: metric(today: nil, mean: nil, stdDev: nil, days: 0),
                acuteLoad: nil,
                chronicLoad: nil,
                yesterdayHRV: nil
            ))
        }

        XCTAssertTrue(scoreWithBaselineDays(6).insufficientData)
        XCTAssertFalse(scoreWithBaselineDays(7).insufficientData)
    }

    // Test 7: A metric short on history is excluded and the remaining weights redistribute.
    func testPartialBaseline() {
        let input = ReadinessInput(
            hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0, days: 20),
            restingHeartRate: metric(today: 60.0, mean: 60.0, stdDev: 5.0, days: 20),
            sleepHours: metric(today: 7.5, mean: 7.5, stdDev: 1.0, days: 3),  // excluded (< 7)
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertFalse(result.insufficientData)
        XCTAssertEqual(result.score, 70)
        XCTAssertFalse(result.breakdown.contains { $0.name == "Sleep" })
    }

    // Test 8: A missing single-day value is excluded gracefully.
    func testMissingSingleDayValue() {
        let input = ReadinessInput(
            hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 60.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: nil, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 50.0
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertFalse(result.insufficientData)
        XCTAssertEqual(result.score, 70)
        XCTAssertFalse(result.breakdown.contains { $0.name == "Sleep" })
    }

    // MARK: - Training load

    // Test 9: A 2x acute load spike lowers the composite.
    func testTrainingLoadSpike() {
        let hrv = metric(today: 50.0, mean: 50.0, stdDev: 10.0)
        let rhr = metric(today: 60.0, mean: 60.0, stdDev: 5.0)
        let sleep = metric(today: 7.5, mean: 7.5, stdDev: 1.0)

        let normal = ReadinessEngine.calculate(from: ReadinessInput(
            hrv: hrv, restingHeartRate: rhr, sleepHours: sleep,
            acuteLoad: 500.0, chronicLoad: 500.0, yesterdayHRV: 50.0
        ))

        let spike = ReadinessEngine.calculate(from: ReadinessInput(
            hrv: hrv, restingHeartRate: rhr, sleepHours: sleep,
            acuteLoad: 1000.0, chronicLoad: 500.0, yesterdayHRV: 50.0
        ))

        XCTAssertLessThan(spike.score ?? 100, normal.score ?? 0)
        XCTAssertEqual(spike.breakdown.first { $0.name == "Training Load" }?.subscore, 20)
    }

    // MARK: - Numerical edge cases

    // Test 10: A near-zero standard deviation produces a huge z, which must clamp cleanly.
    func testExtremeInputStdDevNearZero() {
        let input = ReadinessInput(
            hrv: metric(today: 100.0, mean: 50.0, stdDev: 0.00001),
            restingHeartRate: metric(today: 60.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: 7.5, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 100.0
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertFalse(result.insufficientData)
        guard let score = result.score else {
            return XCTFail("Expected a score")
        }
        XCTAssertGreaterThanOrEqual(score, 0)
        XCTAssertLessThanOrEqual(score, 100)
        XCTAssertEqual(result.breakdown.first { $0.name == "HRV" }?.subscore, 100)
    }

    // Test 10b: Non-finite inputs never produce a score or a crash.
    func testNonFiniteInputsAreRejected() {
        let input = ReadinessInput(
            hrv: metric(today: Double.nan, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 60.0, mean: Double.infinity, stdDev: 5.0),
            sleepHours: metric(today: 7.5, mean: 7.5, stdDev: Double.nan),
            acuteLoad: nil,
            chronicLoad: nil,
            yesterdayHRV: nil
        )

        let result = ReadinessEngine.calculate(from: input)
        XCTAssertTrue(result.insufficientData)
        XCTAssertNil(result.score)
    }

    // MARK: - Staleness

    // Data older than the freshness window must not be scored as if it were today.
    func testStaleDataIsNotScored() {
        let input = ReadinessInput(
            hrv: metric(today: 70.0, mean: 50.0, stdDev: 10.0),
            restingHeartRate: metric(today: 50.0, mean: 60.0, stdDev: 5.0),
            sleepHours: metric(today: 9.0, mean: 7.5, stdDev: 1.0),
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: nil,
            dataAgeInDays: 12
        )

        let result = ReadinessEngine.calculate(from: input)

        XCTAssertEqual(result.status, .staleData(daysAgo: 12))
        XCTAssertNil(result.score)
        XCTAssertNil(result.band)
        XCTAssertTrue(result.insufficientData)
    }

    // Today (0) and yesterday (1) are both fresh enough; two days is not.
    func testFreshnessBoundary() {
        func status(ageInDays: Int) -> ReadinessStatus {
            ReadinessEngine.calculate(from: ReadinessInput(
                hrv: metric(today: 50.0, mean: 50.0, stdDev: 10.0),
                restingHeartRate: metric(today: 60.0, mean: 60.0, stdDev: 5.0),
                sleepHours: metric(today: 7.5, mean: 7.5, stdDev: 1.0),
                acuteLoad: 500.0,
                chronicLoad: 500.0,
                yesterdayHRV: nil,
                dataAgeInDays: ageInDays
            )).status
        }

        XCTAssertEqual(status(ageInDays: 0), .scored)
        XCTAssertEqual(status(ageInDays: 1), .scored)
        XCTAssertEqual(status(ageInDays: 2), .staleData(daysAgo: 2))
    }

    // MARK: - Composite calibration

    // The whole point of the variance correction: a composite "+1 sigma day" must land
    // one spread-unit above centre, not be flattened toward the middle by averaging.
    func testVarianceCorrectionExpandsTheComposite() {
        let weights = [0.35, 0.25, 0.25, 0.15]
        let factor = ReadinessEngine.compressionFactor(weights: weights)

        // Averaging correlated metrics shrinks the spread, so the factor is below 1...
        XCTAssertLessThan(factor, 1.0)
        // ...but not so far that the correction becomes an amplifier.
        XCTAssertGreaterThan(factor, 0.5)

        // A single metric involves no averaging, so there is nothing to correct.
        XCTAssertEqual(ReadinessEngine.compressionFactor(weights: [1.0]), 1.0, accuracy: 1e-9)
    }

    // A uniformly +1σ day should reach the Ready band. Under the old uncorrected
    // averaging it landed at 70 — permanently short of it.
    func testUniformOneSigmaDayReachesReady() {
        let input = ReadinessInput(
            hrv: metric(today: 60.0, mean: 50.0, stdDev: 10.0),          // +1σ
            restingHeartRate: metric(today: 55.0, mean: 60.0, stdDev: 5.0),  // +1σ (inverted)
            sleepHours: metric(today: 8.5, mean: 7.5, stdDev: 1.0),      // +1σ
            acuteLoad: 500.0,
            chronicLoad: 500.0,
            yesterdayHRV: 58.0
        )

        let result = ReadinessEngine.calculate(from: input)
        XCTAssertEqual(result.band, .ready)
        XCTAssertGreaterThanOrEqual(result.score ?? 0, 80)
    }

    // Bands must tile 0...100 with no gaps.
    func testBandsCoverFullRange() {
        var seen = Set<ReadinessBand>()
        for score in 0...100 {
            let result = ReadinessEngine.calculate(from: ReadinessInput(
                hrv: metric(today: Double(score), mean: 50.0, stdDev: 10.0),
                restingHeartRate: metric(today: nil, mean: nil, stdDev: nil, days: 0),
                sleepHours: metric(today: nil, mean: nil, stdDev: nil, days: 0),
                acuteLoad: nil,
                chronicLoad: nil,
                yesterdayHRV: nil
            ))
            if let band = result.band { seen.insert(band) }
            XCTAssertNotNil(result.score)
        }
        XCTAssertEqual(seen.count, ReadinessBand.allCases.count)
    }
}
