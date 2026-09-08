//
//  BaselineStatisticsTests.swift
//  OrivTests
//
//  Covers the baseline construction and training-load windowing in AppViewModel.
//

import XCTest
@testable import Oriv

@MainActor
final class BaselineStatisticsTests: XCTestCase {

    private let calendar = Calendar.current

    private var today: Date {
        calendar.startOfDay(for: Date())
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: today)!
    }

    /// Builds `[Date: Double]` from day-offsets: `[1: 50.0]` means "yesterday was 50".
    private func series(_ pairs: [Int: Double]) -> [Date: Double] {
        var out: [Date: Double] = [:]
        for (offset, value) in pairs { out[day(offset)] = value }
        return out
    }

    // MARK: - Self-inclusion

    // The day being scored must never contribute to the baseline it is measured against.
    // Including it drags the mean toward the observation and pins the z-score near zero.
    func testScoredDayIsExcludedFromItsOwnBaseline() {
        var data: [Int: Double] = [0: 999.0]   // today: a wild outlier
        for offset in 1...20 { data[offset] = 50.0 }

        let baseline = AppViewModel.computeBaseline(
            from: series(data),
            before: today,
            calendar: calendar
        )

        XCTAssertEqual(baseline.count, 20)
        XCTAssertEqual(baseline.mean ?? 0, 50.0, accuracy: 0.001,
                       "Today's 999 must not appear in today's own baseline")
    }

    // Previously, a metric with no prior days fell back to averaging *all* values,
    // including the one being scored — guaranteeing a z-score of 0.
    func testNoPriorHistoryYieldsNoBaselineRatherThanSelfComparison() {
        let baseline = AppViewModel.computeBaseline(
            from: series([0: 55.0]),
            before: today,
            calendar: calendar
        )

        XCTAssertEqual(baseline.count, 0)
        XCTAssertNil(baseline.mean)
        XCTAssertNil(baseline.stdDev)
    }

    // MARK: - Minimum history

    func testFewerThanSevenDaysProducesNoUsableBaseline() {
        var data: [Int: Double] = [:]
        for offset in 1...6 { data[offset] = 50.0 }

        let baseline = AppViewModel.computeBaseline(from: series(data), before: today, calendar: calendar)

        XCTAssertEqual(baseline.count, 6)
        XCTAssertNil(baseline.mean, "6 days is below the 7-day minimum")
    }

    func testSevenDaysProducesAUsableBaseline() {
        let values: [Double] = [48, 52, 49, 53, 47, 51, 50]
        var data: [Int: Double] = [:]
        for (index, value) in values.enumerated() { data[index + 1] = value }

        let baseline = AppViewModel.computeBaseline(from: series(data), before: today, calendar: calendar)

        XCTAssertEqual(baseline.count, 7)
        XCTAssertNotNil(baseline.mean)
        XCTAssertNotNil(baseline.stdDev)
        XCTAssertGreaterThan(baseline.stdDev ?? 0, 0)
    }

    // MARK: - Rolling window

    // Data beyond the rolling window must not anchor the baseline forever.
    func testDataOlderThanTheWindowIsIgnored() {
        var data: [Int: Double] = [:]
        for offset in 1...10 { data[offset] = 50.0 }              // recent: ~50
        for offset in 61...80 { data[offset] = 200.0 }            // ancient: outside the window

        let baseline = AppViewModel.computeBaseline(from: series(data), before: today, calendar: calendar)

        XCTAssertEqual(baseline.count, 10)
        XCTAssertEqual(baseline.mean ?? 0, 50.0, accuracy: 0.001)
    }

    // MARK: - Recency weighting

    // A recent shift in the metric should move the baseline faster than an unweighted
    // mean would, so the score tracks who you are now.
    func testRecentValuesDominateTheBaseline() {
        var data: [Int: Double] = [:]
        for offset in 1...10 { data[offset] = 70.0 }     // last 10 days: 70
        for offset in 11...40 { data[offset] = 40.0 }    // the month before: 40

        let baseline = AppViewModel.computeBaseline(from: series(data), before: today, calendar: calendar)

        let unweightedMean = (70.0 * 10 + 40.0 * 30) / 40.0   // 47.5
        let mean = baseline.mean ?? 0

        // With a 14-day half-life this lands near 53.6 — meaningfully pulled toward the
        // recent 70s, without discarding the older history entirely.
        XCTAssertGreaterThan(mean, unweightedMean + 5.0,
                             "Recency weighting should pull the baseline toward the recent 70s")
        XCTAssertLessThan(mean, 70.0, "Older history should still carry some weight")
    }

    // MARK: - Outlier trimming

    func testSingleWildOutlierIsTrimmed() {
        let normal: [Double] = [48, 50, 52, 49, 51, 50, 53, 47, 50, 49]
        var data: [Int: Double] = [:]
        for (index, value) in normal.enumerated() { data[index + 1] = value }
        data[11] = 500.0   // a slipped watch strap

        let baseline = AppViewModel.computeBaseline(from: series(data), before: today, calendar: calendar)

        XCTAssertEqual(baseline.count, normal.count, "The 500 should have been trimmed")
        XCTAssertEqual(baseline.mean ?? 0, 50.0, accuracy: 3.0)
        XCTAssertLessThan(baseline.stdDev ?? 999, 10.0,
                          "One outlier must not permanently inflate the standard deviation")
    }

    func testOrdinaryVariationIsNotTrimmed() {
        let values: [Double] = [44, 48, 50, 52, 56, 47, 53, 49, 51, 45]
        var data: [Int: Double] = [:]
        for (index, value) in values.enumerated() { data[index + 1] = value }

        let baseline = AppViewModel.computeBaseline(from: series(data), before: today, calendar: calendar)

        XCTAssertEqual(baseline.count, values.count, "Normal spread must be preserved")
    }

    // MARK: - Training load

    // Today is a partial day. Including it makes the acute average dip in the morning,
    // which reads as under-training and inflates the score.
    func testTrainingLoadExcludesToday() {
        var data: [Int: Double] = [0: 5.0]                  // today so far: barely moved
        for offset in 1...28 { data[offset] = 500.0 }

        let (acute, chronic) = AppViewModel.computeTrainingLoad(
            from: series(data),
            todayKey: today,
            calendar: calendar
        )

        XCTAssertEqual(acute ?? 0, 500.0, accuracy: 0.001, "Today's partial 5 kcal must be excluded")
        XCTAssertEqual(chronic ?? 0, 500.0, accuracy: 0.001)
    }

    func testTrainingLoadDetectsAnAcuteSpike() {
        var data: [Int: Double] = [:]
        for offset in 1...3 { data[offset] = 1000.0 }
        for offset in 4...28 { data[offset] = 400.0 }

        let (acute, chronic) = AppViewModel.computeTrainingLoad(
            from: series(data),
            todayKey: today,
            calendar: calendar
        )

        XCTAssertEqual(acute ?? 0, 1000.0, accuracy: 0.001)
        XCTAssertGreaterThan((acute ?? 0) / (chronic ?? 1), 1.5)
    }

    func testTrainingLoadWithNoEnergyData() {
        let (acute, chronic) = AppViewModel.computeTrainingLoad(
            from: [:],
            todayKey: today,
            calendar: calendar
        )

        XCTAssertNil(acute)
        XCTAssertNil(chronic)
    }

    // MARK: - Sample lookup

    // The lookup helper itself stays unbounded; the freshness policy lives above it.
    func testFindMostRecentSampleReportsAge() {
        let data = series([10: 58.0])

        let result = AppViewModel.findMostRecentSample(in: data, todayKey: today, calendar: calendar)

        XCTAssertEqual(result?.value, 58.0)
        XCTAssertEqual(result?.daysAgo, 10)
    }

    func testFindMostRecentSampleIgnoresFutureDates() {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let data: [Date: Double] = [tomorrow: 99.0, day(2): 55.0]

        let result = AppViewModel.findMostRecentSample(in: data, todayKey: today, calendar: calendar)

        XCTAssertEqual(result?.value, 55.0)
        XCTAssertEqual(result?.daysAgo, 2)
    }

    func testFindMostRecentSampleOnEmptyData() {
        XCTAssertNil(AppViewModel.findMostRecentSample(in: [:], todayKey: today, calendar: calendar))
    }
}
