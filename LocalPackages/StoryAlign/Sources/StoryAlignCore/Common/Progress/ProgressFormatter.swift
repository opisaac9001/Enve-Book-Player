//
//  ProgressFormatter.swift
//  StoryAlign
//
//  Created by Rich Waters on 1/24/26.
//


import Foundation


fileprivate let GH_BYTES_PER_KiB: Double = 1024
fileprivate let GH_BYTES_PER_MiB: Double = GH_BYTES_PER_KiB * GH_BYTES_PER_KiB
fileprivate let GH_BYTES_PER_GiB: Double = GH_BYTES_PER_KiB * GH_BYTES_PER_MiB

fileprivate let secondsPerMinute = 60.0
fileprivate let secondsPerHour = 60.0*secondsPerMinute


public struct ProgressFormatter {
    public init() {}
    
    public func format( count: Double, overTot: Double, unit:ProgressUnit) -> String {
        if overTot == 0 {
            return ""
        }
        if unit == .chapters {
            return "\(Int(count))/\(Int(overTot)) chapters"
        }
        if unit == .tracks {
            return "\(Int(count))/\(Int(overTot)) tracks"
        }
        
        if let (divisor, sfx, decimals) = scaleFor(count: count, unit: unit) {
            let fmt = "%.\(decimals)f"
            let countStr = String(format: fmt, count / divisor)
            let totStr = String(format: fmt, overTot / divisor)
            return "\(countStr)/\(totStr) \(sfx)"
        }
        
        return "\(Int(count))/\(Int(overTot))"
    }
    
    public func scaleFor(count: Double, unit: ProgressUnit) -> (Double, String, Int)? {
        if unit == .bytes {
            if count > GH_BYTES_PER_GiB { return (GH_BYTES_PER_GiB, "GB", 2) }
            if count > GH_BYTES_PER_MiB { return (GH_BYTES_PER_MiB, "MB", 1) }
            if count > GH_BYTES_PER_KiB { return (GH_BYTES_PER_KiB, "KB", 1) }
            return (1.0, "bytes", 0)
        }

        if unit == .sentences || unit == .words || unit == .phrases {
            let unitStr = (unit == .sentences) ? "sentences" : (unit == .phrases) ? "phrases" : "words"
            if count > GH_BYTES_PER_MiB { return (GH_BYTES_PER_MiB, "million \(unitStr)", 1) }
            return (1.0, unitStr, 0)
        }
    
        if unit == .seconds {
            if count > secondsPerHour { return (secondsPerHour, "hours", 2) }
            if count > secondsPerMinute { return (secondsPerMinute, "minutes", 1) }
            return (1.0, "seconds", 0)
        }

        return nil
    }
    
    
    public func stageTotalText(_ snapshot: ProgressSnapshot) -> String? {
        guard snapshot.stageTotal != 0 else { return nil }
        let countOverTot = format(count: snapshot.stageProgress, overTot: snapshot.stageTotal, unit: snapshot.unit)
        return countOverTot.split(separator: "/").last.map(String.init)
    }
    
    public func detailedStageText(_ snapshot: ProgressSnapshot) -> String {
        let label = title(for: snapshot.stage)
        
        if snapshot.event == .end {
            let completed = completedTitle(for: snapshot.stage)
            guard let tot = stageTotalText(snapshot) else { return completed }
            return "\(completed) \(tot)"
        }
        
        guard snapshot.stageTotal != 0 else { return label }
        guard snapshot.stageProgress != 0 else { return "\(label)..." }
        
        let countOverTot = format(count: snapshot.stageProgress, overTot: snapshot.stageTotal, unit: snapshot.unit)
        return "\(label): \(countOverTot)"
    }
    
    public func title(for stage: ProgressStage) -> String {
        switch stage {
            case .epub: return "Parsing"
            case .model: return "Loading model"
            case .transcribe: return "Transcribing"
            case .align: return "Aligning"
            case .audio: return "Extracting audio"
            case .alignWords: return "Aligning"
            case .xml: return "Tagging"
            case .export: return "Exporting"
            case .report: return "Generating Report"
        }
    }
    public func completedTitle(for stage: ProgressStage) -> String {
        switch stage {
            case .epub: return "Parsed"
            case .model: return "Loaded model"
            case .transcribe: return "Transcribed"
            case .align: return "Aligned"
            case .audio: return "Extracted"
            case .alignWords: return "Aligned"
            case .xml: return "Tagged"
            case .export: return "Exported"
            case .report: return "Generated Report"
        }
    }
}
