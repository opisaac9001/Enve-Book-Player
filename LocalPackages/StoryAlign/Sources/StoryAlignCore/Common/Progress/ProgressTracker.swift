//
//  ProgressTracker.swift
//  StoryAlign
//
//  Created by Rich Waters on 1/24/26.
//


import Foundation

class ProgressTracker : @unchecked Sendable {
    let plannedStages:[ProgressStage]
    let alignmentStageUnit:ProgressUnit
    let logger:Logger?
    private let updateQueue = SafeDispatchQueue( label: "com.goodhumans.storyalign.progresstracker" )
    private let notifyQueue = SafeDispatchQueue(label: "com.goodhumans.storyalign.progress.notify")

    private var stageProgress:[ProgressStage:Double] = [:]
    private var stageTotal:[ProgressStage:Double] = [:]
    private var listeners:[Int:ProgressListener] = [:]
    private var listenerHandle:Int = 0
    private var stageStartTime: [ProgressStage: DispatchTime] = [:]
    private var stageEndTime: [ProgressStage: DispatchTime] = [:]

    private var runStartTime: DispatchTime = .now()
    private var completedStages:[ProgressStage] = []
    
    private var heartbeatTimer: DispatchSourceTimer?
    private var currentStage: ProgressStage?
    private var currentItem: String = ""
    
    init( plannedStages:[ProgressStage], alignmentStageUnit:ProgressUnit, logger:Logger? ) {
        self.plannedStages = plannedStages
        self.alignmentStageUnit = alignmentStageUnit
        self.logger = logger
    }
    
    deinit {
        self.updateQueue.sync {
            self.stopHeartbeatTimerFromQueue()
        }
    }
    
    var totalStages:Int { plannedStages.count }
    
    func addListener(_ listener:ProgressListener ) -> Int {
        updateQueue.sync {
            listenerHandle += 1
            listeners[listenerHandle] = listener
            return listenerHandle
        }
    }
    func removeListener( handle:Int ) {
        _ = updateQueue.sync {
            self.listeners.removeValue(forKey: handle)
        }
    }
}


extension ProgressTracker {    
    func updateProgress(
        for stage: ProgressStage,
        event: ProgressStageEvent = .update,
        increment: Double=0.0,
        total: Double? = nil,
        item: String = "" ,
    ) {
        self.updateQueue.async {

            if event == .start {
                if stage == self.plannedStages.first {
                    self.resetFromQueue()
                }
                if !self.listeners.isEmpty {
                    self.startHeartbeatTimerFromQueue()
                }
            }
            self.currentStage = stage
            self.currentItem = item
            
            let stageProgress = (self.stageProgress[stage] ?? 0.0) + increment
            self.stageProgress[stage] = stageProgress
            
            if self.stageStartTime[stage] == nil {
                self.stageStartTime[stage] = .now()
            }
            
            let stageTotal = self.stageTotal[stage] ?? 0.0
            let nuTotal = total ?? stageTotal
            if nuTotal != stageTotal {
                self.stageTotal[stage] = nuTotal
            }
            
            self.emitSnapshotFromQueue(stage: stage, event: event, item: item)
            
            if event == .end {
                self.currentStage = nil
                if self.completedStages.contains(stage) {
                    self.logger?.log( .debug, "Ignoring duplicate end for stage: \(stage)")
                    return
                }
                self.completedStages.append(stage)
                self.stageEndTime[stage] = .now()
                self.stopHeartbeatTimerFromQueue()
            }
        }
    }
    
    func updateProgress<N: BinaryInteger & Sendable>(
        for stage: ProgressStage,
        event: ProgressStageEvent = .update,
        increment: N = 0,
        total: N? = nil,
        item: String = "",
    ) {
        updateProgress(
            for: stage,
            event: event,
            increment: Double(increment),
            total: total.map(Double.init),
            item: item,
        )
    }
}

extension ProgressTracker {
    func reset() {
        self.updateQueue.sync {
           resetFromQueue()
        }
    }
    func finish() {
        self.reset()
    }
}

private extension ProgressTracker {
    var overallRuntimeFromQueue: TimeInterval {
        let endTime = {
            guard let last = plannedStages.last else {
                return DispatchTime.now()
            }
            return stageEndTime[last] ?? .now()
        }()
        return endTime.secondsSince(runStartTime)
    }
    func runTimeFromQueue( forStage:ProgressStage ) -> TimeInterval {
        guard let startTime = stageStartTime[forStage] else {
            return 0.0
        }
        let endTime = stageEndTime[forStage] ?? .now()
        return endTime.secondsSince(startTime)
    }
}

extension ProgressTracker {
    var overallRunTime: TimeInterval {
        return updateQueue.sync {
            overallRuntimeFromQueue
        }
    }

    func runTime( forStage:ProgressStage ) -> TimeInterval {
        return updateQueue.sync {
            runTimeFromQueue(forStage: forStage )
        }
    }
    
    var completedStageRunTimes: [ProgressStage:TimeInterval] {
        updateQueue.sync {
            completedStages.reduce(into: [ProgressStage:TimeInterval]() ) { (result, stage) in
                result[stage] = runTimeFromQueue(forStage: stage)
            }
        }
    }
}

private extension ProgressTracker {
    func emitSnapshotFromQueue(stage: ProgressStage, event: ProgressStageEvent, item: String) {
        let stageProgress = self.stageProgress[stage] ?? 0.0
        let stageTotal = self.stageTotal[stage] ?? 0.0

        let unit = stage == .align ? self.alignmentStageUnit : stage.unit
        let stageElapsed = self.runTimeFromQueue(forStage: stage)
        let totalElapsed = self.overallRuntimeFromQueue

        let snapShot = ProgressSnapshot(
            stage: stage,
            event: event,
            stageProgress: stageProgress,
            stageTotal: stageTotal,
            unit: unit,
            item: item,
            stageRunTime: stageElapsed,
            runTime: totalElapsed,
            completedStages: self.completedStages,
            plannedStages: self.plannedStages
        )

        let listeners = Array(self.listeners.values)
        notifyQueue.async {
            for listener in listeners {
                listener.show(snapShot)
            }
        }
    }
    
    func startHeartbeatTimerFromQueue() {
        guard heartbeatTimer == nil else { return }

        let t = DispatchSource.makeTimerSource(queue: updateQueue.queue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard let stage = self.currentStage else { return }
            self.emitSnapshotFromQueue(stage: stage, event: .update, item: self.currentItem)
        }

        heartbeatTimer = t
        t.activate()
    }

    func stopHeartbeatTimerFromQueue() {
        guard let t = heartbeatTimer else { return }
        heartbeatTimer = nil
        t.cancel()
    }
    
    func resetFromQueue() {
        self.stopHeartbeatTimerFromQueue()
        self.stageProgress = [:]
        self.stageTotal = [:]
        self.stageStartTime = [:]
        self.stageEndTime = [:]
        self.runStartTime = .now()
        self.completedStages = []
        self.currentStage = nil
        self.currentItem = ""
    }
}
