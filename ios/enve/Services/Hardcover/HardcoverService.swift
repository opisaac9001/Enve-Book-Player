import Foundation
import Logging

public final class HardcoverService: Sendable {
    public static let shared = HardcoverService()

    private let baseURL = URL(string: "https://api.hardcover.app/v1/graphql")!
    private let userIdCache = UserIdCache()
    private let session: URLSession
    private let pacer: HardcoverRequestPacer
    private let tokenProvider: @MainActor @Sendable () -> String?

    @TaskLocal static var syncToken: String?

    init(session: URLSession = .shared, pacer: HardcoverRequestPacer = .shared, tokenProvider: @escaping @MainActor @Sendable () -> String? = { SettingsManager.shared.hardcoverApiKey }) {
        self.session = session
        self.pacer = pacer
        self.tokenProvider = tokenProvider
    }

    private func cachedUserId() async throws -> Int {
        guard let token = tokenProvider() else { throw HardcoverError.noApiKey }
        if let id = await userIdCache.get(token: token) { return id }
        let user = try await getCurrentUser()
        guard let id = user.id, tokenProvider() == token else { throw HardcoverError.invalidResponse }
        await userIdCache.set(id, token: token)
        return id
    }

    public typealias Book = HardcoverBook
    public typealias Author = HardcoverAuthor
    public typealias ReadingState = HardcoverReadingStatus
    public typealias UserBook = HardcoverUserBookLegacy
    public typealias UserInfo = HardcoverUserInfo

    public func getCurrentUser() async throws -> HardcoverUserInfo {
        let query = """
            query { me { id username } }
            """
        let response: MeResponse = try await performQuery(query)
        guard let user = response.me?.first else {
            throw HardcoverError.invalidResponse
        }
        return HardcoverUserInfo(username: user.username, id: user.id)
    }

    public func getUserProfile() async throws -> HardcoverUserProfile {
        let query = """
            query {
                me {
                    id
                    username
                    bio
                    flair
                    image { url }
                    user_books_aggregate { aggregate { count } }
                    followed_users_count
                    followers_count
                }
            }
            """
        let response: ProfileResponse = try await performQuery(query)
        guard let me = response.me?.first else {
            throw HardcoverError.invalidResponse
        }
        return HardcoverUserProfile(
            id: me.id,
            username: me.username,
            bio: me.bio,
            image: me.image,
            flair: me.flair,
            booksCount: me.userBooksAggregate?.aggregate?.count,
            followingCount: me.followedUsersCount,
            followersCount: me.followersCount
        )
    }

    public func getUserBooks(state: HardcoverReadingStatus? = nil, limit: Int = 50) async throws -> [HardcoverUserBookLegacy] {
        let stateFilter = state.map { ", status_id: {_eq: \($0.rawValue)}" } ?? ""
        let query = """
            query {
                me {
                    user_books(
                        limit: \(limit),
                        order_by: {updated_at: desc},
                        where: {_and: [{status_id: {_is_null: false}}\(stateFilter.isEmpty ? "" : ", {\(stateFilter.dropFirst(2))}")]}
                    ) {
                        id
                        book_id
                        rating
                        review
                        status_id
                        edition_id
                        book {
                            id title description release_year slug
                            cached_contributors
                            image { url }
                            contributions { author { id name } }
                        }
                        edition {
                            id title pages audio_seconds reading_format_id
                            isbn_10 isbn_13 edition_format
                            publisher { name }
                            image { url }
                        }
                        user_book_reads(order_by: {id: desc}, limit: 1) {
                            id started_at finished_at progress_pages progress_seconds edition_id
                            edition { id pages audio_seconds reading_format_id }
                        }
                    }
                }
            }
            """
        let response: UserBooksFullResponse = try await performQuery(query)
        guard let me = response.me?.first, let books = me.userBooks else {
            return []
        }
        return books.map { mapToLegacyUserBook($0) }
    }

    public func getUserBooksRich(status: HardcoverReadingStatus? = nil, limit: Int = 50) async throws -> [HardcoverUserBook] {
        let stateFilter = status.map { ", status_id: {_eq: \($0.rawValue)}" } ?? ""
        let query = """
            query {
                me {
                    user_books(
                        limit: \(limit),
                        order_by: {updated_at: desc},
                        where: {_and: [{status_id: {_is_null: false}}\(stateFilter.isEmpty ? "" : ", {\(stateFilter.dropFirst(2))}")]}
                    ) {
                        id book_id rating review status_id edition_id privacy_setting_id
                        book {
                            id title description release_year slug
                            cached_contributors users_count
                            image { url }
                        }
                        edition {
                            id title pages audio_seconds reading_format_id edition_format
                            isbn_10 isbn_13
                            publisher { name }
                            image { url }
                            users_count
                        }
                        user_book_reads(order_by: {id: desc}, limit: 1) {
                            id started_at finished_at progress_pages progress_seconds edition_id
                            edition { id pages audio_seconds reading_format_id }
                        }
                    }
                }
            }
            """
        let response: UserBooksRichResponse = try await performQuery(query)
        guard let me = response.me?.first, let books = me.userBooks else {
            return []
        }
        return books
    }

    public func getBookById(_ bookId: Int) async throws -> HardcoverBook {
        let query = """
            query {
                books(where: {id: {_eq: \(bookId)}}) {
                    id title description release_year slug
                    cached_contributors users_count
                    image { url }
                }
            }
            """
        let response: BooksQueryResponse = try await performQuery(query)
        guard let book = response.books?.first else {
            throw HardcoverError.invalidResponse
        }
        return book
    }

    public func getEditionsForBook(bookId: Int) async throws -> [HardcoverEdition] {
        let query = """
            query {
                editions(
                    where: {book_id: {_eq: \(bookId)}},
                    order_by: {users_count: desc_nulls_last}
                ) {
                    id title isbn_10 isbn_13 pages audio_seconds
                    reading_format_id edition_format release_date
                    publisher { name }
                    image { url }
                    users_count
                }
            }
            """
        let response: EditionsQueryResponse = try await performQuery(query)
        return response.editions ?? []
    }

    public func getEditionDetails(editionId: Int) async throws -> (pages: Int?, audioSeconds: Int?, editionFormat: String?) {
        let query = """
            query {
                editions(where: {id: {_eq: \(editionId)}}) {
                    id pages audio_seconds edition_format reading_format_id
                }
            }
            """
        let response: EditionsQueryResponse = try await performQuery(query)
        guard let edition = response.editions?.first else {
            return (nil, nil, nil)
        }
        return (edition.pages, edition.audioSeconds, edition.editionFormat)
    }

    public func searchBooks(query searchText: String, limit: Int = 20) async throws -> [HardcoverBook] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let escaped = trimmed.graphQLEscaped
        let searchQuery = """
            query {
                search(query: "\(escaped)", query_type: "Book", per_page: \(limit), page: 1) {
                    results
                }
            }
            """
        let response: SearchResponse = try await performQuery(searchQuery)
        guard let hits = response.search?.results?.hits else { return [] }

        return hits.map { hit in
            HardcoverBook(
                id: Int(hit.document.id) ?? 0,
                title: hit.document.title,
                description: hit.document.description,
                releaseYear: hit.document.releaseYear,
                slug: hit.document.slug,
                image: hit.document.image,
                cachedContributors: FlexibleContributors(hit.document.authorNames?.joined(separator: ", ")),
                usersCount: nil
            )
        }
    }

    public func getBooksByAudibleASIN(_ asin: String) async throws -> [HardcoverBook] {
        let normalizedASIN = asin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalizedASIN.count == 10,
            normalizedASIN.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else {
            return []
        }

        let query = """
            query {
                editions(where: {asin: {_eq: "\(normalizedASIN)"}}, limit: 10) {
                    book {
                        id title description release_year slug cached_contributors users_count
                        image { url }
                    }
                }
            }
            """
        let response: EditionBookLookupResponse = try await performQuery(query)
        var seenBookIds = Set<Int>()
        return (response.editions ?? [])
            .map(\.book)
            .filter { seenBookIds.insert($0.id).inserted }
    }

    public func searchUsers(query searchText: String) async throws -> [HardcoverUserSearchResult] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let query = """
            query {
                users(
                    where: {username: {_ilike: "%\(trimmed.graphQLEscaped)%"}},
                    limit: 20
                ) {
                    id username flair image { url }
                }
            }
            """
        let response: UserSearchResponse = try await performQuery(query)
        return (response.users ?? []).map { user in
            HardcoverUserSearchResult(
                id: user.id,
                username: user.username,
                name: nil,
                imageURL: user.image?.url,
                flair: user.flair
            )
        }
    }

    func findEdition(identifiers: HardcoverIdentifiers) async throws -> HardcoverIdentifierEdition? {
        guard !identifiers.isEmpty else { return nil }
        var filters: [[String: Any]] = []
        if let isbn = identifiers.isbn {
            filters.append([isbn.count == 10 ? "isbn_10" : "isbn_13": ["_eq": isbn]])
        }
        if let asin = identifiers.asin { filters.append(["asin": ["_eq": asin]]) }
        let query = """
            query EditionsByIdentifier($where: editions_bool_exp!) {
                editions(where: $where, limit: 20) {
                    id book_id isbn_10 isbn_13 asin pages
                    book { id title cached_contributors image { url } }
                }
            }
            """
        struct Response: Decodable { let editions: [HardcoverIdentifierEdition] }
        let response: Response = try await performQuery(query, variables: ["where": ["_or": filters]])
        return try HardcoverIdentifierEdition.select(response.editions, identifiers: identifiers)
    }

    public func getUserBook(bookId: Int) async throws -> HardcoverUserBook? {
        let query = """
            query {
                me {
                    user_books(where: {book_id: {_eq: \(bookId)}}, limit: 1) {
                        id book_id rating review status_id edition_id privacy_setting_id
                        book { id title cached_contributors image { url } }
                        edition { id title pages audio_seconds reading_format_id edition_format }
                        user_book_reads(order_by: {id: desc}, limit: 1) {
                            id started_at finished_at progress_pages progress_seconds edition_id
                            edition { id pages audio_seconds reading_format_id }
                        }
                    }
                }
            }
            """
        let response: UserBooksRichResponse = try await performQuery(query)
        return response.me?.first?.userBooks?.first
    }

    public func addBookToLibrary(bookId: Int, startReading: Bool = false, eventDate: String? = nil) async throws -> Int {
        if let existing = try await getUserBook(bookId: bookId) {
            if startReading, existing.statusId != 2 {
                try await markBookAsStarted(userBookId: existing.id, eventDate: eventDate)
            }
            return existing.id
        }
        return try await setBookStatus(bookId: bookId, status: startReading ? .currentlyReading : .wantToRead, eventDate: eventDate)
    }

    public func setBookStatus(bookId: Int, status: HardcoverReadingStatus, eventDate: String? = nil) async throws -> Int {
        let query = """
            query {
                me {
                    user_books(where: {book_id: {_eq: \(bookId)}}, limit: 1) {
                        id
                    }
                }
            }
            """
        let response: UserBookIDQueryResponse = try await performQuery(query)
        if let userBookId = response.me?.first?.userBooks?.first?.id {
            try await updateBookStatus(userBookId: userBookId, statusId: status.rawValue, eventDate: eventDate)
            return userBookId
        }

        let today = eventDate ?? HardcoverDateFormatter.todayString()
        let mutation = """
            mutation {
                insert_user_book(object: {book_id: \(bookId), status_id: \(status.rawValue), date_added: "\(today)", user_date: "\(today)"}) {
                    error
                    user_book { id }
                }
            }
            """
        let insertResponse: InsertUserBookMutResponse = try await performQuery(mutation)
        if let error = insertResponse.insertUserBook?.error {
            throw HardcoverError.graphQLError(message: error)
        }
        guard let userBookId = insertResponse.insertUserBook?.userBook?.id else {
            throw HardcoverError.invalidResponse
        }
        return userBookId
    }

    public func updateBookStatus(userBookId: Int, statusId: Int, eventDate: String? = nil) async throws {
        let dateParameter = eventDate.map { ", user_date: \"\($0)\"" } ?? ""
        let mutation = """
            mutation {
                update_user_book(id: \(userBookId), object: {status_id: \(statusId)\(dateParameter)}) {
                    error
                    user_book { id status_id }
                }
            }
            """
        let response: GenericUpdateResponse = try await performQuery(mutation)
        try response.validate()
    }

    public func markBookAsStarted(userBookId: Int, eventDate: String? = nil) async throws {
        try await updateBookStatus(userBookId: userBookId, statusId: 2, eventDate: eventDate)
    }

    public func markBookAsFinished(userBookId: Int, eventDate: String? = nil) async throws {
        try await updateBookStatus(userBookId: userBookId, statusId: 3, eventDate: eventDate)
    }

    public func deleteUserBook(userBookId: Int) async throws {
        let mutation = """
            mutation {
                delete_user_book(id: \(userBookId)) { id }
            }
            """
        let response: GenericDeleteResponse = try await performQuery(mutation)
        guard response.deleteUserBook?.id == userBookId else { throw HardcoverError.invalidResponse }
    }

    public func createReadingSession(userBookId: Int, editionId: Int? = nil, eventDate: String? = nil) async throws -> Int {
        try await insertReadRecord(
            userBookId: userBookId,
            progressPages: 0,
            isFinished: false,
            editionId: editionId, eventDate: eventDate
        )
    }

    public func latestRead(userBookId: Int) async throws -> (id: Int, isFinished: Bool)? {
        let query = """
            query {
                user_book_reads(where: {user_book_id: {_eq: \(userBookId)}}, order_by: {id: desc}, limit: 1) {
                    id finished_at
                }
            }
            """
        let response: LatestReadResponse = try await performQuery(query)
        return response.userBookReads?.first.map { ($0.id, $0.finishedAt != nil) }
    }

    public func finishRead(readId: Int) async throws {
        let mutation = """
            mutation {
                update_user_book_read(id: \(readId), object: {finished_at: "\(HardcoverDateFormatter.todayString())"}) {
                    error
                    user_book_read { id progress_pages }
                }
            }
            """
        let response: UpdateReadProgressResponse = try await performQuery(mutation)
        try response.validate()
    }

    public func upsertReadingProgress(
        userBookId: Int,
        existingReadId: Int?,
        progressPages: Int,
        progressSeconds: Int? = nil,
        isFinished: Bool,
        editionId: Int?,
        eventDate: String? = nil,
        startDate: String? = nil,
        actionAt: Date? = nil
    ) async throws -> Int {
        let today = eventDate ?? HardcoverDateFormatter.todayString()
        let editionParam = editionId.map { ", edition_id: \($0)" } ?? ""
        let actionParam = actionAt.map { ", action_at: \"\($0.ISO8601Format())\"" } ?? ""
        let finishedParam = isFinished ? ", finished_at: \"\(today)\"" : ""
        let progressParam = progressSeconds.map { "progress_seconds: \($0)" } ?? "progress_pages: \(progressPages)"

        if let readId = existingReadId, readId > 0 {
            let mutation = """
                mutation {
                    update_user_book_read(id: \(readId), object: {\(progressParam)\(finishedParam)\(editionParam)\(actionParam)}) {
                        error
                        user_book_read { id progress_pages }
                    }
                }
                """
            let response: UpdateReadProgressResponse = try await performQuery(mutation)
            try response.validate()
            return readId
        } else {
            return try await insertReadRecord(
                userBookId: userBookId,
                progressPages: progressPages,
                progressSeconds: progressSeconds,
                isFinished: isFinished,
                editionId: editionId, eventDate: eventDate, startDate: startDate, actionAt: actionAt
            )
        }
    }

    private func insertReadRecord(
        userBookId: Int,
        progressPages: Int,
        progressSeconds: Int? = nil,
        isFinished: Bool,
        editionId: Int?,
        eventDate: String? = nil,
        startDate: String? = nil,
        actionAt: Date? = nil
    ) async throws -> Int {
        let today = eventDate ?? HardcoverDateFormatter.todayString()
        var input: [String: Any] = ["started_at": startDate ?? today]
        if let actionAt { input["action_at"] = actionAt.ISO8601Format() }
        if let progressSeconds { input["progress_seconds"] = progressSeconds }
        else { input["progress_pages"] = progressPages }
        if isFinished { input["finished_at"] = today }
        if let editionId { input["edition_id"] = editionId }
        let mutation = """
            mutation InsertRead($userBookId: Int!, $read: DatesReadInput!) {
                insert_user_book_read(user_book_id: $userBookId, user_book_read: $read) {
                    error
                    user_book_read { id }
                }
            }
            """
        let response: InsertReadSessionResponse = try await performQuery(
            mutation, variables: ["userBookId": userBookId, "read": input]
        )
        return try response.createdReadId()
    }

    public func rateBook(userBookId: Int, rating: Double) async throws {
        guard rating >= 0.5 && rating <= 5.0 else {
            throw HardcoverError.invalidRating
        }
        let mutation = """
            mutation {
                update_user_book(id: \(userBookId), object: {rating: \(rating)}) {
                    error
                    user_book { id rating }
                }
            }
            """
        let response: GenericUpdateResponse = try await performQuery(mutation)
        try response.validate()
    }

    public func reviewBook(userBookId: Int, reviewText: String) async throws {
        let mutation = """
            mutation ReviewBook($id: Int!, $review: UserBookUpdateInput!) {
                update_user_book(id: $id, object: $review) {
                    error
                    user_book { id }
                }
            }
            """
        let response: GenericUpdateResponse = try await performQuery(
            mutation, variables: ["id": userBookId, "review": ["review_markdown": reviewText]]
        )
        try response.validate()
    }

    public func getBookReviews(bookId: Int, limit: Int = 20) async throws -> [HardcoverReview] {
        let query = """
            query {
                user_books(
                    where: {book_id: {_eq: \(bookId)}, has_review: {_eq: true}},
                    order_by: {reviewed_at: desc},
                    limit: \(limit)
                ) {
                    id rating review_raw reviewed_at has_review
                    user { id username image { url } }
                }
            }
            """
        let response: ReviewsResponse = try await performQuery(query)
        return (response.userBooks ?? []).map { ub in
            HardcoverReview(
                id: ub.id,
                userId: ub.user?.id ?? 0,
                username: ub.user?.username ?? "Unknown",
                userImageURL: ub.user?.image?.url,
                rating: ub.rating,
                reviewText: ub.reviewRaw,
                createdAt: ub.reviewedAt,
                hasReview: ub.hasReview ?? false
            )
        }
    }

    public func getTrendingBooks(limit: Int = 20, period: HardcoverTrendingPeriod = .month) async throws -> [HardcoverTrendingBook] {
        let query = """
            query {
                books(
                    limit: \(limit),
                    order_by: {users_count: desc},
                    where: {release_year: {_gte: \(period.yearThreshold)}}
                ) {
                    id title cached_contributors users_count
                    image { url }
                }
            }
            """
        let response: BooksQueryResponse = try await performQuery(query)
        return (response.books ?? []).map { book in
            HardcoverTrendingBook(
                id: book.id,
                title: book.title,
                author: book.cachedContributors?.value,
                coverImageUrl: book.image?.url,
                usersCount: book.usersCount ?? 0
            )
        }
    }

    public func getActivityFeed(limit: Int = 50) async throws -> [HardcoverFeedActivity] {
        let userId = try await cachedUserId()
        let user = try await getCurrentUser()

        let query = """
            query {
                user_books(
                    where: {user_id: {_eq: \(userId)}, status_id: {_is_null: false}},
                    order_by: {updated_at: desc},
                    limit: \(limit)
                ) {
                    id updated_at status_id rating
                    book { id title cached_contributors image { url } }
                }
            }
            """
        let response: UserActivityResponse = try await performQuery(query)
        return (response.userBooks ?? []).map { ub in
            HardcoverFeedActivity(
                id: ub.id,
                userId: userId,
                event: "StatusUpdate",
                createdAt: ub.updatedAt ?? "",
                username: user.username,
                userImageURL: nil,
                bookId: ub.book?.id,
                bookTitle: ub.book?.title,
                bookImageURL: ub.book?.image?.url,
                authorName: ub.book?.cachedContributors?.value,
                rating: ub.rating,
                statusId: ub.statusId,
                progress: nil,
                reviewText: nil
            )
        }
    }

    public func getFollowing() async throws -> [HardcoverFriend] {
        let profile = try await getUserProfile()
        _ = profile.username

        let userId = try await cachedUserId()
        let query = """
            query {
                followed_users(where: {user_id: {_eq: \(userId)}}) {
                    followed_user_id
                }
            }
            """
        do {
            let response: FollowedIdsResponse = try await performQuery(query)
            let ids = (response.followedUsers ?? []).compactMap(\.followedUserId)
            guard !ids.isEmpty else { return [] }
            return try await fetchUsersById(ids)
        } catch {
            AppLogger.network.error("getFollowing failed: \(error.localizedDescription)")
            return []
        }
    }

    public func getFollowers() async throws -> [HardcoverFriend] {
        let userId = try await cachedUserId()
        let query = """
            query {
                followed_users(where: {followed_user_id: {_eq: \(userId)}}) {
                    user_id
                }
            }
            """
        do {
            let response: FollowerIdsResponse = try await performQuery(query)
            let ids = (response.followedUsers ?? []).compactMap(\.userId)
            guard !ids.isEmpty else { return [] }
            return try await fetchUsersById(ids)
        } catch {
            AppLogger.network.error("getFollowers failed: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchUsersById(_ ids: [Int]) async throws -> [HardcoverFriend] {
        let idsString = ids.map { String($0) }.joined(separator: ", ")
        let query = """
            query {
                users(where: {id: {_in: [\(idsString)]}}, order_by: {username: asc}) {
                    id username flair image { url }
                }
            }
            """
        let response: UsersListResponse = try await performQuery(query)
        return (response.users ?? []).map { u in
            HardcoverFriend(id: u.id, username: u.username, imageURL: u.image?.url, flair: u.flair)
        }
    }

    public func getUserLists() async throws -> [HardcoverUserList] {
        let userId = try await cachedUserId()
        let query = """
            query {
                lists(where: {user_id: {_eq: \(userId)}}, order_by: {id: desc}) {
                    id name description slug books_count likes_count
                }
            }
            """
        let response: TopLevelListsResponse = try await performQuery(query)
        return (response.lists ?? []).map { l in
            HardcoverUserList(
                id: l.id,
                name: l.name,
                description: l.description,
                slug: l.slug,
                booksCount: l.booksCount ?? 0,
                likesCount: l.likesCount,
                isPublic: true
            )
        }
    }

    public func getListBooks(listId: Int) async throws -> [HardcoverListBook] {
        let query = """
            query {
                list_books(where: {list_id: {_eq: \(listId)}}, order_by: {id: asc}) {
                    id book_id
                    book { id title cached_contributors image { url } }
                }
            }
            """
        let response: ListBooksResponse = try await performQuery(query)
        return (response.listBooks ?? []).map { lb in
            HardcoverListBook(
                id: lb.id,
                bookId: lb.bookId,
                title: lb.book?.title ?? "Unknown",
                author: lb.book?.cachedContributors?.value,
                coverUrl: lb.book?.image?.url
            )
        }
    }

    private func annualBookGoal() async throws -> GoalsResponse.GoalData? {
        let year = Calendar.current.component(.year, from: Date())
        let query = """
            query {
                me {
                    goals(where: {metric: {_eq: "book"}, archived: {_eq: false},
                        start_date: {_eq: "\(year)-01-01"}, end_date: {_eq: "\(year)-12-31"}},
                        order_by: {id: desc}) {
                        id goal metric start_date end_date description conditions privacy_setting_id progress
                    }
                }
            }
            """
        let response: GoalsResponse = try await performQuery(query)
        return response.me?.first?.goals?.first
    }

    public func getReadingGoal() async throws -> HardcoverReadingGoalLegacy? {
        guard let goal = try await annualBookGoal() else { return nil }
        return HardcoverReadingGoalLegacy(
            id: goal.id,
            year: Calendar.current.component(.year, from: Date()),
            target: goal.goal,
            current: Int(goal.progress)
        )
    }

    public func setReadingGoal(target: Int) async throws {
        guard target > 0 else { throw HardcoverError.invalidResponse }
        let year = Calendar.current.component(.year, from: Date())
        let existing = try await annualBookGoal()
        var input: [String: Any] = [
            "goal": target, "metric": "book",
            "start_date": existing?.startDate ?? "\(year)-01-01",
            "end_date": existing?.endDate ?? "\(year)-12-31",
            "description": existing?.description ?? "Books read in \(year)",
            "conditions": try JSONSerialization.jsonObject(with: JSONEncoder().encode(existing?.conditions ?? .init()))
        ]
        if let privacy = existing?.privacySettingId { input["privacy_setting_id"] = privacy }
        let operation = existing == nil ? "insert_goal(object: $goal)" : "update_goal(id: $id, object: $goal)"
        let idDeclaration = existing == nil ? "" : ", $id: Int!"
        let mutation = """
            mutation SaveGoal($goal: GoalInput!\(idDeclaration)) {
                result: \(operation) { id errors }
            }
            """
        var variables: [String: Any] = ["goal": input]
        if let existing { variables["id"] = existing.id }
        let response: GoalMutationResponse = try await performQuery(mutation, variables: variables)
        if let errors = response.result?.errors, !errors.isEmpty {
            throw HardcoverError.graphQLError(message: errors.joined(separator: ", "))
        }
        guard response.result?.id != nil else { throw HardcoverError.invalidResponse }
    }

    public func getUserStats() async throws -> HardcoverUserStats {
        let userId = try await cachedUserId()
        let query = """
            query {
                user_books(where: {user_id: {_eq: \(userId)}, status_id: {_eq: 3}}) {
                    id rating
                    edition { pages audio_seconds }
                }
            }
            """
        let response: StatsUserBooksResponse = try await performQuery(query)
        let userBooks = response.userBooks ?? []

        var totalPages = 0
        var totalAudioSeconds = 0
        var totalRating = 0.0
        var ratingCount = 0

        for ub in userBooks {
            totalPages += ub.edition?.pages ?? 0
            totalAudioSeconds += ub.edition?.audioSeconds ?? 0
            if let r = ub.rating, r > 0 {
                totalRating += r
                ratingCount += 1
            }
        }

        return HardcoverUserStats(
            booksRead: userBooks.count,
            pagesRead: totalPages,
            authorsRead: 0,
            reviewsWritten: 0,
            hoursListened: Double(totalAudioSeconds) / 3600.0,
            averageRating: ratingCount > 0 ? totalRating / Double(ratingCount) : nil
        )
    }

    public func getFinishedBooks(limit: Int = 25, offset: Int = 0) async throws -> [HardcoverFinishedBookEntry] {
        let userId = try await cachedUserId()
        let query = """
            query {
                user_book_reads(
                    where: {
                        finished_at: {_is_null: false},
                        user_book: {user_id: {_eq: \(userId)}}
                    },
                    order_by: [{finished_at: desc}, {id: desc}],
                    limit: \(limit),
                    offset: \(offset)
                ) {
                    id finished_at edition_id
                    user_book {
                        id book_id rating
                        book { id title cached_contributors image { url } }
                    }
                }
            }
            """
        let response: FinishedBooksResponse = try await performQuery(query)
        return (response.userBookReads ?? []).compactMap { read in
            guard let ub = read.userBook, let book = ub.book else { return nil }
            return HardcoverFinishedBookEntry(
                id: read.id,
                bookId: book.id,
                userBookId: ub.id,
                title: book.title,
                author: book.cachedContributors?.value ?? "Unknown",
                rating: ub.rating,
                finishedAt: HardcoverDateFormatter.parseDate(read.finishedAt ?? ""),
                coverImageUrl: book.image?.url
            )
        }
    }

    private func performQuery<T: Decodable>(
        _ query: String,
        variables: [String: Any]? = nil
    ) async throws -> T {
        guard let apiKey = tokenProvider(), !apiKey.isEmpty else {
            throw HardcoverError.noApiKey
        }

        if let expected = Self.syncToken {
            guard expected == apiKey, SettingsManager.shared.hardcoverAutoSyncEnabled else { throw CancellationError() }
        }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["query": query]
        body["variables"] = variables
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let account = HardcoverRequestPacer.accountKey(apiKey)
        let isCurrent = {
            self.tokenProvider() == apiKey && (Self.syncToken == nil ||
                (SettingsManager.shared.hardcoverAutoSyncEnabled && HardcoverSyncService.hasProfileAccess))
        }
        var data = Data()
        var httpResponse: HTTPURLResponse?
        for attempt in 0..<2 {
            try await pacer.acquire(account: account, cost: HardcoverRequestPacer.requestCost(query), isCurrent: isCurrent)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let (received, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HardcoverError.networkError }
            pacer.observe(http, account: account)
            guard isCurrent() else { throw CancellationError() }
            data = received
            httpResponse = http
            if http.statusCode != 429 || attempt == 1 { break }
        }
        guard let httpResponse else { throw HardcoverError.networkError }

        if !(200...299).contains(httpResponse.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            AppLogger.network.error("[Hardcover] HTTP \(httpResponse.statusCode)")
            if HardcoverError.isAuthenticationFailure(statusCode: httpResponse.statusCode, message: msg),
                SettingsManager.shared.hardcoverApiKey == apiKey {
                SettingsManager.shared.hardcoverApiKey = nil
            }
            throw HardcoverError.httpError(statusCode: httpResponse.statusCode, message: msg)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorMsg = rawDict["error"] as? String
        {
            AppLogger.network.error("[Hardcover] API error: \(errorMsg)")
            if HardcoverError.isAuthenticationFailure(statusCode: httpResponse.statusCode, message: errorMsg),
                SettingsManager.shared.hardcoverApiKey == apiKey {
                SettingsManager.shared.hardcoverApiKey = nil
            }
            throw HardcoverError.graphQLError(message: errorMsg)
        }

        do {
            let graphQLResponse = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = graphQLResponse.errors, !errors.isEmpty {
                let msg = errors.map(\.message).joined(separator: ", ")
                AppLogger.network.error("[Hardcover] GraphQL request failed")
                if HardcoverError.isAuthenticationFailure(statusCode: 200, message: msg),
                    SettingsManager.shared.hardcoverApiKey == apiKey {
                    SettingsManager.shared.hardcoverApiKey = nil
                }
                throw HardcoverError.graphQLError(message: msg)
            }

            guard let responseData = graphQLResponse.data else {
                AppLogger.network.error("[Hardcover] No data in response")
                throw HardcoverError.invalidResponse
            }
            return responseData
        } catch let decodingError as DecodingError {
            AppLogger.network.error("[Hardcover] Decode failed for \(T.self): \(decodingError)")
            throw decodingError
        }
    }

    private func mapToLegacyUserBook(_ data: UserBookFullData) -> HardcoverUserBookLegacy {
        let authors: [HardcoverAuthor]? = data.book.contributions?.compactMap { c in
            guard let a = c.author else { return nil }
            return HardcoverAuthor(id: a.id, name: a.name)
        }
        let authorsFinal =
            (authors?.isEmpty == false)
            ? authors
            : data.book.cachedContributors?.value.map {
                [HardcoverAuthor(id: 0, name: $0)]
            }

        let book = HardcoverBook(
            id: data.book.id,
            title: data.book.title,
            description: data.book.description,
            releaseYear: data.book.releaseYear,
            slug: data.book.slug,
            image: data.book.image,
            cachedContributors: data.book.cachedContributors,
            usersCount: data.book.usersCount
        )

        return HardcoverUserBookLegacy(
            id: data.id,
            book: book,
            rating: data.rating.flatMap { Int($0) },
            review: data.review,
            statusId: data.statusId,
            editionId: data.userBookReads?.first?.editionId ?? data.editionId,
            totalPages: (data.userBookReads?.first?.edition ?? data.edition)?.pages,
            totalAudioSeconds: (data.userBookReads?.first?.edition ?? data.edition)?.audioSeconds,
            userBookReads: data.userBookReads?.map { r in
                HardcoverUserBookReadLegacy(
                    id: r.id,
                    startedAt: r.startedAt,
                    finishedAt: r.finishedAt,
                    progress: r.progressPages.map { Double($0) },
                    progressSeconds: r.progressSeconds
                )
            },
            authors: authorsFinal
        )
    }
}

public struct HardcoverUserInfo: Codable, Sendable {
    public let username: String
    public let id: Int?
}

public struct HardcoverAuthor: Codable, Hashable, Sendable {
    public let id: Int
    public let name: String
}

public struct HardcoverUserBookLegacy: Codable, Identifiable, Sendable {
    public let id: Int
    public let book: HardcoverBook
    public let rating: Int?
    public let review: String?
    public let statusId: Int
    public let editionId: Int?
    public let totalPages: Int?
    public var totalAudioSeconds: Int? = nil
    public let userBookReads: [HardcoverUserBookReadLegacy]?
    public let authors: [HardcoverAuthor]?

    public var readingState: HardcoverReadingStatus {
        HardcoverReadingStatus(rawValue: statusId) ?? .wantToRead
    }

    public var currentReadSession: HardcoverUserBookReadLegacy? {
        userBookReads?.first
    }

    public var progressFraction: Double? {
        if currentReadSession?.finishedAt != nil { return 1 }
        if let seconds = currentReadSession?.progressSeconds, let total = totalAudioSeconds, total > 0 {
            return min(1, max(0, Double(seconds) / Double(total)))
        }
        guard let pages = currentReadSession?.progress,
            let total = totalPages, total > 0
        else { return nil }
        return min(1, max(0, pages / Double(total)))
    }
}

public struct HardcoverUserBookReadLegacy: Codable, Sendable {
    public let id: Int
    public let startedAt: String?
    public let finishedAt: String?
    public let progress: Double?
    public var progressSeconds: Int? = nil
}

public struct HardcoverReadingGoalLegacy: Codable, Sendable {
    public let id: Int
    public let year: Int
    public let target: Int
    public let current: Int

    public var progress: Double {
        guard target > 0 else { return 0 }
        return Double(current) / Double(target)
    }
}

public struct HardcoverUserActivity: Codable, Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let action: String
    public let bookTitle: String
    public let bookId: Int
    public let timestamp: String
    public let rating: Int?
}

public enum HardcoverTrendingPeriod: Sendable {
    case week, month, year, allTime

    public var yearThreshold: Int {
        let currentYear = Calendar.current.component(.year, from: Date())
        switch self {
        case .week, .month: return currentYear
        case .year: return currentYear - 1
        case .allTime: return 1900
        }
    }

    public var displayName: String {
        switch self {
        case .week: return "This Week"
        case .month: return "This Month"
        case .year: return "This Year"
        case .allTime: return "All Time"
        }
    }
}

private actor UserIdCache: Sendable {
    private var id: Int?
    private var token: String?
    func get(token: String) -> Int? { self.token == token ? id : nil }
    func set(_ id: Int, token: String) { self.id = id; self.token = token }
}

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GQLError]?

    struct GQLError: Decodable {
        let message: String
    }
}

private struct MeResponse: Decodable {
    let me: [MeUser]?
    struct MeUser: Decodable {
        let username: String
        let id: Int?
    }
}

private struct ProfileResponse: Decodable {
    let me: [ProfileUser]?
    struct ProfileUser: Decodable {
        let id: Int
        let username: String
        let bio: String?
        let flair: String?
        let image: HardcoverImage?
        let userBooksAggregate: AggregateWrapper?
        let followedUsersCount: Int?
        let followersCount: Int?
    }
}

private struct UsersResponse: Decodable {
    let users: [ProfileUser]?
    struct ProfileUser: Decodable {
        let id: Int
        let username: String
        let bio: String?
        let flair: String?
        let image: HardcoverImage?
        let userBooksAggregate: AggregateWrapper?
        let followedUsersCount: Int?
        let followersCount: Int?
    }
}

private struct AggregateWrapper: Decodable {
    let aggregate: AggregateCount?
    struct AggregateCount: Decodable {
        let count: Int?
    }
}

private struct UserBooksFullResponse: Decodable {
    let me: [MeWithBooks]?
    struct MeWithBooks: Decodable {
        let userBooks: [UserBookFullData]?
    }
}

private struct UserBooksRichResponse: Decodable {
    let me: [MeWithRichBooks]?
    struct MeWithRichBooks: Decodable {
        let userBooks: [HardcoverUserBook]?
    }
}

struct UserBookFullData: Decodable {
    let id: Int
    let bookId: Int?
    let rating: Double?
    let review: String?
    let statusId: Int
    let editionId: Int?
    let book: BookFullData
    let edition: HardcoverEdition?
    let userBookReads: [ReadData]?

    struct BookFullData: Decodable {
        let id: Int
        let title: String
        let description: String?
        let releaseYear: Int?
        let slug: String?
        let cachedContributors: FlexibleContributors?
        let usersCount: Int?
        let image: HardcoverImage?
        let contributions: [ContribData]?
    }

    struct ContribData: Decodable {
        let author: AuthorData?
        struct AuthorData: Decodable {
            let id: Int
            let name: String
        }
    }

    struct ReadData: Decodable {
        let id: Int
        let startedAt: String?
        let finishedAt: String?
        let progressPages: Int?
        let progressSeconds: Int?
        let editionId: Int?
        let edition: HardcoverEdition?
    }
}

private struct BooksQueryResponse: Decodable {
    let books: [HardcoverBook]?
}

private struct EditionsQueryResponse: Decodable {
    let editions: [HardcoverEdition]?
}

private struct EditionBookLookupResponse: Decodable {
    let editions: [EditionBook]?

    struct EditionBook: Decodable {
        let book: HardcoverBook
    }
}

private struct UserBookIDQueryResponse: Decodable {
    let me: [User]?

    struct User: Decodable {
        let userBooks: [UserBook]?
    }

    struct UserBook: Decodable {
        let id: Int
    }
}

private struct SearchResponse: Decodable {
    let search: SearchData?
    struct SearchData: Decodable {
        let results: TypesenseResults?
    }
}

private struct TypesenseResults: Decodable {
    let found: Int?
    let hits: [TypesenseHit]?
}

private struct TypesenseHit: Decodable {
    let document: TypesenseDoc
}

private struct TypesenseDoc: Decodable {
    let id: String
    let title: String
    let description: String?
    let releaseYear: Int?
    let authorNames: [String]?
    let image: HardcoverImage?
    let slug: String?

}

private struct UserSearchResponse: Decodable {
    let users: [UserData]?
    struct UserData: Decodable {
        let id: Int
        let username: String
        let flair: String?
        let image: HardcoverImage?
    }
}

private struct InsertUserBookMutResponse: Decodable {
    let insertUserBook: InsertData?
    struct InsertData: Decodable {
        let error: String?
        let userBook: UBData?
    }
    struct UBData: Decodable { let id: Int }
}

struct GenericUpdateResponse: Decodable {
    func validate() throws {
        guard let result = updateUserBook else { throw HardcoverError.invalidResponse }
        if let error = result.error, !error.isEmpty { throw HardcoverError.graphQLError(message: error) }
        guard let id = result.userBook?.id, id > 0 else { throw HardcoverError.invalidResponse }
    }

    let updateUserBook: UpdateData?
    struct UpdateData: Decodable {
        let error: String?
        let userBook: UpdatedBook?
    }
    struct UpdatedBook: Decodable { let id: Int }
}

private struct GenericDeleteResponse: Decodable {
    let deleteUserBook: DeleteData?
    struct DeleteData: Decodable { let id: Int? }
}

struct InsertReadSessionResponse: Decodable {
    func createdReadId() throws -> Int {
        guard let result = insertUserBookRead else { throw HardcoverError.invalidResponse }
        if let error = result.error, !error.isEmpty { throw HardcoverError.graphQLError(message: error) }
        guard let id = result.userBookRead?.id, id > 0 else { throw HardcoverError.invalidResponse }
        return id
    }

    let insertUserBookRead: InsertData?
    struct InsertData: Decodable {
        let error: String?
        let userBookRead: ReadData?
    }
    struct ReadData: Decodable {
        let id: Int
        let startedAt: String?
        let progressPages: Int?
    }
}

struct UpdateReadProgressResponse: Decodable {
    func validate() throws {
        guard let result = updateUserBookRead else { throw HardcoverError.invalidResponse }
        if let error = result.error, !error.isEmpty { throw HardcoverError.graphQLError(message: error) }
        guard result.userBookRead != nil else { throw HardcoverError.invalidResponse }
    }

    let updateUserBookRead: UpdateData?
    struct UpdateData: Decodable {
        let error: String?
        let userBookRead: ReadData?
    }
    struct ReadData: Decodable {
        let id: Int
        let progressPages: Int?
    }
}

private struct ReviewsResponse: Decodable {
    let userBooks: [ReviewBook]?
    struct ReviewBook: Decodable {
        let id: Int
        let rating: Double?
        let reviewRaw: String?
        let reviewedAt: String?
        let hasReview: Bool?
        let user: ReviewUser?
    }
    struct ReviewUser: Decodable {
        let id: Int
        let username: String
        let image: HardcoverImage?
    }
}

private struct ListBooksResponse: Decodable {
    let listBooks: [ListBookData]?
    struct ListBookData: Decodable {
        let id: Int
        let bookId: Int
        let book: BookRef?
    }
    struct BookRef: Decodable {
        let title: String?
        let cachedContributors: FlexibleContributors?
        let image: HardcoverImage?
    }
}

private struct GoalsResponse: Decodable {
    let me: [MeWithGoals]?
    struct MeWithGoals: Decodable {
        let goals: [GoalData]?
    }
    struct GoalData: Decodable {
        let id: Int
        let goal: Int
        let metric: String?
        let startDate: String?
        let endDate: String?
        let description: String?
        let conditions: GoalConditions
        let privacySettingId: Int?
        let progress: Double
    }
}

private struct GoalConditions: Codable {
    var authorBipoc: Int?
    var authorGenderIds: [Int]?
    var authorLgbtqia: Int?
    var bookCategoryIds: [Int]?
    var readingFormatId: Int?
}

private struct GoalMutationResponse: Decodable {
    let result: Result?
    struct Result: Decodable {
        let id: Int?
        let errors: [String]?
    }
}

private struct UserActivityResponse: Decodable {
    let userBooks: [ActivityUserBook]?
    struct ActivityUserBook: Decodable {
        let id: Int
        let updatedAt: String?
        let statusId: Int?
        let rating: Double?
        let book: ActivityBook?
    }
    struct ActivityBook: Decodable {
        let id: Int
        let title: String
        let cachedContributors: FlexibleContributors?
        let image: HardcoverImage?
    }
}

private struct FollowedIdsResponse: Decodable {
    let followedUsers: [FollowedIdEntry]?
    struct FollowedIdEntry: Decodable {
        let followedUserId: Int?
    }
}

private struct FollowerIdsResponse: Decodable {
    let followedUsers: [FollowerIdEntry]?
    struct FollowerIdEntry: Decodable {
        let userId: Int?
    }
}

private struct UsersListResponse: Decodable {
    let users: [UserListEntry]?
    struct UserListEntry: Decodable {
        let id: Int
        let username: String
        let flair: String?
        let image: HardcoverImage?
    }
}

private struct TopLevelListsResponse: Decodable {
    let lists: [ListData]?
    struct ListData: Decodable {
        let id: Int
        let name: String
        let description: String?
        let slug: String?
        let booksCount: Int?
        let likesCount: Int?
    }
}

private struct StatsUserBooksResponse: Decodable {
    let userBooks: [StatsUserBook]?
    struct StatsUserBook: Decodable {
        let id: Int
        let rating: Double?
        let edition: StatsEdition?
    }
    struct StatsEdition: Decodable {
        let pages: Int?
        let audioSeconds: Int?
    }
}

private struct LatestReadResponse: Decodable {
    let userBookReads: [Read]?
    struct Read: Decodable {
        let id: Int
        let finishedAt: String?
    }
}

private struct FinishedBooksResponse: Decodable {
    let userBookReads: [FinishedRead]?
    struct FinishedRead: Decodable {
        let id: Int
        let finishedAt: String?
        let editionId: Int?
        let userBook: FinishedUserBook?
    }
    struct FinishedUserBook: Decodable {
        let id: Int
        let bookId: Int?
        let rating: Double?
        let book: FinishedBook?
    }
    struct FinishedBook: Decodable {
        let id: Int
        let title: String
        let cachedContributors: FlexibleContributors?
        let image: HardcoverImage?
    }
}

private extension String {
    var graphQLEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum HardcoverError: LocalizedError {
    case noApiKey
    case invalidResponse
    case networkError
    case httpError(statusCode: Int, message: String)
    case graphQLError(message: String)
    case decodingError(Error)
    case invalidRating
    case invalidProgress
    case noMatchFound
    case rateLimited(until: Date)

    static func isAuthenticationFailure(statusCode: Int, message: String) -> Bool {
        if statusCode == 403 { return false }
        let lowercased = message.lowercased()
        return statusCode == 401
            || lowercased.contains("jwtexpired")
            || lowercased.contains("invalid api key")
            || lowercased.contains("unauthorized")
            || lowercased.contains("invalid-jwt")
            || lowercased.contains("invalid_token")
            || lowercased.contains("unable to verify token")
            || lowercased.contains("verify token")
    }

    var errorDescription: String? {
        switch self {
        case .noApiKey:
            return "Hardcover API key not configured. Please add your API key in Settings."
        case .invalidResponse:
            return "Invalid response from Hardcover API."
        case .networkError:
            return "Network error. Please check your connection."
        case .httpError(let code, let msg):
            if code == 401 { return "Invalid API key." }
            if code == 429 { return "Hardcover is rate limiting requests. Try again shortly." }
            if code == 403 {
                if msg.contains("insufficient_scope") { return "This Hardcover key needs additional permissions for this section." }
                if msg.contains("request_exceeds_capacity") { return "This Hardcover request exceeds the account's burst capacity." }
                if msg.contains("unsupported_operation") { return "Hardcover does not allow this operation for API keys." }
                return "Hardcover denied access to this section."
            }
            return "HTTP \(code): \(msg)"
        case .graphQLError(let msg):
            return msg.contains("JWT") ? "API key expired. Regenerate at hardcover.app/account/api" : msg
        case .decodingError(let error):
            return "Decode error: \(error.localizedDescription)"
        case .invalidRating:
            return "Rating must be between 0.5 and 5 stars"
        case .invalidProgress:
            return "Invalid progress value"
        case .rateLimited:
            return "Hardcover is rate limiting requests. Saved progress will retry when the limit resets."
        case .noMatchFound:
            return "No Hardcover match found. Please match the book first."
        }
    }
}
