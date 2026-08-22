import SwiftUI

extension Book {

    var hearthCoverRatio: CGFloat {
        mediaType == .ebook ? 1.5 : 1.0
    }
}

struct CoverTile: View {
    let book: Book
    var width: CGFloat
    var showsProgress = false

    var badges: Bool = true
    var corner: CGFloat = Hearth.radiusCover

    @Environment(\.hearth) private var hearth

    private var showBadges: Bool { badges && width >= 64 }

    var body: some View {
        CachedAsyncCoverImage(
            url: book.coverURL,
            fallbackColor: "Blue",
            headers: CachedAsyncCoverImage.authHeaders(for: book),
            book: book
        )
        .aspectRatio(1 / book.hearthCoverRatio, contentMode: .fill)
        .frame(width: width, height: width * book.hearthCoverRatio)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            if showBadges, book.isFinished {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(hearth.bg.opacity(0.38))
            }
        }
        .overlay(alignment: .topLeading) {
            if showBadges { stateBadges.padding(6) }
        }
        .overlay(alignment: .topTrailing) {
            if showBadges, book.isFinished {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: max(13, width * 0.13), weight: .bold))
                    .foregroundStyle(hearth.ember)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottom) {
            if showsProgress, fraction > 0.001, !book.isFinished {
                Ribbon(progress: fraction, tint: hearth.ember)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 7)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hearth.isInk ? 0.45 : 0.18), radius: 14, y: 8)
    }

    @ViewBuilder
    private var stateBadges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hasReadAloudBadge {
                CoverReadAloudBadge()
            } else if book.hasAlternateFormat || book.linkedAudiobookStableId != nil {
                CoverGlyphBadge(systemName: book.mediaType == .ebook ? "headphones" : "book.closed")
            }
        }
    }

    private var hasReadAloudBadge: Bool {
        book.readAloudSourceStableId != nil || book.epub3Features?.hasMediaOverlay == true
    }

    private var fraction: Double {
        if book.mediaType == .ebook {
            return book.canonicalEbookProgress
        }
        guard let duration = book.duration, duration > 0 else { return 0 }
        return min(max(book.currentTime / duration, 0), 1)
    }
}

private struct CoverReadAloudBadge: View {
    @Environment(\.hearth) private var hearth

    var body: some View {
        StorytellerReadAloudMark()
            .foregroundStyle(hearth.readableOnEmber)
            .frame(width: 15, height: 17)
            .frame(width: 20, height: 20)
            .background {
                Circle().fill(hearth.ember)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
    }
}

private struct StorytellerReadAloudMark: View {
    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 26, geo.size.height / 30)
            ZStack {
                ReadAloudSignalShape()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ReadAloudBookShape()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            .frame(width: 26, height: 30)
            .scaleEffect(scale)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

private struct ReadAloudSignalShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(6.2959, 12.6312, in: rect))
        path.addCurve(
            to: point(9.33011, 10.4828, in: rect),
            control1: point(7.14994, 11.7153, in: rect),
            control2: point(8.18258, 10.9842, in: rect)
        )
        path.addCurve(
            to: point(12.968, 9.7162, in: rect),
            control1: point(10.4776, 9.98148, in: rect),
            control2: point(11.7157, 9.72057, in: rect)
        )
        path.addCurve(
            to: point(16.6111, 10.4574, in: rect),
            control1: point(14.2202, 9.71183, in: rect),
            control2: point(15.4601, 9.96408, in: rect)
        )
        path.addCurve(
            to: point(19.6602, 12.5845, in: rect),
            control1: point(17.7621, 10.9507, in: rect),
            control2: point(18.7998, 11.6746, in: rect)
        )
        path.move(to: point(8.97753, 15.1318, in: rect))
        path.addCurve(
            to: point(10.7981, 13.8428, in: rect),
            control1: point(9.48995, 14.5823, in: rect),
            control2: point(10.1095, 14.1436, in: rect)
        )
        path.addCurve(
            to: point(12.9808, 13.3828, in: rect),
            control1: point(11.4866, 13.542, in: rect),
            control2: point(12.2294, 13.3855, in: rect)
        )
        path.addCurve(
            to: point(15.1667, 13.8276, in: rect),
            control1: point(13.7321, 13.3802, in: rect),
            control2: point(14.4761, 13.5316, in: rect)
        )
        path.addCurve(
            to: point(16.9961, 15.1038, in: rect),
            control1: point(15.8573, 14.1236, in: rect),
            control2: point(16.4799, 14.5579, in: rect)
        )
        return path
    }
}

private struct ReadAloudBookShape: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(20.9161, 19.73, in: rect))
        path.addLine(to: point(17.8867, 19.73, in: rect))
        path.addCurve(
            to: point(15.9233, 19.8685, in: rect),
            control1: point(16.8823, 19.73, in: rect),
            control2: point(16.3791, 19.73, in: rect)
        )
        path.addCurve(
            to: point(14.8192, 20.4595, in: rect),
            control1: point(15.5197, 19.991, in: rect),
            control2: point(15.145, 20.1917, in: rect)
        )
        path.addCurve(
            to: point(13.615, 22.0157, in: rect),
            control1: point(14.4511, 20.762, in: rect),
            control2: point(14.1722, 21.1799, in: rect)
        )
        path.addLine(to: point(13, 22.9382, in: rect))
        path.addLine(to: point(12.3781, 22.0055, in: rect))
        path.addCurve(
            to: point(11.1818, 20.4595, in: rect),
            control1: point(11.8255, 21.1765, in: rect),
            control2: point(11.5484, 20.7608, in: rect)
        )
        path.addCurve(
            to: point(10.0759, 19.8685, in: rect),
            control1: point(10.8559, 20.1917, in: rect),
            control2: point(10.4794, 19.991, in: rect)
        )
        path.addCurve(
            to: point(8.11346, 19.73, in: rect),
            control1: point(9.61998, 19.73, in: rect),
            control2: point(9.1179, 19.73, in: rect)
        )
        path.addLine(to: point(5.08398, 19.73, in: rect))
        return path
    }
}

nonisolated private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(
        x: rect.minX + rect.width * (x / 26),
        y: rect.minY + rect.height * (y / 30)
    )
}

private struct CoverGlyphBadge: View {
    let systemName: String
    @Environment(\.hearth) private var hearth

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(hearth.readableOnEmber)
            .frame(width: 20, height: 20)
            .background {
                Circle().fill(hearth.ember)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            }
    }
}

struct ShelfCoverCell: View {
    let book: Book
    var width: CGFloat
    var cellRatio: CGFloat?
    var showsProgress = true

    var body: some View {
        let resolvedRatio = cellRatio ?? book.hearthCoverRatio
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            CoverTile(book: book, width: width, showsProgress: showsProgress)
        }
        .frame(width: width, height: width * resolvedRatio, alignment: .bottom)
    }
}
