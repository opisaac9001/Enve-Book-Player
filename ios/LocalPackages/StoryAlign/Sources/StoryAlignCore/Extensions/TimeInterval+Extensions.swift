//
// TimeInterval+Extensions.swift
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Rich Waters
//

import Foundation
import CryptoKit

public extension TimeInterval {
    var HHMMSSs:String {
        let totalHundredths = Int(self * 100)
        let hours       = totalHundredths / 360000
        let minutes     = (totalHundredths % 360000) / 6000
        let seconds     = (totalHundredths % 6000) / 100
        let fraction    = totalHundredths % 100
        return String(format: "%02d:%02d:%02d.%02d", hours, minutes, seconds, fraction)
    }
    var HHMMSS:String {
        String(HHMMSSs.dropLast(3))
    }

}

public extension Double {
    func roundToUs() -> Double {
        return (self * 1000000).rounded() / 1000000
    }

    func roundToMs() -> Double {
        return (self * 1000).rounded() / 1000
    }
    func roundToCs() -> Double {
        return (self * 100).rounded() / 100
    }
    
    func modifiedZcore( forMedian:Double, medianAbsoluteDeviation:Double ) -> Double {
        guard medianAbsoluteDeviation > 0  else {
            return 0
        }
        return 0.6745 * (self - forMedian) / medianAbsoluteDeviation
    }
}

public extension [Double] {
    func average() -> Double {
        if self.isEmpty {
            return 0
        }
        let sum = self.reduce(0, +)
        return sum/Double(self.count)
    }
    
    func median() -> Double {
        if isEmpty {
            return 0
        }
        let sorted = self.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count/2]
        }
        return (sorted[count/2 - 1] + sorted[count/2]) / 2
    }
    
    func medianAbsoluteDeviation() -> Double {
        if isEmpty {
            return 0
        }
        let med = median()
        let devs = map { abs($0 - med) }.sorted()
        let mid = devs.count / 2
        if devs.count % 2 == 0 {
            return (devs[mid - 1] + devs[mid]) / 2
        }
        return devs[mid]
    }
}


extension [Float] {
    var sha256:String {
        var h = SHA256()
        self.withUnsafeBytes { h.update(data: $0) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}


extension DispatchTime {
    func secondsSince(_ other: DispatchTime) -> TimeInterval {
        let delta = Int64(bitPattern: self.uptimeNanoseconds) - Int64(bitPattern: other.uptimeNanoseconds)
        return TimeInterval(delta) / 1_000_000_000
    }
}


