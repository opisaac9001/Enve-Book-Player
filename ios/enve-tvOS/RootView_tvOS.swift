import SwiftUI

struct RootView_tvOS: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: TVTab = .library

    enum TVTab: Hashable {
        case library
        case audiobooks
        case books
        case readTogether
        case settings
    }

    @State private var companionReceiver = CompanionReceiverService_tvOS.shared

    #if DEBUG
    @State private var debugDetailBook: Book?
    @State private var debugReadBook: Book?
    #endif

    private var companionSessionActive: Bool {
        if case .connected = companionReceiver.state { return true }
        return false
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryHomeView_tvOS()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(TVTab.library)

            AudiobookLibraryView_tvOS()
                .tabItem { Label("Audiobooks", systemImage: "headphones") }
                .tag(TVTab.audiobooks)

            EbookLibraryView_tvOS()
                .tabItem { Label("Books", systemImage: "text.book.closed.fill") }
                .tag(TVTab.books)

            ReadTogetherView_tvOS()
                .tabItem { Label("Read together", systemImage: "person.2.fill") }
                .tag(TVTab.readTogether)

            SettingsView_tvOS()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(TVTab.settings)
        }
        .miniPlayerOverlay()

        .fullScreenCover(isPresented: .constant(companionSessionActive)) {
            CompanionSessionView_tvOS()
        }
        #if DEBUG
        .fullScreenCover(item: $debugDetailBook) { book in
            NavigationStack { BookDetailView_tvOS(book: book) }
        }
        .fullScreenCover(item: $debugReadBook) { book in
            EbookReaderView_tvOS(book: book)
        }
        .task {
            await handleDebugLaunch()
        }
        #endif
    }

    #if DEBUG
    private func debugTrace(_ line: String) {
        let url = URL.documentsDirectory.appendingPathComponent("enve_tv_debug.txt")
        let stamped = "\(Date().formatted(date: .omitted, time: .standard)) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? stamped.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func handleDebugLaunch() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ key: String) -> String? {
            guard let index = args.firstIndex(of: key), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }

        if args.contains("-tvReadTogether") { selectedTab = .readTogether }
        switch value("-tvTab") {
        case "home": selectedTab = .library
        case "audiobooks": selectedTab = .audiobooks
        case "books": selectedTab = .books
        case "settings": selectedTab = .settings
        default: break
        }

        if let urlString = value("-tvConnectURL"),
            let typeRaw = value("-tvConnectType"),
            let type = ProviderType(rawValue: typeRaw),
            !appState.providerConnections.connections.contains(where: { $0.url == urlString && $0.type == type && !$0.isArchived })
        {
            var connection = ServerConnection(
                name: typeRaw.capitalized,
                url: urlString,
                type: type,
                username: value("-tvConnectUser"),
                password: value("-tvConnectPassword"),
                token: nil
            )
            if let provider = PluginRegistry.shared.makeLibraryProvider(for: connection),
                (try? await provider.validateConnection()) == true
            {
                connection = provider.connection
                connection.isConnected = true
                connection.lastVerified = Date()
                appState.providerConnections.connections.append(connection)
                await LibraryCatalogCoordinator.shared.refreshLibrary()
            }
        }

        func findBook(_ needle: String, mediaType: AppMediaType?) async -> Book? {
            let rawType: String? =
                switch mediaType {
                case .audiobook: "audiobook"
                case .ebook: "ebook"
                default: nil
                }
            for _ in 0..<45 {
                let books = await appState.bookStore.pagedBooks(offset: 0, limit: 1000, mediaType: rawType)
                if let match = needle.isEmpty
                    ? books.first
                    : books.first(where: { $0.title.localizedCaseInsensitiveContains(needle) })
                {
                    return match
                }
                try? await Task.sleep(for: .seconds(1))
            }
            return nil
        }

        if args.contains("-tvAutoPlay") {
            let needle = value("-tvAutoPlay") ?? ""
            if let book = await findBook(needle, mediaType: .audiobook) {
                debugTrace("autoplay: found '\(book.title)' source=\(book.source.rawValue)")
                PlayerViewModel.shared.play(book: book)
                try? await Task.sleep(for: .seconds(4))
                let vm = PlayerViewModel.shared
                debugTrace("autoplay: current=\(vm.currentBook?.title ?? "nil") playing=\(vm.isPlaying) err=\(ActivePlayback.controller.snapshot.errorDescription ?? "nil")")
            } else {
                debugTrace("autoplay: no match for '\(needle)' among \(appState.allBooks.count) books")
            }
        }
        if let needle = value("-tvOpenBook"), let book = await findBook(needle, mediaType: nil) {
            debugDetailBook = book
        }
        if let needle = value("-tvReadBook"), let book = await findBook(needle, mediaType: .ebook) {
            debugReadBook = book
        }
    }
    #endif
}
