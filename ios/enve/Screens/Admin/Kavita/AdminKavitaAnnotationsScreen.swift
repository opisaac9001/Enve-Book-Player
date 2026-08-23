import SwiftUI
import UIKit

struct AdminKavitaAnnotationsScreen: View {
    let model: AdminKavitaModel

    @Environment(\.hearth) private var hearth

    @State private var items: [KavitaProvider.Annotation] = []
    @State private var search = ""
    @State private var page = 1
    @State private var exhausted = false
    @State private var isLoading = false
    @State private var unavailable = false
    @State private var exportFile: AdminKavitaExportFile?

    private static let pageSize = 50

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Highlights & notes") {
            if unavailable {
                AdminEmptyText("This Kavita server doesn't publish annotations.")
            } else {
                searchField
                exportRow
                if filtered.isEmpty {
                    AdminEmptyText(isLoading ? "Gathering the margins…" : "Nothing in the margins yet.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered) { item in
                            SourcesCard {
                                entry(item)
                            }
                            .onAppear {
                                guard item.id == items.last?.id else { return }
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                if isLoading && !items.isEmpty {
                    AdminLoadingRow("Turning the page…")
                }
            }
        }
        .task {
            guard items.isEmpty, !unavailable else { return }
            await loadMore()
        }
        .sheet(item: $exportFile) { file in
            AdminKavitaShareSheet(items: [file.url])
        }
    }

    private var filtered: [KavitaProvider.Annotation] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.text.localizedCaseInsensitiveContains(needle)
                || ($0.note ?? "").localizedCaseInsensitiveContains(needle)
                || ($0.seriesName ?? "").localizedCaseInsensitiveContains(needle)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Search highlights and notes", text: $search)
                .font(.hearthUI(15))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    private var exportRow: some View {
        HStack(spacing: 10) {
            Text("\(filtered.count) \(filtered.count == 1 ? "highlight" : "highlights") loaded")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
            Spacer()
            Menu {
                ForEach(AdminKavitaExportFormat.allCases, id: \.rawValue) { format in
                    Button(format.rawValue.uppercased()) { export(format: format) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.hearthUI(16, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle()
                            .fill(hearth.bgElevated)
                            .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
            }
            .disabled(filtered.isEmpty)
            .accessibilityLabel("Export highlights")
        }
    }

    private func entry(_ item: KavitaProvider.Annotation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.text.isEmpty {
                Text("\u{201C}\(item.text)\u{201D}")
                    .font(.hearthDisplay(16))
                    .foregroundStyle(hearth.text)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = item.note {
                Text(note)
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(caption(item))
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.text
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
        }
    }

    private func caption(_ item: KavitaProvider.Annotation) -> String {
        var parts: [String] = []
        if let series = item.seriesName, !series.isEmpty { parts.append(series) }
        if let chapter = item.chapterTitle, !chapter.isEmpty { parts.append(chapter) }
        if item.pageNumber > 0 { parts.append("page \(item.pageNumber)") }
        if let created = item.createdAt {
            parts.append(created.formatted(.dateTime.month(.abbreviated).day().year()))
        }
        return parts.joined(separator: " · ")
    }

    private func loadMore() async {
        guard let provider = model.provider, !isLoading, !exhausted else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fetched = try await provider.fetchAnnotations(page: page, pageSize: Self.pageSize)
            let known = Set(items.map(\.id))
            let fresh = fetched.filter { !known.contains($0.id) }
            items.append(contentsOf: fresh)
            exhausted = fetched.count < Self.pageSize || fresh.isEmpty
            page += 1
        } catch KavitaProvider.InsightsError.unavailable {
            unavailable = true
            exhausted = true
        } catch {
            exhausted = true
        }
    }

    private func export(format: AdminKavitaExportFormat) {
        guard let url = AdminKavitaExport.write(filtered, format: format, server: model.connection.name) else { return }
        exportFile = AdminKavitaExportFile(url: url)
    }
}

struct AdminKavitaExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

enum AdminKavitaExportFormat: String, CaseIterable {
    case md
    case csv
    case json
}

enum AdminKavitaExport {
    static func write(_ items: [KavitaProvider.Annotation], format: AdminKavitaExportFormat, server: String) -> URL? {
        let body: String
        switch format {
        case .md: body = markdown(items, server: server)
        case .csv: body = csv(items)
        case .json: body = json(items)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("kavita-highlights.\(format.rawValue)")
        try? FileManager.default.removeItem(at: destination)
        guard let data = body.data(using: .utf8), (try? data.write(to: destination, options: .atomic)) != nil else {
            return nil
        }
        return destination
    }

    private static func markdown(_ items: [KavitaProvider.Annotation], server: String) -> String {
        var lines = ["# Highlights from \(server)", ""]
        for group in Dictionary(grouping: items, by: { $0.seriesName ?? "Unknown series" }).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(group.key)")
            lines.append("")
            for item in group.value {
                lines.append("> \(item.text)")
                if let note = item.note { lines.append("") ; lines.append(note) }
                lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func csv(_ items: [KavitaProvider.Annotation]) -> String {
        var rows = ["series,chapter,page,text,note,created"]
        for item in items {
            let fields = [
                item.seriesName ?? "",
                item.chapterTitle ?? "",
                String(item.pageNumber),
                item.text,
                item.note ?? "",
                item.createdUtc,
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func json(_ items: [KavitaProvider.Annotation]) -> String {
        let payload = items.map { item -> [String: Any] in
            [
                "id": item.id,
                "series": item.seriesName ?? "",
                "chapter": item.chapterTitle ?? "",
                "page": item.pageNumber,
                "text": item.text,
                "note": item.note ?? "",
                "created": item.createdUtc,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }
}

private struct AdminKavitaShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
