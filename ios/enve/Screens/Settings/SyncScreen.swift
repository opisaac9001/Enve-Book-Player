import SwiftUI

struct SyncScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var profileSession
    private var session: ProfileSession { profileSession ?? .owner }
    private var coordinator: SyncCoordinator { session.sync }
    @State private var isManualSyncing = false

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & storage",
            title: "Sync",
            subtitle: "Keep reading and listening progress in step across your Apple devices."
        ) {
            SourcesCard {
                SourcesToggleRow(
                    title: "Sync progress with iCloud",
                    subtitle: coordinator.isCloudKitAvailable ? nil : "iCloud isn't available right now.",
                    isOn: Binding(
                        get: { coordinator.syncEnabled },
                        set: { coordinator.setSyncEnabled($0) }
                    )
                )

                SourcesToggleRow(
                    title: "Sync to Apple TV",
                    subtitle: "Share your server connections with Enve on Apple TV.",
                    isOn: Binding(
                        get: { ServerConnectionCloudKitSync.shared.isEnabled },
                        set: { ServerConnectionCloudKitSync.shared.isEnabled = $0 }
                    )
                )

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if coordinator.isSyncing || isManualSyncing {
                            Text("Syncing…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        } else if let date = coordinator.lastSyncDate {
                            Text("Last synced \(date.formatted(.relative(presentation: .named)))")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        } else {
                            Text("Not synced yet")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        if coordinator.pendingSyncCount > 0 {
                            Text("\(coordinator.pendingSyncCount) waiting to send")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                        if let device = coordinator.lastSyncDeviceName, !device.isEmpty {
                            Text("From \(device)")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                    Spacer()
                    QuietButton(title: "Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        guard !isManualSyncing else { return }
                        isManualSyncing = true
                        Task {
                            await coordinator.manualSync()
                            isManualSyncing = false
                        }
                    }
                }
            }

            PendingSyncRecoverySection(session: session)
        }
        .accessibilityIdentifier("sync-screen")
    }
}

private struct PendingSyncRecoverySection: View {
    let session: ProfileSession

    @Environment(\.hearth) private var hearth
    @State private var destinations: [String: Destination] = [:]
    @State private var lookedUpIds: Set<String> = []
    @State private var retryingIds: Set<String> = []
    @State private var pendingDiscard: PendingServerSync?
    @State private var notice: String?

    private struct Destination {
        let title: String
        let server: String
    }

    private var entries: [PendingServerSync] {
        session.pendingSync.entries.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.stableId < $1.stableId : $0.updatedAt > $1.updatedAt
        }
    }

    var body: some View {
        SourcesCard {
            Overline("Waiting to send")
            if !session.serverSyncEnabled {
                Text("Server sync is off for this profile. Updates stay on this device and send once it's turned back on.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusWarn)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-pending-disabled")
            }
            if let notice {
                Text(notice)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-pending-notice")
            }
            if entries.isEmpty {
                Text("Nothing is waiting to send. New reading and listening updates will appear here if delivery needs attention.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-pending-empty")
            } else {
                ForEach(entries, id: \.stableId) { entry in
                    row(for: entry)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-pending-section")
        .task(id: entries.map(\.stableId)) {
            await loadDestinations(for: entries)
        }
        .confirmationDialog(
            "Discard this update?",
            isPresented: Binding(get: { pendingDiscard != nil }, set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible,
            presenting: pendingDiscard
        ) { entry in
            Button("Discard update", role: .destructive) { discard(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("Enve will stop sending this position to \(destination(for: entry).server). Progress on this device and your reading history stay as they are.")
        }
    }

    private func row(for entry: PendingServerSync) -> some View {
        let destination = destination(for: entry)
        let status = entry.deliveryStatus()
        return VStack(alignment: .leading, spacing: 6) {
            Text(destination.title)
                .font(.hearthBody.weight(.medium))
                .foregroundStyle(hearth.text)
                .lineLimit(3)
            Text("\(progressDescription(for: entry)) · To \(destination.server)")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Saved \(Date(timeIntervalSince1970: entry.updatedAt).formatted(date: .abbreviated, time: .shortened))")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textTertiary)
            statusText(status, isRetrying: retryingIds.contains(entry.stableId))
            actions(for: entry, status: status)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sync-pending-row-\(entry.stableId)")
    }

    private func statusText(_ status: PendingSyncDeliveryStatus, isRetrying: Bool) -> some View {
        let (text, color) = statusCopy(status, isRetrying: isRetrying)
        return Text(text)
            .font(.hearthCaption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func statusCopy(_ status: PendingSyncDeliveryStatus, isRetrying: Bool) -> (String, Color) {
        if isRetrying { return ("Sending now…", hearth.textSecondary) }
        switch status {
        case .waiting:
            return ("Waiting to send.", hearth.textSecondary)
        case .retrying(let failure, let nextAttempt?):
            return ("\(failure.message) Trying again \(nextAttempt.formatted(.relative(presentation: .named))).", hearth.statusWarn)
        case .retrying(let failure, nil):
            return ("\(failure.message) Enve will try again on the next sync.", hearth.statusWarn)
        case .authentication:
            return ("The server needs you to sign in again. Reconnect it in Sources to resume sending.", hearth.statusWarn)
        case .conflict:
            return ("The server has newer progress than this download. Open the book to choose which position to keep; nothing is overwritten until you decide.", hearth.statusWarn)
        case .validation(let message):
            return ("\(message) Move to a different spot in the book to send a new position, or discard this update.", hearth.statusError)
        }
    }

    private func actions(for entry: PendingServerSync, status: PendingSyncDeliveryStatus) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons(for: entry, status: status) }
            VStack(alignment: .leading, spacing: 10) { actionButtons(for: entry, status: status) }
        }
    }

    @ViewBuilder
    private func actionButtons(for entry: PendingServerSync, status: PendingSyncDeliveryStatus) -> some View {
        if !isValidation(status) {
            let canRetry = session.serverSyncEnabled && !retryingIds.contains(entry.stableId)
            QuietButton(title: "Retry now", systemImage: "arrow.clockwise") { retry(entry) }
                .disabled(!canRetry)
                .opacity(canRetry ? 1 : 0.5)
                .accessibilityIdentifier("sync-pending-retry-\(entry.stableId)")
        }
        if status != .conflict {
            QuietButton(title: "Discard", systemImage: "trash") { pendingDiscard = entry }
                .accessibilityIdentifier("sync-pending-discard-\(entry.stableId)")
        }
    }

    private func isValidation(_ status: PendingSyncDeliveryStatus) -> Bool {
        if case .validation = status { return true }
        return false
    }

    private func retry(_ entry: PendingServerSync) {
        guard session.serverSyncEnabled else { return }
        guard session.pendingSync.retryNow(entry) else {
            notice = staleNotice(for: entry)
            return
        }
        notice = nil
        retryingIds.insert(entry.stableId)
        Task {
            await session.sync.flushPendingSyncs()
            retryingIds.remove(entry.stableId)
        }
    }

    private func discard(_ entry: PendingServerSync) {
        pendingDiscard = nil
        notice = session.pendingSync.discard(entry) ? nil : staleNotice(for: entry)
    }

    private func staleNotice(for entry: PendingServerSync) -> String {
        let title = destination(for: entry).title
        guard let current = session.pendingSync.entries[entry.stableId] else {
            return "\(title) already finished sending."
        }
        guard current.isSameCheckpoint(as: entry) else {
            return "\(title) saved newer progress, so the update you picked was left alone."
        }
        return switch current.deliveryStatus() {
        case .conflict: "The server has newer progress for \(title). Open the book to choose which position to keep."
        case .validation: "\(title) can't be retried until a new position is saved."
        default: "\(title) couldn't be updated. Try again."
        }
    }

    private func progressDescription(for entry: PendingServerSync) -> String {
        if entry.domain.usesEbookProgress {
            return "Ebook \((entry.progress ?? 0).formatted(.percent.precision(.fractionLength(0))))"
        }
        let position = Duration.seconds(entry.position).formatted(.time(pattern: .hourMinuteSecond))
        guard entry.duration > 0 else { return "Audiobook \(position)" }
        return "Audiobook \(position) of \(Duration.seconds(entry.duration).formatted(.time(pattern: .hourMinuteSecond)))"
    }

    private func destination(for entry: PendingServerSync) -> Destination {
        destinations[entry.stableId] ?? Destination(
            title: lookedUpIds.contains(entry.stableId) ? "Book no longer in library" : "Loading…",
            server: serverName(providerId: nil, backendId: entry.backendId)
        )
    }

    private func loadDestinations(for entries: [PendingServerSync]) async {
        let ids = Set(entries.map(\.stableId))
        let books = await session.bookStore.booksByStableIds(ids)
        guard !Task.isCancelled else { return }
        lookedUpIds = ids
        destinations = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            guard let book = books[entry.stableId] else { return nil }
            return (entry.stableId, Destination(
                title: book.title,
                server: serverName(providerId: book.providerId, backendId: book.backendId ?? entry.backendId)
            ))
        })
    }

    // Connection names can be a bare host, IP, or URL; never surface a server address here.
    private func serverName(providerId: UUID?, backendId: String?) -> String {
        let connections = session.providerConnections.connections
        let connection = connections.first { $0.id == providerId }
            ?? connections.first { $0.id.uuidString.caseInsensitiveCompare(backendId ?? "") == .orderedSame }
        guard let connection else { return "your library server" }
        let name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeAddress = name.isEmpty || name.contains("://") || name.contains("/")
            || (!name.contains(" ") && (name.contains(".") || name.contains(":")))
        return looksLikeAddress ? "your library server" : name
    }
}
