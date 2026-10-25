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
    let postId: Int
    let likeCount: Int
    let liked: Bool

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
    /// The thread's total post count from the backend rows; the reader
    /// shows its "load all" bar while posts.count < postsTotal.
    @Published var postsTotal = 0
    @Published var loadingPosts = false
    /// Set when the open thread failed to load; the reader offers Retry /
    /// Back instead of the "empty thread" dead end.
    @Published var topicLoadError: String?
    @Published var statusLine = ""
    @Published var signedInUser: String?
    @Published var notifications: [NotificationRow] = []
    @Published var signInStage: SignInStage = .idle
    @Published var replySheetTopic: TopicRow?
    @Published var postingReply = false
    @Published var showAIPanel = false
    @Published var aiPanelTitle = ""
    @Published var aiPanelText = ""
    @Published var aiLoading = false

    /// Identity of the current thread load. Every posts/total/error write
    /// is gated on this: a completion from a superseded open (user moved
    /// on, signed out, went back to the list) is dropped, so a late
    /// response can never present topic A's content under topic B.
    private var topicLoadGeneration = 0
    /// Draft replies per topic id, kept across failed loads and composer
    /// dismissals; dropped once the reply actually posts.
    private var replyDrafts: [Int: String] = [:]

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
    /// paste-the-code sheet. The browser open rides the backend's
    /// open-url event (handleEvent) — auth-begin both fires the event and
    /// returns the URL, so opening here too would open two tabs.
    func beginSignIn() {
        guard let api else { return }
        Task {
            do {
                _ = try await api.auth_begin()
                await MainActor.run { self.signInStage = .awaitingCode }
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
        // In-flight signed reads (e.g. a notifications-driven open) are
        // dropped: nothing signed may land after the identity is gone.
        invalidateTopicLoad()
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
                    // posted: the draft has become a forum post
                    self.replyDrafts.removeValue(forKey: topic.id)
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

    // MARK: - likes (M2 write path)

    /// Called from the thread webview's JS bridge. The RPC reports
    /// success/failure; the view then moves the button via JS so the
    /// shown state always matches the server.
    func likePost(_ postId: Int, completion: @escaping (Bool) -> Void) {
        setLike(postId, liked: true, failure: "Couldn't like that post.",
                completion: completion)
    }

    /// The second click on a liked post — the engine's was_deleted
    /// direction. Same contract as likePost: the RPC reports
    /// success/failure; the view moves the button via JS.
    func unlikePost(_ postId: Int, completion: @escaping (Bool) -> Void) {
        setLike(postId, liked: false, failure: "Couldn't remove that like.",
                completion: completion)
    }

    private func setLike(_ postId: Int, liked: Bool, failure: String,
                         completion: @escaping (Bool) -> Void) {
        guard let api else { return }
        Task {
            let ok: Bool
            do {
                ok = liked
                    ? try await api.like_post(post_id: String(postId))
                    : try await api.unlike_post(post_id: String(postId))
            } catch {
                ok = false
            }
            await MainActor.run {
                if !ok {
                    self.statusLine = failure
                }
                completion(ok)
            }
        }
    }

    // MARK: - M3 reading value-add (summary, translation)

    enum AIKind {
        case summarize
        case translate
    }

    /// Runs summary or translation over the open thread and shows the
    /// result in a panel. The engine answers "" + a notify event on
    /// failure, so an empty result just closes the panel (the status line
    /// carries the reason).
    func runAI(_ kind: AIKind) {
        guard let topic = selectedTopic, let api, !aiLoading else { return }
        aiPanelTitle = kind == .summarize ? "Summary" : "Translation"
        aiPanelText = ""
        aiLoading = true
        showAIPanel = true
        let topicId = String(topic.id)
        Task {
            let result: String
            do {
                result = kind == .summarize
                    ? try await api.ai_summarize(topic_id: topicId)
                    : try await api.ai_translate(topic_id: topicId)
            } catch {
                result = ""
                await MainActor.run { self.statusLine = "\(kind == .summarize ? "Summary" : "Translation") failed: \(error)" }
            }
            await MainActor.run {
                self.aiLoading = false
                if result.isEmpty {
                    self.showAIPanel = false
                } else {
                    self.aiPanelText = result
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
        // A scope switch also drops any in-flight thread open: the list
        // is being rebuilt, so its rows' reader must not fill late.
        invalidateTopicLoad()
        do {
            switch scope {
            case .latest:
                let rows = try await api.latest_list(page: 0, fresh: fresh)
                topics = rows.map(Self.topic(fromLatest:))
            case .notifications:
                let rows = try await api.notifications_list()
                notifications = rows.map(Self.notification(from:))
                // the forum marks notifications read on view; mirror that
                try? await api.notifications_mark_read()
            case .category(let id, let slug):
                let rows = try await api.category_topics_list(slug: slug, id: String(id))
                topics = rows.map(Self.topic(fromLatest:))
            }
            selectedTopic = nil
            posts = []
            postsTotal = 0
            if searchResults.isEmpty == false { searchResults = [] }
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
    ///
    /// Navigation contract: the previous thread's posts are NOT kept on
    /// screen while the new one loads — the header switches to the new
    /// topic immediately and the pane shows a spinner, so stale content
    /// can never sit under a new header. The load captures the
    /// generation at request start; posts/total/error writes from a
    /// superseded generation are dropped (issue #2: delayed topic A must
    /// not clear or overwrite topic B).
    func openTopicId(_ id: Int, title: String) async {
        invalidateTopicLoad()
        let generation = topicLoadGeneration
        selectedTopic = TopicRow(id: id, title: title, categoryId: 0,
                                 postsCount: 0, replyCount: 0, views: 0,
                                 likeCount: 0, lastPosted: "")
        guard let api else { return }
        loadingPosts = true
        defer { if generation == topicLoadGeneration { loadingPosts = false } }
        do {
            let rows = try await api.topic_open(id: String(id))
            guard generation == topicLoadGeneration else { return }
            posts = rows.compactMap(Self.post(from:))
            postsTotal = Self.postsTotal(from: rows)
            statusLine = ""
        } catch {
            guard generation == topicLoadGeneration else { return }
            posts = []
            postsTotal = 0
            topicLoadError = "Couldn't open the topic: \(error)"
        }
    }

    /// Retry the open thread in place. The sidebar selection and scroll
    /// position are untouched (the topic list is not rewritten), and a
    /// draft reply for the thread survives in replyDrafts.
    func retryOpenTopic() {
        guard let topic = selectedTopic else { return }
        Task { await openTopicId(topic.id, title: topic.title) }
    }

    /// Back to the list: drop the selection and any in-flight load, so a
    /// late response cannot repopulate the closed reader.
    func closeTopic() {
        invalidateTopicLoad()
        selectedTopic = nil
        posts = []
        postsTotal = 0
    }

    /// Bumps the load identity so every in-flight open completes as
    /// stale; clears the transient load UI it owns.
    private func invalidateTopicLoad() {
        topicLoadGeneration += 1
        loadingPosts = false
        topicLoadError = nil
    }

    /// The draft saved for this thread, if any.
    func draftReply(for topic: TopicRow) -> String {
        replyDrafts[topic.id] ?? ""
    }

    /// Keeps the composer's text across dismissals, failures and topic
    /// switches; an emptied draft is forgotten.
    func saveDraftReply(_ raw: String, for topic: TopicRow) {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            replyDrafts.removeValue(forKey: topic.id)
        } else {
            replyDrafts[topic.id] = raw
        }
    }

    /// The whole thread for the reader's "load all" bar. Deliberately
    /// not published: the webview appends the tail in place, and a posts
    /// update would reload the document and throw the scroll away.
    /// Returns every post; the caller drops the ones already rendered.
    func fetchAllPosts() async -> [PostRow]? {
        guard let id = selectedTopic?.id, let api else { return nil }
        let generation = topicLoadGeneration
        do {
            let rows = try await api.topic_posts_all(id: String(id))
            // a superseded load-all (topic switched meanwhile) must not
            // move this thread's total
            guard generation == topicLoadGeneration else { return nil }
            postsTotal = Self.postsTotal(from: rows)
            return rows.compactMap(Self.post(from:))
        } catch {
            guard generation == topicLoadGeneration else { return nil }
            statusLine = "Couldn't load the whole thread: \(error)"
            return nil
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
        // topic-post row = (author avatar-url cooked-html created-at
        //                   post-number post-id like-count liked posts-total)
        guard row.count >= 5 else { return nil }
        return PostRow(
            number: Int(row[4]) ?? 0,
            author: row[0],
            avatarURL: row[1],
            html: row[2],
            createdAt: row[3],
            postId: row.count > 5 ? Int(row[5]) ?? 0 : 0,
            likeCount: row.count > 6 ? Int(row[6]) ?? 0 : 0,
            liked: row.count > 7 && row[7] == "1")
    }

    private static func postsTotal(from rows: [[String]]) -> Int {
        rows.first.flatMap { $0.count > 8 ? Int($0[8]) ?? 0 : 0 } ?? 0
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
