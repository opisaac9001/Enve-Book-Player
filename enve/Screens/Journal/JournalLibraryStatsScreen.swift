import SwiftUI

struct JournalLibraryStatsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = JournalLibraryStatsModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    JournalScreenHeader(overline: "The whole collection", title: "Library")
                    Text("What the shelves hold. Your own reading stays in the journal.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                .padding(.horizontal, 24)

                if let snap = model.snapshot, snap.totalBooks > 0 {
                    content(snap)
                } else if model.isLoading {
                    JournalLoadingNote(text: "Counting the shelves…")
                        .padding(.horizontal, 24)
                } else {
                    JournalQuietNote(text: "Nothing on the shelves yet. Connect a source and the counting begins.")
                        .padding(.horizontal, 24)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.load(force: true) }
        .task { await model.load() }
    }

    @ViewBuilder
    private func content(_ snap: JournalLibrarySnapshot) -> some View {
        kpiStrip(snap)

        VStack(alignment: .leading, spacing: 20) {
            if snap.totalAudioSeconds > 0 {
                audioHero(snap)
            }
            if !snap.seriesCompletion.isEmpty {
                seriesCompletionCard(snap)
            }
            if !snap.formatBreakdown.isEmpty {
                countsCard("Formats", items: snap.formatBreakdown)
            }
            if !snap.topGenres.isEmpty {
                countsCard("Top genres", items: snap.topGenres)
            }
            if !snap.languageBreakdown.isEmpty {
                countsCard("Languages", items: snap.languageBreakdown)
            }
            if !snap.decadeHistogram.isEmpty {
                decadesCard(snap)
            }
            if snap.pubYearTimeline.count > 1 {
                timelineCard(snap)
            }
            if !snap.addedOverTime.isEmpty {
                addedCard(snap)
            }
            if !snap.topAuthors.isEmpty {
                countsCard("Top authors", items: snap.topAuthors, ranked: true)
            }
            if !snap.topNarrators.isEmpty {
                countsCard("Top narrators", items: snap.topNarrators, ranked: true)
            }
            if !snap.topSeries.isEmpty {
                countsCard("Top series", items: snap.topSeries, ranked: true)
            }
            if !snap.longestBooks.isEmpty {
                longestCard(snap)
            }
            if !snap.acquisitionLag.isEmpty {
                lagCard(snap)
            }
            if !snap.completeness.isEmpty {
                completenessCard(snap)
            }
        }
        .padding(.horizontal, 24)
    }

    private func kpiStrip(_ snap: JournalLibrarySnapshot) -> some View {
        let publishedRange = snap.earliestYear.flatMap { lo in snap.latestYear.map { "\(lo)-\($0)" } } ?? "-"
        return ScrollView(.horizontal) {
            HStack(spacing: 10) {
                kpiTile(snap.totalBooks.formatted(), "Books")
                kpiTile(snap.totalAuthors.formatted(), "Authors")
                kpiTile(snap.totalSeries.formatted(), "Series")
                kpiTile(snap.totalPublishers.formatted(), "Publishers")
                kpiTile(snap.totalGenres.formatted(), "Genres")
                kpiTile(snap.totalLanguages.formatted(), "Languages")
                kpiTile(publishedRange, "Published")
                kpiTile("\(Int((snap.avgProgress * 100).rounded()))%", "Avg progress")
                kpiTile(snap.finishedCount.formatted(), "Finished")
                kpiTile(snap.inProgressCount.formatted(), "Underway")
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func kpiTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Overline(label, color: hearth.textTertiary)
        }
        .frame(width: 100, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    private func audioHero(_ snap: JournalLibrarySnapshot) -> some View {
        let hours = snap.totalAudioSeconds / 3600
        let days = snap.totalAudioSeconds / 86400
        return JournalCard("Hours on the shelves") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Int(hours).formatted())
                    .font(.hearthDisplay(40))
                    .foregroundStyle(hearth.text)
                Text("hours of audio")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.textSecondary)
            }
            Text("\(String(format: "%.1f", days)) days without pause · \(snap.audiobookCount.formatted()) audiobooks")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
        }
    }

    private func seriesCompletionCard(_ snap: JournalLibrarySnapshot) -> some View {
        JournalCard("Series, seen through") {
            VStack(spacing: 14) {
                ForEach(snap.seriesCompletion) { series in
                    JournalMeterRow(
                        label: series.name,
                        detail: "\(series.finished)/\(series.total)",
                        fraction: series.fraction,
                        tint: series.fraction >= 1 ? hearth.statusOK : nil
                    )
                }
            }
        }
    }

    private func countsCard(_ title: String, items: [JournalNamedCount], ranked: Bool = false) -> some View {
        let peak = max(Double(items.map(\.count).max() ?? 0), 0.001)
        return JournalCard(title) {
            VStack(spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    JournalMeterRow(
                        rank: ranked ? index + 1 : nil,
                        label: item.label,
                        detail: item.count.formatted(),
                        fraction: Double(item.count) / peak
                    )
                }
            }
        }
    }

    private func decadesCard(_ snap: JournalLibrarySnapshot) -> some View {
        let bins = snap.decadeHistogram
        let labelStride = bins.count > 8 ? 2 : 1
        return JournalCard("By decade of publication") {
            JournalColumns(
                columns: bins.enumerated().map { index, bin in
                    (label: index % labelStride == 0 ? bin.label : "", value: Double(bin.count))
                }
            )
        }
    }

    private func timelineCard(_ snap: JournalLibrarySnapshot) -> some View {
        JournalCard("Years of publication") {
            JournalSparkColumns(values: snap.pubYearTimeline.map { Double($0.count) })
            HStack {
                Text(snap.earliestYear.map(String.init) ?? "")
                Spacer()
                Text(snap.latestYear.map(String.init) ?? "")
            }
            .font(.hearthUI(10))
            .foregroundStyle(hearth.textTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                JournalStatTile(value: snap.peakYear.map(String.init) ?? "-", label: "Peak year")
                JournalStatTile(value: "\(snap.yearSpan)", label: "Year span")
                JournalStatTile(value: "\(snap.uniqueYears)", label: "Years held")
                JournalStatTile(value: snap.avgPerYear.formatted(), label: "Avg a year")
            }
        }
    }

    private func addedCard(_ snap: JournalLibrarySnapshot) -> some View {
        JournalCard("Brought in, over time") {
            JournalSparkColumns(values: snap.addedOverTime.map { Double($0.count) })
            HStack {
                Text(snap.addedOverTime.first.map { journalMonthLabel($0.date) } ?? "")
                Spacer()
                Text(snap.addedOverTime.last.map { journalMonthLabel($0.date) } ?? "")
            }
            .font(.hearthUI(10))
            .foregroundStyle(hearth.textTertiary)
        }
    }

    private func longestCard(_ snap: JournalLibrarySnapshot) -> some View {
        let peak = max(snap.longestBooks.map(\.seconds).max() ?? 0, 0.001)
        return JournalCard("The longest books") {
            VStack(spacing: 14) {
                ForEach(snap.longestBooks) { book in
                    JournalMeterRow(
                        label: book.title,
                        detail: String(format: "%.0f h", book.seconds / 3600),
                        fraction: book.seconds / peak
                    )
                }
            }
        }
    }

    private func lagCard(_ snap: JournalLibrarySnapshot) -> some View {
        JournalCard("Acquisition lag") {
            Text("When a book was published, against when it joined the shelves.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            JournalLagScatter(points: snap.acquisitionLag)
        }
    }

    private func completenessCard(_ snap: JournalLibrarySnapshot) -> some View {
        JournalCard("How complete the records are") {
            VStack(spacing: 14) {
                ForEach(snap.completeness) { stat in
                    JournalMeterRow(
                        label: stat.field,
                        detail: "\(Int((stat.fraction * 100).rounded()))%",
                        fraction: stat.fraction
                    )
                }
            }
        }
    }

    private func journalMonthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }
}

private struct JournalLagScatter: View {
    let points: [JournalLagPoint]

    @Environment(\.hearth) private var hearth

    var body: some View {
        let minX = Double(points.map(\.publishedYear).min() ?? 0)
        let maxX = Double(points.map(\.publishedYear).max() ?? 1)
        let minY = Double(points.map(\.addedYear).min() ?? 0)
        let maxY = Double(points.map(\.addedYear).max() ?? 1)
        let spanX = max(maxX - minX, 1)
        let spanY = max(maxY - minY, 1)
        let ember = hearth.ember

        VStack(spacing: 6) {
            Canvas { context, size in
                for point in points {
                    let x = (Double(point.publishedYear) - minX) / spanX * (size.width - 6) + 3
                    let y = size.height - ((Double(point.addedYear) - minY) / spanY * (size.height - 6) + 3)
                    let dot = CGRect(x: x - 2, y: y - 2, width: 4, height: 4)
                    context.fill(Path(ellipseIn: dot), with: .color(ember.opacity(0.55)))
                }
            }
            .frame(height: 180)
            HStack {
                Text("Published \(Int(minX))")
                Spacer()
                Text("\(Int(maxX))")
            }
            .font(.hearthUI(10))
            .foregroundStyle(hearth.textTertiary)
        }
    }
}
