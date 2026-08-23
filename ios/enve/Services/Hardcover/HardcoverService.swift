import Foundation
import Logging

public final class HardcoverService: Sendable {
    public static let shared = HardcoverService()

    private let baseURL = URL(string: "https://api.hardcover.app/v1/graphql")!
    private let userIdCache = UserIdCache()
    private let insertReadModeStore = InsertReadModeStore()

    private init() {}

    private func cachedUserId() async throws -> Int {
        if let id = await userIdCache.id { return id }
        let user = try await getCurrentUser()
        guard let id = user.id else { throw HardcoverError.invalidResponse }
        await userIdCache.set(id)
        return id
    }

    public typealias Book = HardcoverBook
    public typealias Author = HardcoverAuthor
    public typealias ReadingState = HardcoverReadingStatus
    public typealias UserBook = HardcoverUserBookLegacy
    public typealias UserBookRead = HardcoverUserBookReadLegacy
    public typealias UserInfo = HardcoverUserInfo
    public typealias UserList = HardcoverUserList
    public typealias UserActivity = HardcoverUserActivity
    public typealias ReadingGoal = HardcoverReadingGoalLegacy
    public typealias TrendingPeriod = HardcoverTrendingPeriod

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
                    following_aggregate { aggregate { count } }
                    followers_aggregate { aggregate { count } }
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
            followingCount: me.followingAggregate?.aggregate?.count,
            followersCount: me.followersAggregate?.aggregate?.count
        )
    }

    public func getUserProfileByUsername(_ username: String) async throws -> HardcoverUserProfile {
        let query = """
            query {
                users(where: {username: {_eq: "\(username.graphQLEscaped)"}}, limit: 1) {
                    id
                    username
                    bio
                    flair
                    image { url }
                    user_books_aggregate { aggregate { count } }
                    following_aggregate { aggregate { count } }
                    followers_aggregate { aggregate { count } }
                }
            }
            """
        let response: UsersResponse = try await performQuery(query)
        guard let user = response.users?.first else {
            throw HardcoverError.invalidResponse
        }
        return HardcoverUserProfile(
            id: user.id,
            username: user.username,
            bio: user.bio,
            image: user.image,
            flair: user.flair,
            booksCount: user.userBooksAggregate?.aggregate?.count,
            followingCount: user.followingAggregate?.aggregate?.count,
            followersCount: user.followersAggregate?.aggregate?.count
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

    public func addBookToLibrary(bookId: Int, startReading: Bool = false) async throws -> Int {
        let statusId = startReading ? 2 : 1
        let today = HardcoverDateFormatter.todayString()
        let mutation = """
            mutation {
                insert_user_book(object: {book_id: \(bookId), status_id: \(statusId), date_added: "\(today)"}) {
                    error
                    user_book { id }
                }
            }
            """
        do {
            let response: InsertUserBookMutResponse = try await performQuery(mutation)
            if let id = response.insertUserBook?.userBook?.id {
                return id
            }
            if let error = response.insertUserBook?.error {
                AppLogger.network.error("insert_user_book error: \(error)")
            }
        } catch {
            AppLogger.network.error("insert_user_book failed: \(error.localizedDescription)")
        }

        let userBooks = try await getUserBooks(limit: 200)
        if let existing = userBooks.first(where: { $0.book.id == bookId }) {
            if startReading {
                try? await updateBookStatus(userBookId: existing.id, statusId: 2)
            }
            return existing.id
        }
        throw HardcoverError.invalidResponse
    }

    public func setBookStatus(bookId: Int, status: HardcoverReadingStatus) async throws -> Int {
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
            try await updateBookStatus(userBookId: userBookId, statusId: status.rawValue)
            return userBookId
        }

        let today = HardcoverDateFormatter.todayString()
        let mutation = """
            mutation {
                insert_user_book(object: {book_id: \(bookId), status_id: \(status.rawValue), date_added: "\(today)"}) {
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

    public func updateBookStatus(userBookId: Int, statusId: Int) async throws {
        let mutation = """
            mutation {
                update_user_book(id: \(userBookId), object: {status_id: \(statusId)}) {
                    error
                    user_book { id status_id }
                }
            }
            """
        let response: GenericUpdateResponse = try await performQuery(mutation)
        if let error = response.updateUserBook?.error {
            throw HardcoverError.graphQLError(message: error)
        }
    }

    public func markBookAsStarted(userBookId: Int) async throws {
        try await updateBookStatus(userBookId: userBookId, statusId: 2)
    }

    public func markBookAsFinished(userBookId: Int) async throws {
        try await updateBookStatus(userBookId: userBookId, statusId: 3)
    }

    public func deleteUserBook(userBookId: Int) async throws {
        let mutation = """
            mutation {
                delete_user_book(id: \(userBookId)) { id }
            }
            """
        let _: GenericDeleteResponse = try await performQuery(mutation)
    }

    private enum InsertReadMode: String {
        case legacyObject
        case startedAt
        case progressPages
        case unsupported
    }

    private actor InsertReadModeStore {
        private var mode: InsertReadMode = .legacyObject

        func get() -> InsertReadMode { mode }
        func set(_ newValue: InsertReadMode) { mode = newValue }
    }

    public func createReadingSession(userBookId: Int, editionId: Int? = nil) async throws -> Int {
        try await insertReadRecord(
            userBookId: userBookId,
            progressPages: 0,
            isFinished: false,
            editionId: editionId
        )
    }

    public func upsertReadingProgress(
        userBookId: Int,
        existingReadId: Int?,
        progressPages: Int,
        isFinished: Bool,
        editionId: Int?
    ) async throws -> Int {
        let today = HardcoverDateFormatter.todayString()
        let editionParam = editionId.map { ", edition_id: \($0)" } ?? ""
        let finishedParam = isFinished ? ", finished_at: \"\(today)\"" : ""

        if let readId = existingReadId, readId > 0 {
            let mutation = """
                mutation {
                    update_user_book_read(id: \(readId), object: {progress_pages: \(progressPages)\(finishedParam)\(editionParam)}) {
                        error
                        user_book_read { id progress_pages }
                    }
                }
                """
            let _: UpdateReadProgressResponse = try await performQuery(mutation)
            return readId
        } else {
            return try await insertReadRecord(
                userBookId: userBookId,
                progressPages: progressPages,
                isFinished: isFinished,
                editionId: editionId
            )
        }
    }

    private func insertReadRecord(
        userBookId: Int,
        progressPages: Int,
        isFinished: Bool,
        editionId: Int?
    ) async throws -> Int {
        let today = HardcoverDateFormatter.todayString()
        let editionParam = editionId.map { ", edition_id: \($0)" } ?? ""
        let finishedParam = isFinished ? ", finished_at: \"\(today)\"" : ""

        var mode = await insertReadModeStore.get()

        while true {
            if mode == .unsupported {
                return 0
            }

            let mutation: String
            switch mode {
            case .legacyObject:
                mutation = """
                    mutation {
                        insert_user_book_read(user_book_id: \(userBookId), object: {started_at: "\(today)", progress_pages: \(progressPages)\(finishedParam)\(editionParam)}) {
                            error
                            user_book_read { id }
                        }
                    }
                    """
            case .startedAt:
                mutation = """
                    mutation {
                        insert_user_book_read(user_book_id: \(userBookId), started_at: "\(today)", progress_pages: \(progressPages)\(finishedParam)\(editionParam)) {
                            error
                            user_book_read { id }
                        }
                    }
                    """
            case .progressPages:
                mutation = """
                    mutation {
                        insert_user_book_read(user_book_id: \(userBookId), progress_pages: \(progressPages)\(editionParam)) {
                            error
                            user_book_read { id }
                        }
                    }
                    """
            case .unsupported:
                return 0
            }

            do {
                let response: InsertReadSessionResponse = try await performQuery(mutation, suppressGraphQLErrorLogging: true)
                await insertReadModeStore.set(mode)

                let createdReadId = response.insertUserBookRead?.userBookRead?.id ?? 0
                if isFinished, mode == .progressPages, createdReadId > 0 {
                    try? await markReadSessionFinished(readId: createdReadId)
                }
                return createdReadId
            } catch {
                if shouldRetryInsertUserBookReadWithoutObject(error) {
                    mode = .startedAt
                    await insertReadModeStore.set(mode)
                    continue
                }
                if shouldRetryInsertUserBookReadWithoutStartedAt(error) {
                    mode = .progressPages
                    await insertReadModeStore.set(mode)
                    continue
                }
                if shouldDisableInsertUserBookReadProgressSync(error) {
                    mode = .unsupported
                    await insertReadModeStore.set(mode)
                    return 0
                }
                throw error
            }
        }
    }

    public func updateEditionForRead(readId: Int, editionId: Int) async throws {
        let mutation = """
            mutation {
                update_user_book_read(id: \(readId), object: {edition_id: \(editionId)}) {
                    error
                    user_book_read { id edition_id }
                }
            }
            """
        let _: UpdateReadProgressResponse = try await performQuery(mutation)
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
        let _: GenericUpdateResponse = try await performQuery(mutation)
    }

    public func reviewBook(userBookId: Int, reviewText: String) async throws {
        let slateJSON = "[{\"type\":\"paragraph\",\"children\":[{\"text\":\"\(reviewText.graphQLEscaped)\"}]}]"
        let mutation = """
            mutation {
                update_user_book(id: \(userBookId), object: {review_raw: "\(reviewText.graphQLEscaped)", review_slate: \(slateJSON)}) {
                    error
                    user_book { id has_review reviewed_at }
                }
            }
            """
        let _: GenericUpdateResponse = try await performQuery(mutation)
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

    public func followUser(userId: Int) async throws {
        let mutation = """
            mutation {
                insert_followed_user(user_id: \(userId)) {
                    error
                    followed_users { user_id followed_user_id }
                }
            }
            """
        let _: GenericMutResponse = try await performQuery(mutation)
    }

    public func unfollowUser(userId: Int) async throws {
        let mutation = """
            mutation {
                delete_followed_user(user_id: \(userId)) {
                    id user_id followed_user_id
                }
            }
            """
        let _: GenericMutResponse = try await performQuery(mutation)
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

    public func addBookToList(bookId: Int, listId: Int) async throws {
        let mutation = """
            mutation {
                insert_list_books(objects: {list_id: \(listId), book_id: \(bookId)}) {
                    returning { id }
                }
            }
            """
        let _: GenericMutResponse = try await performQuery(mutation)
    }

    public func getReadingGoal() async throws -> HardcoverReadingGoalLegacy? {
        let currentYear = Calendar.current.component(.year, from: Date())
        let startDate = "\(currentYear)-01-01"
        let endDate = "\(currentYear)-12-31"

        let query = """
            query {
                me {
                    goals(where: {start_date: {_lte: "\(endDate)"}, end_date: {_gte: "\(startDate)"}}) {
                        id goal metric start_date end_date
                    }
                }
            }
            """

        do {
            let response: GoalsResponse = try await performQuery(query)
            if let goal = response.me?.first?.goals?.first {
                let userId = try await cachedUserId()
                let finishedCount = try await countFinishedBooks(userId: userId, startDate: startDate, endDate: endDate)
                return HardcoverReadingGoalLegacy(
                    id: goal.id,
                    year: currentYear,
                    target: goal.goal,
                    current: finishedCount
                )
            }
        } catch {
            AppLogger.network.error("Goals query failed, trying fallback: \(error.localizedDescription)")
        }

        return nil
    }

    private func countFinishedBooks(userId: Int, startDate: String, endDate: String) async throws -> Int {
        let query = """
            query {
                user_book_reads_aggregate(
                    where: {
                        finished_at: {_gte: "\(startDate)", _lte: "\(endDate)"},
                        user_book: {user_id: {_eq: \(userId)}}
                    }
                ) {
                    aggregate { count }
                }
            }
            """
        let response: FinishedCountResponse = try await performQuery(query)
        return response.userBookReadsAggregate?.aggregate?.count ?? 0
    }

    public func setReadingGoal(target: Int) async throws {
        let currentYear = Calendar.current.component(.year, from: Date())
        let mutation = """
            mutation {
                insert_reading_goals(
                    objects: {year: \(currentYear), target: \(target)},
                    on_conflict: {constraint: reading_goals_user_id_year_key, update_columns: [target]}
                ) {
                    returning { id target }
                }
            }
            """
        let _: GenericMutResponse = try await performQuery(mutation)
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

    public func syncProgressForMatchedBook(localBookId: String, progress: Double) async throws {
        guard let match = SettingsManager.shared.getHardcoverMatch(forLocalBookId: localBookId) else {
            throw HardcoverError.noMatchFound
        }

        let userBooks = try await getUserBooks(limit: 100)
        guard let userBook = userBooks.first(where: { $0.book.id == match.hardcoverBookId }) else {
            return
        }

        guard let currentRead = userBook.currentReadSession else { return }

        var pageCount = match.editionPageCount
        let editionId = match.hardcoverEditionId ?? userBook.editionId

        if pageCount == nil, let fetchEditionId = editionId {
            let details = try await getEditionDetails(editionId: fetchEditionId)
            pageCount = details.pages
            if let pages = pageCount {
                let updatedMatch = HardcoverBookMatch(
                    id: match.id,
                    localBookId: match.localBookId,
                    hardcoverBookId: match.hardcoverBookId,
                    hardcoverUserBookId: userBook.id,
                    hardcoverEditionId: editionId,
                    editionPageCount: pages,
                    matchedAt: match.matchedAt,
                    matchType: match.matchType,
                    localBookTitle: match.localBookTitle,
                    hardcoverBookTitle: match.hardcoverBookTitle
                )
                SettingsManager.shared.addHardcoverMatch(updatedMatch)
            }
        }

        guard let pages = pageCount, pages > 0 else { return }
        let currentPage = max(1, Int(Double(pages) * progress))
        try await updateProgressPages(userBookReadId: currentRead.id, currentPage: currentPage, editionId: editionId)
    }

    public func updateProgressPages(userBookReadId: Int, currentPage: Int, editionId: Int?) async throws {
        guard currentPage > 0 else { throw HardcoverError.invalidProgress }
        let editionParam = editionId.map { ", edition_id: \($0)" } ?? ""
        let mutation = """
            mutation {
                update_user_book_read(id: \(userBookReadId), object: {progress_pages: \(currentPage)\(editionParam)}) {
                    error
                    user_book_read { id progress_pages }
                }
            }
            """
        let _: UpdateReadProgressResponse = try await performQuery(mutation)
    }

    public func markMatchedBookAsFinished(localBookId: String) async throws {
        guard let match = SettingsManager.shared.getHardcoverMatch(forLocalBookId: localBookId),
            let userBookId = match.hardcoverUserBookId
        else {
            throw HardcoverError.noMatchFound
        }
        try await markBookAsFinished(userBookId: userBookId)
    }

    private func performQuery<T: Decodable>(
        _ query: String,
        suppressGraphQLErrorLogging: Bool = false
    ) async throws -> T {
        guard let apiKey = SettingsManager.shared.hardcoverApiKey, !apiKey.isEmpty else {
            throw HardcoverError.noApiKey
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let queryPrefix = String(query.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        AppLogger.network.debug("[Hardcover] Query: \(queryPrefix)...")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HardcoverError.networkError
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            AppLogger.network.error("[Hardcover] HTTP \(httpResponse.statusCode)")
            if HardcoverError.isAuthenticationFailure(statusCode: httpResponse.statusCode, message: msg) {
                SettingsManager.shared.clearHardcoverAccess(reason: "authenticationFailed")
            }
            throw HardcoverError.httpError(statusCode: httpResponse.statusCode, message: msg)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        if let rawDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorMsg = rawDict["error"] as? String
        {
            AppLogger.network.error("[Hardcover] API error: \(errorMsg)")
            if HardcoverError.isAuthenticationFailure(statusCode: httpResponse.statusCode, message: errorMsg) {
                SettingsManager.shared.clearHardcoverAccess(reason: "authenticationFailed")
            }
            throw HardcoverError.graphQLError(message: errorMsg)
        }

        do {
            let graphQLResponse = try decoder.decode(GraphQLResponse<T>.self, from: data)

            if let errors = graphQLResponse.errors, !errors.isEmpty {
                let msg = errors.map(\.message).joined(separator: ", ")
                if !suppressGraphQLErrorLogging {
                    AppLogger.network.error("[Hardcover] GraphQL error: \(msg)")
                }
                if HardcoverError.isAuthenticationFailure(statusCode: 200, message: msg) {
                    SettingsManager.shared.clearHardcoverAccess(reason: "authenticationFailed")
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

    private func shouldRetryInsertUserBookReadWithoutObject(_ error: Error) -> Bool {
        guard case let HardcoverError.graphQLError(message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("insert_user_book_read")
            && lower.contains("no argument named 'object'")
    }

    private func shouldRetryInsertUserBookReadWithoutStartedAt(_ error: Error) -> Bool {
        guard case let HardcoverError.graphQLError(message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("insert_user_book_read")
            && lower.contains("no argument named 'started_at'")
    }

    private func shouldDisableInsertUserBookReadProgressSync(_ error: Error) -> Bool {
        guard case let HardcoverError.graphQLError(message) = error else { return false }
        let lower = message.lowercased()
        return lower.contains("insert_user_book_read")
            && lower.contains("no argument named 'progress_pages'")
    }

    private func markReadSessionFinished(readId: Int) async throws {
        let today = HardcoverDateFormatter.todayString()
        let mutation = """
            mutation {
                update_user_book_read(id: \(readId), object: {finished_at: "\(today)"}) {
                    error
                    user_book_read { id }
                }
            }
            """
        let _: UpdateReadProgressResponse = try await performQuery(mutation)
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
            editionId: data.editionId,
            totalPages: data.edition?.pages,
            userBookReads: data.userBookReads?.map { r in
                HardcoverUserBookReadLegacy(
                    id: r.id,
                    startedAt: r.startedAt,
                    finishedAt: r.finishedAt,
                    progress: r.progressPages.map { Double($0) }
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
    public let userBookReads: [HardcoverUserBookReadLegacy]?
    public let authors: [HardcoverAuthor]?

    public var readingState: HardcoverReadingStatus {
        HardcoverReadingStatus(rawValue: statusId) ?? .wantToRead
    }

    public var currentReadSession: HardcoverUserBookReadLegacy? {
        userBookReads?.first
    }

    public var progressFraction: Double? {
        guard let pages = currentReadSession?.progress,
            let total = totalPages, total > 0
        else { return nil }
        return pages / Double(total)
    }
}

public struct HardcoverUserBookReadLegacy: Codable, Sendable {
    public let id: Int
    public let startedAt: String?
    public let finishedAt: String?
    public let progress: Double?
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
    var id: Int?
    func set(_ newId: Int) { id = newId }
    func clear() { id = nil }
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
        let followingAggregate: AggregateWrapper?
        let followersAggregate: AggregateWrapper?
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
        let followingAggregate: AggregateWrapper?
        let followersAggregate: AggregateWrapper?
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

    enum CodingKeys: String, CodingKey {
        case id, title, description, image, slug
        case releaseYear = "release_year"
        case authorNames = "author_names"
    }
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
        enum CodingKeys: String, CodingKey {
            case error
            case userBook = "user_book"
        }
    }
    struct UBData: Decodable { let id: Int }
    enum CodingKeys: String, CodingKey {
        case insertUserBook = "insert_user_book"
    }
}

private struct GenericUpdateResponse: Decodable {
    let updateUserBook: UpdateData?
    struct UpdateData: Decodable {
        let error: String?
    }
    enum CodingKeys: String, CodingKey {
        case updateUserBook = "update_user_book"
    }
}

private struct GenericDeleteResponse: Decodable {
    let deleteUserBook: DeleteData?
    struct DeleteData: Decodable { let id: Int? }
    enum CodingKeys: String, CodingKey {
        case deleteUserBook = "delete_user_book"
    }
}

private struct GenericMutResponse: Decodable {}

private struct InsertReadSessionResponse: Decodable {
    let insertUserBookRead: InsertData?
    struct InsertData: Decodable {
        let error: String?
        let userBookRead: ReadData?
        enum CodingKeys: String, CodingKey {
            case error
            case userBookRead = "user_book_read"
        }
    }
    struct ReadData: Decodable {
        let id: Int
        let startedAt: String?
        let progressPages: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case startedAt = "started_at"
            case progressPages = "progress_pages"
        }
    }
    enum CodingKeys: String, CodingKey {
        case insertUserBookRead = "insert_user_book_read"
    }
}

private struct UpdateReadProgressResponse: Decodable {
    let updateUserBookRead: UpdateData?
    struct UpdateData: Decodable {
        let error: String?
        let userBookRead: ReadData?
        enum CodingKeys: String, CodingKey {
            case error
            case userBookRead = "user_book_read"
        }
    }
    struct ReadData: Decodable {
        let id: Int
        let progressPages: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case progressPages = "progress_pages"
        }
    }
    enum CodingKeys: String, CodingKey {
        case updateUserBookRead = "update_user_book_read"
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
    }
}

private struct FinishedCountResponse: Decodable {
    let userBookReadsAggregate: AggregateWrapper?
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

    static func isAuthenticationFailure(statusCode: Int, message: String) -> Bool {
        let lowercased = message.lowercased()
        return statusCode == 401
            || statusCode == 403
            || lowercased.contains("jwtexpired")
            || lowercased.contains("invalid api key")
            || lowercased.contains("unauthorized")
            || lowercased.contains("forbidden")
            || lowercased.contains("invalid-jwt")
            || lowercased.contains("jwt")
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
            return code == 401 ? "Invalid API key." : "HTTP \(code): \(msg)"
        case .graphQLError(let msg):
            return msg.contains("JWT") ? "API key expired. Regenerate at hardcover.app/account/api" : msg
        case .decodingError(let error):
            return "Decode error: \(error.localizedDescription)"
        case .invalidRating:
            return "Rating must be between 0.5 and 5 stars"
        case .invalidProgress:
            return "Invalid progress value"
        case .noMatchFound:
            return "No Hardcover match found. Please match the book first."
        }
    }
}
