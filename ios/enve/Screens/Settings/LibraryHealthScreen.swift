import SwiftUI

struct LibraryHealthScreen: View {
    @Environment(\.hearth) private var hearth
    @State private var model = LibraryHealthModel()

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & storage",
            title: "Library Health",
            subtitle: "A quiet check on your sources, sync, downloads, and this phone."
        ) {
            if let snapshot = model.snapshot {
                overallCard(snapshot)
                sourcesCard(snapshot)
                activityCard(snapshot)
                systemHealthCard(snapshot)
            } else {
                loadingCard
            }
        }
        .accessibilityIdentifier("library-health-screen")
        .task { await model.load() }
    }

    private var loadingCard: some View {
        SourcesCard {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(hearth.ember)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Checking the shelves…")
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text("Reading local status only. Nothing private leaves this phone.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    private func overallCard(_ snapshot: LibraryHealthSnapshot) -> some View {
        SourcesCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusSymbol(snapshot.level))
                    .font(.hearthUI(24, weight: .semibold))
                    .foregroundStyle(statusColor(snapshot.level))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(statusColor(snapshot.level).opacity(0.14)))

                VStack(alignment: .leading, spacing: 5) {
                    Overline("Library check", color: statusColor(snapshot.level))
                        .accessibilityHidden(true)
                    Text(statusTitle(snapshot.level))
                        .font(.hearthDisplay(24, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .accessibilityHidden(true)
                    Text(statusDetail(snapshot))
                        .font(.hearthBody.weight(.bold))
                        .foregroundStyle(hearth.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("library-health-overall-status")
            .accessibilityLabel(statusTitle(snapshot.level))
            .accessibilityValue(statusDetail(snapshot))

            Rectangle().fill(hearth.hairline).frame(height: 1)

            HStack(spacing: 20) {
                healthMetric(value: snapshot.totalBooks.formatted(), label: "cached books")
                healthMetric(value: relative(snapshot.checkedAt), label: "last checked")
            }

            EmberButton(
                title: model.isRunningCheck ? "Checking…" : "Check now",
                systemImage: model.isRunningCheck ? nil : "arrow.triangle.2.circlepath",
                tint: nil
            ) {
                Task { await model.runCheck() }
            }
            .disabled(model.isRunningCheck)
            .accessibilityIdentifier("library-health-check-now")
            .accessibilityLabel(model.isRunningCheck ? "Checking library health" : "Check library health now")
            .accessibilityHint("Refreshes connected sources and progress sync, then updates this screen.")
        }
    }

    private func sourcesCard(_ snapshot: LibraryHealthSnapshot) -> some View {
        SourcesCard {
            Overline("Sources")
            if snapshot.sources.isEmpty {
                Text("No sources are connected yet. Add one from Settings to light the first shelf.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(snapshot.sources) { source in
                    NavigationLink {
                        SourceDetailScreen(connectionId: source.id)
                    } label: {
                        sourceRow(source)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }

    private func sourceRow(_ source: LibraryHealthSourceStatus) -> some View {
        HStack(spacing: 12) {
            SourcesProviderLogo(
                assetName: source.type.assetIconName,
                systemName: source.type.iconName,
                size: 38
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.hearthBody.weight(.medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                Text(sourceDetail(source))
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: sourceSymbol(source.health))
                .foregroundStyle(sourceColor(source.health))
                .accessibilityHidden(true)
            Image(systemName: "chevron.right")
                .font(.hearthUI(12, weight: .semibold))
                .foregroundStyle(hearth.textTertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.name), \(sourceStatus(source.health))")
        .accessibilityValue("\(source.bookCount.formatted()) cached books. \(sourceVerification(source.lastVerified)).")
    }

    private func activityCard(_ snapshot: LibraryHealthSnapshot) -> some View {
        SourcesCard {
            Text("ACTIVITY & STORAGE")
                .font(.hearthUI(13, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(hearth.text)
                .accessibilityAddTraits(.isHeader)
            NavigationLink {
                SyncScreen()
            } label: {
                SettingsLinkRow(
                    title: "Progress sync",
                    subtitle: syncSubtitle(snapshot),
                    detail: snapshot.pendingSyncCount > 0 ? "\(snapshot.pendingSyncCount) waiting" : nil,
                    systemImage: "icloud.and.arrow.up.fill"
                )
            }
            .buttonStyle(PressableStyle())

            NavigationLink {
                DownloadsScreen()
            } label: {
                SettingsLinkRow(
                    title: "Downloads",
                    subtitle: downloadsSubtitle(snapshot),
                    detail: snapshot.failedDownloadCount > 0 ? "Needs attention" : nil,
                    systemImage: "arrow.down.circle.fill"
                )
            }
            .buttonStyle(PressableStyle())

            NavigationLink {
                StorageScreen()
            } label: {
                SettingsLinkRow(
                    title: "On this phone",
                    subtitle: "\(bytes(snapshot.downloadedBytes)) downloaded · \(bytes(snapshot.availableBytes)) free",
                    systemImage: "internaldrive.fill"
                )
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func systemHealthCard(_ snapshot: LibraryHealthSnapshot) -> some View {
        SourcesCard {
            Overline("Private system health")
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: snapshot.recentSystemIncidentCount == 0 ? "checkmark.shield.fill" : "waveform.path.ecg")
                    .font(.hearthUI(18, weight: .medium))
                    .foregroundStyle(snapshot.recentSystemIncidentCount == 0 ? hearth.statusOK : hearth.statusWarn)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(hearth.hairline))
                VStack(alignment: .leading, spacing: 4) {
                    Text(systemHealthTitle(snapshot))
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                    Text(systemHealthDetail(snapshot))
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)

            Text("Enve keeps only incident counts and dates. Call stacks, library details, server addresses, and account data are never shown or stored here.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func healthMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.hearthCaption)
                .foregroundStyle(hearth.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusTitle(_ level: LibraryHealthLevel) -> String {
        switch level {
        case .ready: "Your library is healthy"
        case .notice: "Ready, with a small note"
        case .attention: "A few things need attention"
        }
    }

    private func statusDetail(_ snapshot: LibraryHealthSnapshot) -> String {
        switch snapshot.level {
        case .ready:
            "Sources, progress, downloads, and local storage look ready."
        case .notice:
            snapshot.sources.isEmpty
                ? "Connect a source to begin filling the shelves."
                : "Your books remain available while Enve finishes a little background work."
        case .attention:
            "Your books stay in place. Open the marked section below to put things right."
        }
    }

    private func statusSymbol(_ level: LibraryHealthLevel) -> String {
        switch level {
        case .ready: "checkmark.seal.fill"
        case .notice: "info.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ level: LibraryHealthLevel) -> Color {
        switch level {
        case .ready: hearth.statusOK
        case .notice: hearth.ember
        case .attention: hearth.statusWarn
        }
    }

    private func sourceSymbol(_ health: LibrarySourceHealth) -> String {
        switch health {
        case .ready: "checkmark.circle.fill"
        case .disconnected: "wifi.slash"
        case .needsSignIn: "person.crop.circle.badge.exclamationmark"
        }
    }

    private func sourceColor(_ health: LibrarySourceHealth) -> Color {
        health == .ready ? hearth.statusOK : hearth.statusWarn
    }

    private func sourceStatus(_ health: LibrarySourceHealth) -> String {
        switch health {
        case .ready: "ready"
        case .disconnected: "not connected"
        case .needsSignIn: "sign-in needed"
        }
    }

    private func sourceDetail(_ source: LibraryHealthSourceStatus) -> String {
        "\(source.bookCount.formatted()) cached · \(sourceVerification(source.lastVerified))"
    }

    private func sourceVerification(_ date: Date?) -> String {
        guard let date else { return "not verified yet" }
        return "verified \(relative(date))"
    }

    private func syncSubtitle(_ snapshot: LibraryHealthSnapshot) -> String {
        guard snapshot.syncEnabled else { return "Sync across devices is off" }
        if snapshot.pendingSyncCount > 0 {
            return "\(snapshot.pendingSyncCount) progress update\(snapshot.pendingSyncCount == 1 ? "" : "s") waiting to send"
        }
        guard let date = snapshot.lastSyncDate else { return "Ready for the first sync" }
        return "Last synced \(relative(date))"
    }

    private func downloadsSubtitle(_ snapshot: LibraryHealthSnapshot) -> String {
        var details: [String] = []
        if snapshot.activeDownloadCount > 0 { details.append("\(snapshot.activeDownloadCount) active") }
        if snapshot.failedDownloadCount > 0 { details.append("\(snapshot.failedDownloadCount) failed") }
        if snapshot.orphanDownloadCount > 0 { details.append("\(snapshot.orphanDownloadCount) needs a library match") }
        return details.isEmpty ? "Downloaded books and the transfer queue look ready" : details.joined(separator: " · ")
    }

    private func systemHealthTitle(_ snapshot: LibraryHealthSnapshot) -> String {
        snapshot.recentSystemIncidentCount == 0
            ? "No recent system incidents"
            : "\(snapshot.recentSystemIncidentCount) recent system incident\(snapshot.recentSystemIncidentCount == 1 ? "" : "s")"
    }

    private func systemHealthDetail(_ snapshot: LibraryHealthSnapshot) -> String {
        var details: [String] = []
        if let date = snapshot.lastSystemIncidentAt { details.append("Last incident \(relative(date))") }
        if let date = snapshot.lastMetricReportAt { details.append("Performance report \(relative(date))") }
        if details.isEmpty { return "On-device performance reporting is active. Reports arrive when iOS has something to share." }
        return details.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
