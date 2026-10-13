import AppKit
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
    struct ForumCategory: Identifiable, Hashable {
        let id: Int
        let name: String
        let slug: String
        let color: Color?

        /// Discourse's slug/id pair is the category URL + API address.
        var scope: Scope { .category(id: id, slug: slug) }
    }

    /// What the sidebar is browsing: the whole forum, a category, or the
    /// signed-in user's notifications.
    enum Scope: Hashable {
        case latest
        case notifications
        case category(id: Int, slug: String)
    }

    struct NotificationRow: Identifiable, Hashable {
        let id: Int
        let symbol: String
        let text: String
        let createdAt: String
        let topicId: Int?
    }

    @Published var topics: [TopicRow] = []
    @Published var loadingTopics = false
    @Published var searchResults: [TopicRow] = []
    @Published var searching = false
    @Published var categories: [ForumCategory] = []
    @Published var scope: Scope = .latest
    @Published var selectedTopic: TopicRow?
    @Published var posts: [PostRow] = []
    @Published var loadingPosts = false
    @Published var statusLine = ""
    @Published var signedInUser: String?
    @Published var notifications: [NotificationRow] = []
    @Published var signInStage: SignInStage = .idle
    @Published var replySheetTopic: TopicRow?
    @Published var postingReply = false

    enum SignInStage: Equatable {
        case idle            // no sign-in in progress
        case awaitingCode    // browser opened the forum approval page
    }

    private var api: RivetAPI?

    /// Sidebar content: search results while a search is active, the
    /// latest-topic feed otherwise.
    var displayTopics: [TopicRow] {
        searchResults.isEmpty ? topics : searchResults
    }

    var isSearchActive: Bool { !searchResults.isEmpty }

    func bind(api: RivetAPI) {
        self.api = api
        checkAuthStatus()
    }

    // MARK: - account (M2)

    func checkAuthStatus() {
        guard let api else { return }
        Task {
            if let st = try? await api.auth_status(), st.status == "in" {
                let user = st.username
                await MainActor.run { self.signedInUser = user.isEmpty ? nil : user }
            }
        }
    }

    /// Opens the forum approval page in the browser, then shows the
    /// paste-the-code sheet.
    func beginSignIn() {
        guard let api else { return }
        Task {
            do {
                let url = try await api.auth_begin()
                await MainActor.run { self.signInStage = .awaitingCode }
                if let u = URL(string: url) {
                    NSWorkspace.shared.open(u)
                }
            } catch {
                await MainActor.run { self.statusLine = "Sign-in failed: \(error)" }
            }
        }
    }

    func completeSignIn(code: String) {
        guard let api else { return }
        Task {
            do {
                _ = try await api.auth_complete(code: code)
                let st = try await api.auth_status()
                let user = st.username
                await MainActor.run {
                    self.signedInUser = user.isEmpty ? nil : user
                    self.signInStage = .idle
                }
            } catch {
                await MainActor.run {
                    self.signInStage = .awaitingCode  // stay on the sheet
                    self.statusLine = "Sign-in failed: \(error)"
                }
            }
        }
    }

    func cancelSignIn() {
        signInStage = .idle
    }

    func signOut() {
        guard let api else { return }
        Task {
            _ = try? await api.auth_sign_out()
            await MainActor.run { self.signedInUser = nil }
        }
    }

    // MARK: - reply (M2 write path)

    /// Posts the raw markdown and reloads the thread so the new post
    /// appears. Closes the composer on success; on failure it stays open
    /// and the error lands in the status line.
    func submitReply(to topic: TopicRow, raw: String) {
        guard let api else { return }
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        postingReply = true
        Task {
            do {
                _ = try await api.post_create(topic_id: String(topic.id), body: body)
                await MainActor.run {
                    self.postingReply = false
                    self.replySheetTopic = nil
                }
                await self.openTopicId(topic.id, title: topic.title)
            } catch {
                await MainActor.run {
                    self.postingReply = false
                    self.statusLine = "Reply failed: \(error)"
                }
            }
        }
    }

    func handleEvent(_ event: RivetEvent) {
        switch event {
        case .notify(let message):
            statusLine = message
        case .update_available(let version):
            // fired by the backend's update-check RPC (Windows/CLI path);
            // the macOS host checks natively via UpdateService
            statusLine = "Update \(version) is available."
        case .open_url(let url):
            // backend-driven link (open-releases RPC); opens in the browser
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        }
    }

    // MARK: - loads

    /// Load whichever scope the sidebar is browsing. fresh=false serves the
    /// disk cache (TTL on the backend side); the toolbar refresh passes
    /// fresh=true to bypass it.
    func load(scope: Scope, fresh: Bool = false) async {
        guard let api else { return }
        loadingTopics = true
        defer { loadingTopics = false }
        self.scope = scope
        do {
            switch scope {
            case .latest:
                let rows = try await api.latest_list(page: 0, fresh: fresh)
                topics = rows.map(Self.topic(fromLatest:))
            case .notifications:
                let rows = try await api.notifications_list()
                notifications = rows.map(Self.notification(from:))
            case .category(let id, let slug):
                let rows = try await api.category_topics_list(slug: slug, id: String(id))
                topics = rows.map(Self.topic(fromLatest:))
            }
            selectedTopic = nil
            posts = []
            if searchResults.isEmpty == false { searchResults = [] }
            selectedTopic = nil
            posts = []
            statusLine = ""
        } catch {
            statusLine = "Couldn't load topics: \(error)"
        }
    }

    /// Toolbar refresh: bypass the disk cache for the current scope.
    func refresh() {
        Task { await load(scope: scope, fresh: true) }
        Task { await loadCategories() }
    }

    func loadCategories() async {
        guard let api else { return }
        do {
            let rows = try await api.categories_list()
            // category row = (id name slug color); the feed order is the
            // forum's own position order — keep it for the sidebar
            categories = rows.compactMap { row in
                guard row.count >= 3, let id = Int(row[0]) else { return nil }
                return ForumCategory(
                    id: id,
                    name: row[1],
                    slug: row[2],
                    color: Color(forumHex: row.count > 3 ? row[3] : "")
                )
            }
        } catch {
            // category names are decoration; leave them blank on failure
        }
    }

    func openTopic(_ topic: TopicRow) async {
        await openTopicId(topic.id, title: topic.title)
    }

    /// Opens a thread by id; notifications carry only the id.
    func openTopicId(_ id: Int, title: String) async {
        selectedTopic = TopicRow(id: id, title: title, categoryId: 0,
                                 postsCount: 0, replyCount: 0, views: 0,
                                 likeCount: 0, lastPosted: "")
        guard let api else { return }
        loadingPosts = true
        defer { loadingPosts = false }
        do {
            let rows = try await api.topic_open(id: String(id))
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

    private static func notification(from row: [String]) -> NotificationRow {
        // notifications row = (id type-label read-flag created topic-id title username)
        let symbol: String = {
            switch row.count > 1 ? row[1] : "" {
            case "reply": return "arrowshape.turn.up.left.fill"
            case "like", "likes": return "heart.fill"
            case "mention", "group-mention": return "at"
            case "quote": return "text.quote"
            case "message": return "envelope"
            case "edited": return "pencil"
            case "link": return "link"
            default: return "bell.fill"
            }
        }()
        let username = row.count > 6 ? row[6] : ""
        let title = row.count > 5 ? row[5] : ""
        let created = row.count > 3 ? row[3] : ""
        let topicId = row.count > 4 ? Int(row[4]) ?? 0 : 0
        let read = row.count > 2 && row[2] == "1"
        let text = username.isEmpty ? title : "\(username) · \(title)"
        return NotificationRow(id: row.count > 0 ? Int(row[0]) ?? 0 : 0,
                               symbol: symbol,
                               text: read ? text : "● " + text,
                               createdAt: created,
                               topicId: topicId)
    }

    func categoryName(_ id: Int) -> String {
        let category = categories.first { $0.id == id }
        return category?.name ?? (id == 0 ? "" : "Category \(id)")
    }

    func categoryColor(_ id: Int) -> Color? {
        categories.first { $0.id == id }?.color
    }
}
