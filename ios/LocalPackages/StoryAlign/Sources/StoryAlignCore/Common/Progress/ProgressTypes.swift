//
// ProgressUpdater.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters


import Foundation


/// A callback interface for receiving progress updates.
///
/// Progress listeners are registered on an `AlignmentSession`. Each callback receives a `ProgressSnapshot`
/// describing the current stage, what just happened (start/update/end), and the current counts/timing.
///
public protocol ProgressListener : Sendable {
    func show(_ progressSnapshot:ProgressSnapshot ) -> Void
}


/// Units for progress reporting.
///
/// A stage reports progress as `stageProgress` / `stageTotal` in one of these units.
/// Not all stages have meaningful totals, so some stages use `.none`.
///
public enum ProgressUnit : Int, Sendable {
    case none = 0
    case bytes
    case seconds
    case sentences
    case words
    case phrases
    case chapters
    case tracks
}



/// The kind of update represented by a progress snapshot.
///
public enum ProgressStageEvent : Int, Sendable {
    case start
    case update
    case end
}


/// The alignment pipeline stages, in execution order.
///
/// Stages are planned up-front based on config (for example: reports can be omitted, and word alignment
/// only runs for certain granularities).
///
public enum ProgressStage: String, OrderedCaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case epub
    case audio
    case model
    case transcribe
    case align
    case alignWords
    case xml
    case export
    case report
    
    public static var orderedCases: [ProgressStage] {
        return [.epub, .audio, .model, .transcribe, .align, .alignWords, .xml, .export, .report]
    }
}


public extension ProgressStage {
    var unit: ProgressUnit {
        switch self {
            case .epub: return .chapters
            case .audio: return .tracks
            case .model: return .none
            case .transcribe: return .seconds
            case .align: return .sentences
            case .alignWords: return .words
            case .xml: return .bytes
            case .export: return .bytes
            case .report: return .none
        }
    }
}

