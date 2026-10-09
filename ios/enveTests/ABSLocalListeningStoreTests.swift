import Foundation
import Testing

@testable import enve

@MainActor
struct ABSLocalListeningStoreTests {
    private func makeStore() -> ABSLocalListeningStore {
        let suite = "ABSLocalListeningStoreTests.\(UUID().uuidString)"
        return ABSLocalListeningStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private func record(_ store: ABSLocalListeningStore, connection: UUID, seconds: TimeInterval, at date: Date) {
        store.record(
            connectionId: connection,
            libraryItemId: "item-1",
            episodeId: nil,
            displayTitle: "Title",
            displayAuthor: "Author",
            duration: 3600,
            currentTime: 120,
            listened: seconds,
            now: date
        )
    }

    @Test func sameDayListeningAccumulatesIntoOneSession() {
        let store = makeStore()
        let connection = UUID()
        let now = Date()
        record(store, connection: connection, seconds: 42, at: now)
        record(store, connection: connection, seconds: 8, at: now.addingTimeInterval(10))

        let pending = store.pendingUploads(connectionId: connection)
        #expect(pending.count == 1)
        #expect(pending.first?.timeListening == 50)
    }

    @Test func uploadOnlyAcknowledgesTheSentVersion() {
        let store = makeStore()
        let connection = UUID()
        let now = Date()
        record(store, connection: connection, seconds: 10, at: now)
        let sent = store.pendingUploads(connectionId: connection)
        record(store, connection: connection, seconds: 5, at: now.addingTimeInterval(5))

        store.markUploaded(sent)
        #expect(store.pendingUploads(connectionId: connection).first?.timeListening == 15)

        store.markUploaded(store.pendingUploads(connectionId: connection))
        #expect(store.pendingUploads(connectionId: connection).isEmpty)
    }

    @Test func connectionsAreKeptApart() {
        let store = makeStore()
        let first = UUID()
        record(store, connection: first, seconds: 10, at: Date())

        #expect(store.pendingUploads(connectionId: UUID()).isEmpty)
        store.discard(ids: Set(store.pendingUploads(connectionId: first).map(\.id)))
        #expect(store.pendingUploads(connectionId: first).isEmpty)
    }

    @Test func listeningSessionDecodesDeviceAndItem() throws {
        let json = """
            {"id":"s1","libraryItemId":"li_1","timeListening":12.5,"date":"2026-10-02",
             "startedAt":1790427074652,"updatedAt":1790427081660,
             "deviceInfo":{"deviceId":"device-a","clientName":"Enve"}}
            """
        let session = try JSONDecoder().decode(
            AudiobookshelfListeningStats.AudiobookshelfSession.self,
            from: Data(json.utf8)
        )
        #expect(session.libraryItemId == "li_1")
        #expect(session.date == "2026-10-02")
        #expect(session.deviceInfo?.deviceId == "device-a")
        #expect(!JournalEngine.isThisDevice(session))
    }
}
