import Foundation

struct EnveAchievement: Identifiable {
    let id: String
    let title: String
    let group: String
    let systemImage: String
    let progress: Double
    let target: Double
    let detail: String

    var earned: Bool { progress >= target }

    var fraction: Double {
        guard target > 0 else { return 0 }
        return min(max(progress / target, 0), 1)
    }
}

struct EnveAchievementTally {
    var totalSeconds: TimeInterval = 0
    var audiobookSeconds: TimeInterval = 0
    var ebookSeconds: TimeInterval = 0
    var sessionCount = 0
    var dailySeconds: [String: TimeInterval] = [:]
    var streak = 0
    var finishedBooks = 0
    var finishedAudiobooks = 0
    var finishedEbooks = 0
    var sources: Set<HistorySource> = []

    var totalHours: Double { totalSeconds / 3600 }
    var audiobookHours: Double { audiobookSeconds / 3600 }
    var ebookHours: Double { ebookSeconds / 3600 }
}

enum EnveAchievementsPolicy {

    static func tally(sessions: [HistorySession], books: [Book]) -> EnveAchievementTally {
        var tally = EnveAchievementTally()
        var seen = Set<String>()

        for session in sessions {
            if !session.id.isEmpty, !seen.insert(session.id).inserted { continue }
            let seconds = TimeInterval(max(0, session.durationSeconds))
            tally.sessionCount += 1
            tally.totalSeconds += seconds
            tally.sources.insert(session.source)
            if session.mediaType.lowercased() == "audiobook" {
                tally.audiobookSeconds += seconds
            } else {
                tally.ebookSeconds += seconds
            }
            if seconds > 0 {
                tally.dailySeconds[JournalStats.dayKey(for: session.endTime), default: 0] += seconds
            }
        }

        tally.streak = JournalStats.streak(tally.dailySeconds)

        for book in books where book.isFinished && book.mediaType != .podcast {
            tally.finishedBooks += 1
            switch book.mediaType {
            case .audiobook: tally.finishedAudiobooks += 1
            case .ebook: tally.finishedEbooks += 1
            default: break
            }
        }

        return tally
    }

    static func achievements(_ tally: EnveAchievementTally) -> [EnveAchievement] {
        streakBadges(tally) + timeBadges(tally) + sessionBadges(tally) + finishedBadges(tally) + formatBadges(tally)
    }

    private static func streakBadges(_ tally: EnveAchievementTally) -> [EnveAchievement] {
        let glyphs = ["flame", "flame.fill", "flame.circle.fill", "crown.fill"]
        return zip([3, 7, 30, 100], glyphs).map { days, glyph in
            EnveAchievement(
                id: "streak.\(days)",
                title: "\(days) nights running",
                group: "Streak",
                systemImage: glyph,
                progress: Double(tally.streak),
                target: Double(days),
                detail: "\(min(tally.streak, days)) of \(days) nights"
            )
        }
    }

    private static func timeBadges(_ tally: EnveAchievementTally) -> [EnveAchievement] {
        let glyphs = ["1.circle.fill", "10.circle.fill", "star.circle.fill", "hourglass", "infinity.circle.fill"]
        return zip([1, 10, 50, 100, 500], glyphs).map { hours, glyph in
            EnveAchievement(
                id: "hours.\(hours)",
                title: hours == 1 ? "First hour" : "\(hours) hours",
                group: "Time",
                systemImage: glyph,
                progress: tally.totalHours,
                target: Double(hours),
                detail: "\(hoursLabel(min(tally.totalHours, Double(hours)))) of \(hours)h"
            )
        }
    }

    private static func sessionBadges(_ tally: EnveAchievementTally) -> [EnveAchievement] {
        let glyphs = ["play.circle.fill", "square.stack.3d.up.fill", "building.columns.fill"]
        return zip([10, 100, 500], glyphs).map { count, glyph in
            EnveAchievement(
                id: "sessions.\(count)",
                title: "\(count) sittings",
                group: "Sittings",
                systemImage: glyph,
                progress: Double(tally.sessionCount),
                target: Double(count),
                detail: "\(min(tally.sessionCount, count)) of \(count)"
            )
        }
    }

    private static func finishedBadges(_ tally: EnveAchievementTally) -> [EnveAchievement] {
        let glyphs = ["checkmark.seal.fill", "books.vertical.fill", "trophy.fill", "medal.fill"]
        return zip([1, 5, 20, 50], glyphs).map { count, glyph in
            EnveAchievement(
                id: "finished.\(count)",
                title: count == 1 ? "First finish" : "\(count) finished",
                group: "Finished",
                systemImage: glyph,
                progress: Double(tally.finishedBooks),
                target: Double(count),
                detail: "\(min(tally.finishedBooks, count)) of \(count)"
            )
        }
    }

    private static func formatBadges(_ tally: EnveAchievementTally) -> [EnveAchievement] {
        let ebookGlyphs = ["book.fill", "book.closed.fill", "text.book.closed.fill"]
        let audioGlyphs = ["headphones", "headphones.circle.fill", "waveform.circle.fill"]
        let ebooks = zip([1, 10, 25], ebookGlyphs).map { count, glyph in
            EnveAchievement(
                id: "ebooks.\(count)",
                title: count == 1 ? "First ebook" : "\(count) ebooks",
                group: "Ebooks",
                systemImage: glyph,
                progress: Double(tally.finishedEbooks),
                target: Double(count),
                detail: "\(min(tally.finishedEbooks, count)) of \(count)"
            )
        }
        let audiobooks = zip([1, 10, 25], audioGlyphs).map { count, glyph in
            EnveAchievement(
                id: "audiobooks.\(count)",
                title: count == 1 ? "First audiobook" : "\(count) audiobooks",
                group: "Audiobooks",
                systemImage: glyph,
                progress: Double(tally.finishedAudiobooks),
                target: Double(count),
                detail: "\(min(tally.finishedAudiobooks, count)) of \(count)"
            )
        }
        return ebooks + audiobooks
    }

    static func nextUp(_ achievements: [EnveAchievement]) -> EnveAchievement? {
        achievements
            .filter { !$0.earned && $0.fraction > 0 }
            .max { $0.fraction < $1.fraction }
    }

    static func hoursLabel(_ hours: Double) -> String {
        hours < 10 ? String(format: "%.1fh", hours) : "\(Int(hours.rounded()))h"
    }
}
