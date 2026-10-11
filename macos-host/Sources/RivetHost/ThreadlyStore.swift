import SwiftUI
import RivetRuntime

/// One row of the sidebar / search results. Fields are positional strings
/// from the backend; the layouts are documented in app/backend.rkt and must
/// move together with the mapping code below.
struct TopicRow: Identifiable, Hashable {
    let id: Int
    let title: String
    let categoryId: Int
    let postsCount: Int
    let replyCount: Int
    let views: Int
    let likeCount: Int
    let lastPosted: String
}

struct PostRow: Identifiable, Hashable {
    let number: Int
    let author: String
    let avatarURL: String
    let html: String
    let createdAt: String

    var id: Int { number }
}

/// All client state lives here; views stay dumb. Every backend round trip
/// goes through the generated RivetAPI; backend events arrive via
/// handleEvent.
@MainActor
final class ThreadlyStore: ObservableObject {
    struct ForumCategory: Hashable {
        let name: String
        let color: Color?
    }

    @Published var topics: [TopicRow] = []
    @Published var loadingTopics = false
    @Published var searchResults: [TopicRow] = []
    @Published var searching = false
    @Published var categories: [Int: ForumCategory] = [:]
    @Published var selectedTopic: TopicRow?
    @Published var posts: [PostRow] = []
    @Published var loadingPosts = false
    @Published var statusLine = ""

    private var api: RivetAPI?

    /// Sidebar content: search results while a search is active, the
    /// latest-topic feed otherwise.
    var displayTopics: [TopicRow] {
        searchResults.isEmpty ? topics : searchResults
    }

    var isSearchActive: Bool { !searchResults.isEmpty }

    func bind(api: RivetAPI) {
        self.api = api
    }

    func handleEvent(_ event: RivetEvent) {
        switch event {
        case .notify(let message):
            statusLine = message
        }
    }

    // MARK: - loads

    /// fresh=false serves the disk cache (TTL on the backend side); the
    /// toolbar refresh passes fresh=true to bypass it.
    func loadLatest(fresh: Bool = false) async {
        guard let api else { return }
        loadingTopics = true
        defer { loadingTopics = false }
        do {
            let rows = try await api.latest_list(page: 0, fresh: fresh)
            topics = rows.map(Self.topic(fromLatest:))
            if searchResults.isEmpty == false { searchResults = [] }
            statusLine = ""
        } catch {
            statusLine = "Couldn't load topics: \(error)"
        }
    }

    /// Toolbar refresh: bypass the disk cache.
    func refresh() {
        Task { await loadLatest(fresh: true) }
        Task { await loadCategories() }
    }

    func loadCategories() async {
        guard let api else { return }
        do {
            let rows = try await api.categories_list()
            var map: [Int: ForumCategory] = [:]
            // category row = (id name slug color)
            for row in rows where row.count >= 2 {
                map[Int(row[0]) ?? -1] = ForumCategory(
                    name: row[1],
                    color: Color(forumHex: row.count > 3 ? row[3] : "")
                )
            }
            categories = map
        } catch {
            // category names are decoration; leave them blank on failure
        }
    }

    func openTopic(_ topic: TopicRow) async {
        selectedTopic = topic
        guard let api else { return }
        loadingPosts = true
        defer { loadingPosts = false }
        do {
            let rows = try await api.topic_open(id: String(topic.id))
            posts = rows.compactMap(Self.post(from:))
            statusLine = ""
        } catch {
            posts = []
            statusLine = "Couldn't open the topic: \(error)"
        }
    }

    func search(_ term: String) async {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let api else { return }
        searching = true
        defer { searching = false }
        do {
            let rows = try await api.search_list(q: query)
            searchResults = rows.map(Self.topic(fromSearch:))
            statusLine = ""
        } catch {
            searchResults = []
            statusLine = "Search failed: \(error)"
        }
    }

    func clearSearch() {
        searchResults = []
    }

    // MARK: - row mapping

    private static func topic(fromLatest row: [String]) -> TopicRow {
        // latest row = (id title category-id posts-count reply-count
        //               views like-count last-posted-at)
        TopicRow(
            id: row.count > 0 ? Int(row[0]) ?? 0 : 0,
            title: row.count > 1 ? row[1] : "",
            categoryId: row.count > 2 ? Int(row[2]) ?? 0 : 0,
            postsCount: row.count > 3 ? Int(row[3]) ?? 0 : 0,
            replyCount: row.count > 4 ? Int(row[4]) ?? 0 : 0,
            views: row.count > 5 ? Int(row[5]) ?? 0 : 0,
            likeCount: row.count > 6 ? Int(row[6]) ?? 0 : 0,
            lastPosted: row.count > 7 ? row[7] : "")
    }

    private static func topic(fromSearch row: [String]) -> TopicRow {
        // search row = (id title created-at posts-count)
        TopicRow(
            id: row.count > 0 ? Int(row[0]) ?? 0 : 0,
            title: row.count > 1 ? row[1] : "",
            categoryId: 0,
            postsCount: row.count > 3 ? Int(row[3]) ?? 0 : 0,
            replyCount: 0, views: 0, likeCount: 0,
            lastPosted: row.count > 2 ? row[2] : "")
    }

    private static func post(from row: [String]) -> PostRow? {
        // topic-post row = (author avatar-url cooked-html created-at post-number)
        guard row.count >= 5 else { return nil }
        return PostRow(
            number: Int(row[4]) ?? 0,
            author: row[0],
            avatarURL: row[1],
            html: row[2],
            createdAt: row[3])
    }

    func categoryName(_ id: Int) -> String {
        categories[id]?.name ?? (id == 0 ? "" : "Category \(id)")
    }

    func categoryColor(_ id: Int) -> Color? {
        categories[id]?.color
    }
}
