//
//  ReadinessEngine.swift
//  Health 26
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
    public let acuteLoad: Double?            // trailing 3-day avg active energy (kcal)
    public let chronicLoad: Double?          // trailing 28-day avg active energy (kcal)
    public let yesterdayHRV: Double?         // ms, for acute-drop guardrail
    
    public init(
        hrv: MetricInput,
        restingHeartRate: MetricInput,
        sleepHours: MetricInput,
        acuteLoad: Double?,
        chronicLoad: Double?,
        yesterdayHRV: Double?
    ) {
        self.hrv = hrv
        self.restingHeartRate = restingHeartRate
        self.sleepHours = sleepHours
        self.acuteLoad = acuteLoad
        self.chronicLoad = chronicLoad
        self.yesterdayHRV = yesterdayHRV
    }
}

public enum ReadinessBand: String, Sendable, CaseIterable {
    case ready = "Ready"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
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
    public let insufficientData: Bool
    
    public init(
        score: Int?,
        band: ReadinessBand?,
        breakdown: [MetricBreakdown],
        recommendation: String,
        insufficientData: Bool
    ) {
        self.score = score
        self.band = band
        self.breakdown = breakdown
        self.recommendation = recommendation
        self.insufficientData = insufficientData
    }
}

public enum ReadinessEngine {
    
    // Base Weights
    private static let hrvBaseWeight: Double = 0.35
    private static let rhrBaseWeight: Double = 0.25
    private static let sleepBaseWeight: Double = 0.25
    private static let loadBaseWeight: Double = 0.15
    
    public static func calculate(from input: ReadinessInput) -> ReadinessResult {
        // 1. Check if core metrics (HRV, RHR, Sleep) are all skipped -> Insufficient Data
        let isHrvValid = isMetricValid(input.hrv)
        let isRhrValid = isMetricValid(input.restingHeartRate)
        let isSleepValid = isMetricValid(input.sleepHours)
        
        if !isHrvValid && !isRhrValid && !isSleepValid {
            return ReadinessResult(
                score: nil,
                band: nil,
                breakdown: [],
                recommendation: "Still learning your baseline — check back in a few days",
                insufficientData: true
            )
        }
        
        var activeSubscores: [(subscore: Double, baseWeight: Double)] = []
        var breakdowns: [MetricBreakdown] = []
        
        // 2. HRV Calculation
        if isHrvValid,
           let today = input.hrv.todayValue,
           let mean = input.hrv.baselineMean,
           let stdDev = input.hrv.baselineStdDev {
            let z = (today - mean) / stdDev
            let sub = subscore(forZ: z)
            activeSubscores.append((Double(sub), hrvBaseWeight))
            
            let pctDiff = mean != 0 ? ((today - mean) / mean) * 100.0 : 0.0
            let statusStr = String(format: "%.1f ms (%.0f%% vs avg)", today, pctDiff)
            breakdowns.append(MetricBreakdown(name: "HRV", subscore: sub, status: statusStr))
        }
        
        // 3. Resting Heart Rate Calculation (Inverted: lower RHR is better)
        if isRhrValid,
           let today = input.restingHeartRate.todayValue,
           let mean = input.restingHeartRate.baselineMean,
           let stdDev = input.restingHeartRate.baselineStdDev {
            let z = (mean - today) / stdDev
            let sub = subscore(forZ: z)
            activeSubscores.append((Double(sub), rhrBaseWeight))
            
            let diff = today - mean
            let statusStr = String(format: "%.0f bpm (%@%.1f bpm vs avg)", today, diff >= 0 ? "+" : "", diff)
            breakdowns.append(MetricBreakdown(name: "Resting HR", subscore: sub, status: statusStr))
        }
        
        // 4. Sleep Calculation
        if isSleepValid,
           let today = input.sleepHours.todayValue,
           let mean = input.sleepHours.baselineMean,
           let stdDev = input.sleepHours.baselineStdDev {
            let z = (today - mean) / stdDev
            let sub = subscore(forZ: z)
            activeSubscores.append((Double(sub), sleepBaseWeight))
            
            let diff = today - mean
            let statusStr = String(format: "%.1f hrs (%@%.1fh vs avg)", today, diff >= 0 ? "+" : "", diff)
            breakdowns.append(MetricBreakdown(name: "Sleep", subscore: sub, status: statusStr))
        }
        
        // 5. Training Load Calculation
        if let acute = input.acuteLoad,
           let chronic = input.chronicLoad,
           chronic > 0 {
            let loadRatio = acute / chronic
            let zLoad = clamp((1.0 - loadRatio) * 3.0, min: -1.5, max: 1.0)
            let sub = subscore(forZ: zLoad)
            activeSubscores.append((Double(sub), loadBaseWeight))
            
            let statusStr = String(format: "Ratio: %.2fx (%.0f / %.0f kcal)", loadRatio, acute, chronic)
            breakdowns.append(MetricBreakdown(name: "Training Load", subscore: sub, status: statusStr))
        }
        
        // Safety check if activeSubscores is empty (should be caught by isHrvValid / isRhrValid / isSleepValid)
        guard !activeSubscores.isEmpty else {
            return ReadinessResult(
                score: nil,
                band: nil,
                breakdown: [],
                recommendation: "Still learning your baseline — check back in a few days",
                insufficientData: true
            )
        }
        
        // 6. Weight Renormalization
        let totalActiveWeight = activeSubscores.reduce(0.0) { $0 + $1.baseWeight }
        let weightedSum = activeSubscores.reduce(0.0) { $0 + ($1.subscore * ($1.baseWeight / totalActiveWeight)) }
        var compositeScore = Int(round(weightedSum))
        
        // 7. Guardrails (Cap score, only lowering it)
        // Guardrail 1: Sleep < 4.0 hours -> cap at 55
        if let sleepToday = input.sleepHours.todayValue, sleepToday < 4.0 {
            compositeScore = min(compositeScore, 55)
        }
        
        // Guardrail 2: Today's HRV < 70% of yesterday's HRV -> cap at 60
        if let todayHRV = input.hrv.todayValue,
           let yesterdayHRV = input.yesterdayHRV,
           todayHRV < (yesterdayHRV * 0.70) {
            compositeScore = min(compositeScore, 60)
        }
        
        // Final Score Clamping
        let finalScore = clamp(compositeScore, min: 0, max: 100)
        let band = band(for: finalScore)
        let recommendation = recommendation(for: band)
        
        return ReadinessResult(
            score: finalScore,
            band: band,
            breakdown: breakdowns,
            recommendation: recommendation,
            insufficientData: false
        )
    }
    
    // MARK: - Helpers
    
    private static func isMetricValid(_ metric: MetricInput) -> Bool {
        guard metric.daysOfBaselineData >= 1 else { return false }
        guard let today = metric.todayValue, !today.isNaN else { return false }
        guard let mean = metric.baselineMean, !mean.isNaN else { return false }
        guard let stdDev = metric.baselineStdDev, !stdDev.isNaN, stdDev > 1e-9 else { return false }
        return true
    }
    
    private static func subscore(forZ z: Double) -> Int {
        let rawSub = 50.0 + (z * 20.0)
        let clamped = clamp(rawSub, min: 0.0, max: 100.0)
        return Int(round(clamped))
    }
    
    private static func clamp<T: Comparable>(_ value: T, min minValue: T, max maxValue: T) -> T {
        return Swift.min(Swift.max(value, minValue), maxValue)
    }
    
    private static func band(for score: Int) -> ReadinessBand {
        switch score {
        case 80...100:
            return .ready
        case 60...79:
            return .good
        case 40...59:
            return .fair
        default:
            return .poor
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
