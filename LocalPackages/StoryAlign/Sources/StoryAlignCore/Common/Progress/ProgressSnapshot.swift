//
// ProgressSnapshot.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Rich Waters
//


import Foundation

/// A point-in-time snapshot of alignment progress.
///
/// `ProgressSnapshot` is what gets delivered to progress listeners. It captures:
/// - the current stage (`stage`) and what just happened (`event`)
/// - per-stage progress (`stageProgress` / `stageTotal`) in a given unit
/// - the current item being processed (if any)
/// - timing info for the current stage and for the overall run
/// - the planned workflow and what has completed so far
///
/// Notes:
/// - `stageProgress` and `stageTotal` are *stage-local*. Use `workflowProgress or timeEstimateProgress
///  if you want a single overall progress value between 0 and 1.
/// - Timing values are seconds.
///
public struct ProgressSnapshot : Sendable {
    public let stage:ProgressStage
    public let event:ProgressStageEvent
    public let stageProgress:Double
    public let stageTotal:Double
    public let unit:ProgressUnit
    public let item:String
    public let stageRunTime:Double
    public let runTime:Double
    public let completedStages:[ProgressStage]
    public let plannedStages:[ProgressStage]
}

public extension ProgressSnapshot {
    var isFinalStage: Bool {
        self.stage == plannedStages.last
    }
    var isFirstStage: Bool {
        self.stage == plannedStages.first
    }
}

public extension ProgressSnapshot {
    
    
    /// Overall workflow progress (0...1) based on completed stages plus current-stage fraction.
    ///
    /// This is a simple "each stage counts the same" estimate. It works well for UI that just needs a bar,
    /// but it won't match actual runtime when some stages dominate (transcription, in particular).
    ///
    var workflowProgress: Double {
        guard plannedStages.count > 0 else { return 0.0 }
        
        let stageFrac: Double = {
            guard stageTotal > 0 else { return 0.0 }
            return min(1.0, max(0.0, stageProgress / stageTotal))
        }()
        
        let overall = (Double(completedStages.count) + stageFrac) / Double(plannedStages.count)
        return min(1.0, max(0.0, overall))
    }
    
    
    /// A time-ish progress estimate (0...1) using relative stage weights.
    ///
    /// This is intended for the "how far along are we really?" style of progress display.
    /// It uses a weighted sum of stages (by default: transcription dominates), then adds a fraction
    /// for the current stage based on `stageProgress / stageTotal`.
    ///
    /// - Parameters:
    ///      - weights: Optional per-stage weights. Stages that are not planned for this run are treated
    ///
    /// - Returns:
    ///     - A value between 0 and 1 that is the fraction of estimated time completed
    ///
    /// - Note: Like any time estimate, this is only a guess. Some books/models behave unpredictably
    ///
    func timeEstimateProgress(weights: [ProgressStage: Double]? = nil ) -> Double {
        var weights = (weights ?? defaultRelativeWeights)
        let skippedStages = ProgressStage.orderedCases.filter { !plannedStages.contains($0) }
        for stage in skippedStages {
            weights[stage]? = 0
        }
        let normalizedWeights = self.normalizedWeights(weights)
        
        let sumW = normalizedWeights.values.reduce(0.0, +)
        guard sumW > 0 else { return 0.0 }
        
        let frac: Double = {
            guard stageTotal > 0 else { return 0 }
            return min(1, max(0, stageProgress / stageTotal))
        }()
        
        var completedW = 0.0
        for s in completedStages {
            completedW += normalizedWeights[s] ?? 0.0
        }
        
        let currentW = normalizedWeights[stage] ?? 0.0
        return min(1, max(0, (completedW + currentW * frac) / sumW))
    }
}

public extension ProgressSnapshot {
   var defaultRelativeWeights: [ProgressStage: Double] {
       [
           .epub : 1,
           .audio : 1,
           .transcribe : 70,
           .model : 2,
           .align:16,
           .alignWords:2,
           .xml:3,
           .export:4,
           .report:1
       ]
   }
   
   func normalizedWeights(_ weights: [ProgressStage: Double]) -> [ProgressStage: Double] {
       let sum = weights.values.reduce(0.0, +)
       guard sum > 0 else { return weights }
       return weights.mapValues { $0 / sum }
   }
}
