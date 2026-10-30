import Foundation

struct CTCEmissionWindow {
    let start: Double
    let emissions: CTCEmissions

    func joining(_ next: CTCEmissionWindow) throws -> CTCEmissionWindow {
        guard emissions.classes == next.emissions.classes,
              emissions.secondsPerFrame == next.emissions.secondsPerFrame,
              next.start > start else { throw StoryAlignError("Incompatible CTC audio windows.") }
        let step = emissions.secondsPerFrame
        let end = start + Double(emissions.frames) * step
        guard next.start < end else { throw StoryAlignError("CTC audio windows have no overlap.") }
        let midpoint = (end + next.start) / 2
        let keep = min(emissions.frames, max(0, Int(((midpoint - start) / step).rounded())))
        let drop = min(next.emissions.frames, max(0, Int(((start + Double(keep) * step - next.start) / step).rounded())))
        let frames = keep + next.emissions.frames - drop
        let trim = max(0, frames - Int(74 / step))
        guard trim < keep else { throw StoryAlignError("The CTC seam window exceeds its memory limit.") }
        var values = Array(emissions.values[(trim * emissions.classes)..<(keep * emissions.classes)])
        values.append(contentsOf: next.emissions.values.dropFirst(drop * emissions.classes))
        return CTCEmissionWindow(start: start + Double(trim) * step, emissions: CTCEmissions(values: values, frames: frames - trim, classes: emissions.classes, secondsPerFrame: step))
    }
}
