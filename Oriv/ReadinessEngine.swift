//
//  ReadinessEngine.swift
//  Oriv
//
//  Pure, stateless scoring. No HealthKit, no dates, no I/O — everything it needs
//  arrives in `ReadinessInput`, which is what makes it unit-testable.
//

import Foundation

public struct MetricInput: Sendable {
    public let todayValue: Double?
    public let baselineMean: Double?
    public let baselineStdDev: Double?
    public let daysOfBaselineData: Int

    public init(todayValue: Double?, baselineMean: Double?, baselineStdDev: Double?, daysOfBaselineData: Int) {
        self.todayValue = todayValue
        self.baselineMean = baselineMean
        self.baselineStdDev = baselineStdDev
        self.daysOfBaselineData = daysOfBaselineData
    }
}

public struct ReadinessInput: Sendable {
    public let hrv: MetricInput              // ms (SDNN)
    public let restingHeartRate: MetricInput // bpm
    public let sleepHours: MetricInput       // hours
    public let acuteLoad: Double?            // trailing 3-day avg active energy, excluding today (kcal)
    public let chronicLoad: Double?          // trailing 28-day avg active energy, excluding today (kcal)
    public let yesterdayHRV: Double?         // ms, for acute-drop guardrail

    /// Age in days of the freshest *core* sample (HRV / RHR / sleep) backing this input.
    /// 0 = collected today, 1 = yesterday, nil = no core data at all.
    ///
    /// Readiness is a statement about today. If the newest reading is older than
    /// `Tuning.maxDataAgeDays`, the engine refuses to score rather than presenting a
    /// stale day's number under today's date.
    public let dataAgeInDays: Int?

    public init(
        hrv: MetricInput,
        restingHeartRate: MetricInput,
        sleepHours: MetricInput,
        acuteLoad: Double?,
        chronicLoad: Double?,
        yesterdayHRV: Double?,
        dataAgeInDays: Int? = nil
    ) {
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.acuteLoad = acuteLoad
        self.chronicLoad = chronicLoad
        self.yesterdayHRV = yesterdayHRV
        self.dataAgeInDays = dataAgeInDays
    }
}

public enum ReadinessBand: String, Sendable, CaseIterable {
    case ready = "Ready"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
}

/// Why the engine did or didn't produce a score.
public enum ReadinessStatus: Sendable, Equatable {
    /// A score was produced.
    case scored
    /// Not enough baseline history yet to say what "normal" looks like for this user.
    case insufficientBaseline
    /// Baseline exists, but the freshest reading is too old to describe today.
    case staleData(daysAgo: Int)
}

public struct MetricBreakdown: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let subscore: Int    // 0-100
    public let status: String   // e.g., "12% above average"

    public init(id: UUID = UUID(), name: String, subscore: Int, status: String) {
        self.id = id
        self.name = name
        self.subscore = subscore
        self.status = status
    }
}

public struct ReadinessResult: Sendable, Equatable {
    public let score: Int?
    public let band: ReadinessBand?
    public let breakdown: [MetricBreakdown]
    public let recommendation: String
    public let status: ReadinessStatus

    /// True whenever no score could be produced, for any reason.
    public var insufficientData: Bool {
        status != .scored
    }

    public init(
        score: Int?,
        band: ReadinessBand?,
        breakdown: [MetricBreakdown],
        recommendation: String,
        status: ReadinessStatus
    ) {
        self.score = score
        self.band = band
        self.breakdown = breakdown
        self.recommendation = recommendation
        self.status = status
    }
}

public enum ReadinessEngine {

    /// Every calibration constant in one place, so the scoring behaviour can be
    /// reasoned about and adjusted without hunting through the logic.
    public enum Tuning {
        // Base weights (renormalised when a metric is unavailable).
        public static let hrvWeight: Double = 0.35
        public static let rhrWeight: Double = 0.25
        public static let sleepWeight: Double = 0.25
        public static let loadWeight: Double = 0.15

        /// Minimum prior days required before a metric is allowed to contribute.
        /// A standard deviation from 2 or 3 points is noise, not a baseline.
        public static let minBaselineDays: Int = 7

        /// Individual z-scores are clamped to this before they reach the composite, so
        /// one freak reading (or a near-zero standard deviation) can't dominate.
        public static let maxAbsZ: Double = 3.0

        /// Assumed average pairwise correlation between the metrics. Used to undo the
        /// variance shrinkage that weighted-averaging causes. See `compressionFactor`.
        public static let interMetricCorrelation: Double = 0.35

        /// Score for a statistically average day, and points per corrected sigma.
        ///
        /// Centred at 70 rather than 50 deliberately: on an average day you *are*
        /// recovered enough to train normally, so an average day should read "Good",
        /// not a failing grade. With a spread of 15 the bands below land at roughly
        /// Ready 25% / Good 50% / Fair 23% / Poor 2% of days — which keeps "Poor"
        /// rare enough to mean something when it appears.
        public static let centre: Double = 70.0
        public static let spreadPerSigma: Double = 15.0

        /// Per-metric display subscores keep the simpler 50 ± 20σ scale.
        public static let subscoreCentre: Double = 50.0
        public static let subscoreSpreadPerSigma: Double = 20.0

        /// Maximum age, in days, of the freshest core sample for a score to still
        /// describe "today". 1 = today or yesterday is acceptable.
        public static let maxDataAgeDays: Int = 1

        // Guardrails.
        public static let minSleepHours: Double = 4.0
        public static let sleepGuardrailCap: Int = 55
        public static let hrvCrashRatio: Double = 0.70
        public static let hrvCrashCap: Int = 60
    }

    public static func calculate(from input: ReadinessInput) -> ReadinessResult {
        // 1. Staleness gate. Checked first because it is the most specific and most
        //    actionable thing we can say: the problem isn't the maths, it's that we
        //    haven't seen a reading in a while.
        if let age = input.dataAgeInDays, age > Tuning.maxDataAgeDays {
            return ReadinessResult(
                score: nil,
                band: nil,
                breakdown: [],
                recommendation: "No recent readings. Wear your watch overnight and Oriv will pick back up.",
                status: .staleData(daysAgo: age)
            )
        }

        // 2. Baseline sufficiency across the three core metrics.
        let isHrvValid = isMetricValid(input.hrv)
        let isRhrValid = isMetricValid(input.restingHeartRate)
        let isSleepValid = isMetricValid(input.sleepHours)

        if !isHrvValid && !isRhrValid && !isSleepValid {
            return insufficientBaselineResult()
        }

        // 3. Per-metric z-scores.
        var contributions: [(z: Double, weight: Double)] = []
        var breakdowns: [MetricBreakdown] = []

        if isHrvValid,
           let today = input.hrv.todayValue,
           let mean = input.hrv.baselineMean,
           let stdDev = input.hrv.baselineStdDev {
            let z = clampZ((today - mean) / stdDev)
            contributions.append((z, Tuning.hrvWeight))

            let pctDiff = mean != 0 ? ((today - mean) / mean) * 100.0 : 0.0
            breakdowns.append(MetricBreakdown(
                name: "HRV",
                subscore: subscore(forZ: z),
                status: String(format: "%.1f ms (%@%.0f%% vs avg)", today, pctDiff >= 0 ? "+" : "", pctDiff)
            ))
        }

        // Resting heart rate is inverted: lower than baseline is better.
        if isRhrValid,
           let today = input.restingHeartRate.todayValue,
           let mean = input.restingHeartRate.baselineMean,
           let stdDev = input.restingHeartRate.baselineStdDev {
            let z = clampZ((mean - today) / stdDev)
            contributions.append((z, Tuning.rhrWeight))

            let diff = today - mean
            breakdowns.append(MetricBreakdown(
                name: "Resting HR",
                subscore: subscore(forZ: z),
                status: String(format: "%.0f bpm (%@%.1f bpm vs avg)", today, diff >= 0 ? "+" : "", diff)
            ))
        }

        if isSleepValid,
           let today = input.sleepHours.todayValue,
           let mean = input.sleepHours.baselineMean,
           let stdDev = input.sleepHours.baselineStdDev {
            let z = clampZ((today - mean) / stdDev)
            contributions.append((z, Tuning.sleepWeight))

            let diff = today - mean
            breakdowns.append(MetricBreakdown(
                name: "Sleep",
                subscore: subscore(forZ: z),
                status: String(format: "%.1f hrs (%@%.1fh vs avg)", today, diff >= 0 ? "+" : "", diff)
            ))
        }

        // Training load: ACWR, where a ratio near 1.0 is neutral and a spike is penalised.
        if let acute = input.acuteLoad,
           let chronic = input.chronicLoad,
           chronic > 0 {
            let loadRatio = acute / chronic
            let z = clamp((1.0 - loadRatio) * 3.0, min: -1.5, max: 1.0)
            contributions.append((z, Tuning.loadWeight))

            breakdowns.append(MetricBreakdown(
                name: "Training Load",
                subscore: subscore(forZ: z),
                status: String(format: "Ratio: %.2fx (%.0f / %.0f kcal)", loadRatio, acute, chronic)
            ))
        }

        guard !contributions.isEmpty else {
            return insufficientBaselineResult()
        }

        // 4. Variance-corrected composite.
        //
        //    A weighted average of correlated z-scores has a smaller spread than the
        //    individual z-scores do — averaging pulls everything toward the middle. Left
        //    uncorrected this parks nearly every day in a narrow band around the centre
        //    and makes the top of the 0-100 range unreachable. Dividing by the composite's
        //    own expected standard deviation restores unit variance, so a "+1 sigma day"
        //    on the composite means the same thing as a +1 sigma day on a single metric.
        let totalWeight = contributions.reduce(0.0) { $0 + $1.weight }
        let normalised = contributions.map { (z: $0.z, w: $0.weight / totalWeight) }

        let compositeZ = normalised.reduce(0.0) { $0 + $1.z * $1.w }
        let correctedZ = compositeZ / compressionFactor(weights: normalised.map(\.w))

        var compositeScore = Int(round(Tuning.centre + correctedZ * Tuning.spreadPerSigma))

        // 5. Guardrails. These only ever lower the score.
        if let sleepToday = input.sleepHours.todayValue, sleepToday < Tuning.minSleepHours {
            compositeScore = min(compositeScore, Tuning.sleepGuardrailCap)
        }

        if let todayHRV = input.hrv.todayValue,
           let yesterdayHRV = input.yesterdayHRV,
           yesterdayHRV > 0,
           todayHRV < (yesterdayHRV * Tuning.hrvCrashRatio) {
            compositeScore = min(compositeScore, Tuning.hrvCrashCap)
        }

        let finalScore = clamp(compositeScore, min: 0, max: 100)
        let band = band(for: finalScore)

        return ReadinessResult(
            score: finalScore,
            band: band,
            breakdown: breakdowns,
            recommendation: recommendation(for: band),
            status: .scored
        )
    }

    // MARK: - Composite maths

    /// Expected standard deviation of a weighted average of unit-variance variables with
    /// an assumed uniform pairwise correlation `rho`.
    ///
    ///   sd = sqrt( Σwᵢ² + 2ρ·Σ_{i<j} wᵢwⱼ )
    ///
    /// and since the weights sum to 1, Σ_{i<j} wᵢwⱼ = (1 − Σwᵢ²) / 2, giving the
    /// closed form below. Returns 1.0 for a single metric (no averaging, no shrinkage).
    static func compressionFactor(weights: [Double]) -> Double {
        guard weights.count > 1 else { return 1.0 }
        let sumOfSquares = weights.reduce(0.0) { $0 + $1 * $1 }
        let rho = Tuning.interMetricCorrelation
        let variance = sumOfSquares + rho * (1.0 - sumOfSquares)
        return max(sqrt(variance), 0.2)  // floor guards against a degenerate weight set
    }

    // MARK: - Helpers

    private static func insufficientBaselineResult() -> ReadinessResult {
        ReadinessResult(
            score: nil,
            band: nil,
            breakdown: [],
            recommendation: "Still learning your baseline — check back in a few days",
            status: .insufficientBaseline
        )
    }

    private static func isMetricValid(_ metric: MetricInput) -> Bool {
        guard metric.daysOfBaselineData >= Tuning.minBaselineDays else { return false }
        guard let today = metric.todayValue, today.isFinite else { return false }
        guard let mean = metric.baselineMean, mean.isFinite else { return false }
        guard let stdDev = metric.baselineStdDev, stdDev.isFinite, stdDev > 1e-9 else { return false }
        return true
    }

    private static func clampZ(_ z: Double) -> Double {
        guard z.isFinite else { return 0 }
        return clamp(z, min: -Tuning.maxAbsZ, max: Tuning.maxAbsZ)
    }

    private static func subscore(forZ z: Double) -> Int {
        let raw = Tuning.subscoreCentre + (z * Tuning.subscoreSpreadPerSigma)
        return Int(round(clamp(raw, min: 0.0, max: 100.0)))
    }

    private static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private static func band(for score: Int) -> ReadinessBand {
        switch score {
        case 80...100: return .ready
        case 60...79:  return .good
        case 40...59:  return .fair
        default:       return .poor
        }
    }

    private static func recommendation(for band: ReadinessBand) -> String {
        switch band {
        case .ready:
            return "You're well recovered. Heavy training and high intensity work are fair game today."
        case .good:
            return "Solid recovery. Moderate training is a good fit today."
        case .fair:
            return "Recovery is so-so. Keep today lighter — easy session or active recovery."
        case .poor:
            return "Recovery is poor. Prioritize rest, sleep, and light movement today."
        }
    }
}
