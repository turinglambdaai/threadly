import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: ThreadlyStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if model.ready {
                DetailView()
            } else {
                bootPlaceholder
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .navigationTitle("Threadly")
    }

    private var bootPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.bootStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Bottom strip: update banner when one is available, an "up to date"
    /// acknowledgement after a manual check, backend failures surface here
    /// too (notify events), quiet when everything is fine.
    private var statusBar: some View {
        VStack(spacing: 0) {
            if let manifest = model.pendingUpdateManifest {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(DesignTokens.accent)
                    Text("Threadly \(manifest.version) is available.")
                        .font(.callout)
                    Button("Install and Relaunch") {
                        Task { await model.installUpdate(manifest) }
                    }
                    .controlSize(.small)
                    Button("Not now") { model.updateOutcome = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(DesignTokens.accentSoft)
            } else if isUpToDate {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Threadly is up to date.")
                        .font(.callout)
                    Spacer()
                    Button("Dismiss") { model.updateOutcome = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
            if store.statusLine.isEmpty == false {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(store.statusLine)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { store.statusLine = "" }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    private var isUpToDate: Bool {
        if case .success(.upToDate) = model.updateOutcome {
            return true
        }
        return false
    }
}

// MARK: - Shared bits

/// Discourse-authentic category chip: the forum's own color as tint.
private struct CategoryChip: View {
    let name: String
    let color: Color?

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color ?? Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((color ?? Color.secondary).opacity(0.14), in: Capsule())
    }
}

/// Compact icon+number count row (SF Symbols, secondary color).
private struct CountStrip: View {
    let counts: [(symbol: String, value: Int)]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(counts, id: \.symbol) { count in
                HStack(spacing: 3) {
                    Image(systemName: count.symbol)
                    Text("\(count.value)")
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .imageScale(.small)
        .monospacedDigit()
    }
}

// MARK: - Sidebar

/// What a sidebar row is: a browsing scope (Latest / a category) or a
/// topic. One selection binding drives both the scope switch and the
/// thread reader.
enum SidebarItem: Hashable {
    case scope(ThreadlyStore.Scope)
    case topic(Int)
}

extension ThreadlyStore.Scope {
    var label: String {
        switch self {
        case .latest: return "Latest"
        case .notifications: return "Notifications"
        case .category(_, let slug): return slug
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var store: ThreadlyStore
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            List(selection: selectionBinding) {
            // --- Browse: the Discourse information architecture — the
            // forum first, then its categories in the forum's own order.
            Section("Browse") {
                if store.signedInUser != nil {
                    Label("Notifications", systemImage: "bell.fill")
                        .tag(SidebarItem.scope(.notifications))
                }
                Label("Latest", systemImage: "tray.2")
                    .tag(SidebarItem.scope(.latest))
                ForEach(store.categories) { category in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(category.color ?? Color.secondary)
                            .frame(width: 9, height: 9)
                        Text(category.name)
                    }
                    .tag(SidebarItem.scope(category.scope))
                }
            }

            // --- Topics: whatever the current scope returned.
            if store.isSearchActive {
                Section {
                    ForEach(store.displayTopics) { topic in
                        TopicListRow(topic: topic, searchResult: true)
                            .tag(SidebarItem.topic(topic.id))
                    }
                } header: {
                    HStack {
                        Text("\(store.displayTopics.count) results")
                        Spacer()
                        Button("Back to latest") {
                            searchText = ""
                            store.clearSearch()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
            } else if store.scope == .notifications {
                Section("Notifications") {
                    ForEach(store.notifications) { n in
                        NotificationListRow(row: n)
                            .tag(SidebarItem.topic(n.id))
                    }
                    if store.notifications.isEmpty {
                        Text("No notifications.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section(scopeTitle) {
                    ForEach(store.displayTopics) { topic in
                        TopicListRow(topic: topic, searchResult: false)
                            .tag(SidebarItem.topic(topic.id))
                    }
                    if store.displayTopics.isEmpty {
                        Text(store.loadingTopics
                             ? "Loading…"
                             : (scopeTitle == "Uncategorized"
                                ? "No topics — the forum keeps this category empty."
                                : "No topics here yet."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        }
        .safeAreaInset(edge: .bottom) { accountSection }
        .sheet(isPresented: signInSheetBinding) { SignInSheetView() }
        .listStyle(.sidebar)
        .frame(minWidth: 300)
        .onChange(of: searchText) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty,
               store.isSearchActive {
                store.clearSearch()
            }
        }
        .onChange(of: store.scope) { _, newScope in
            Task { await store.load(scope: newScope) }
        }
    }

    /// Pinned above the scrolling list — the searchable field used to
    /// scroll away with the topic list, leaving no way to search.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search the archive", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit {
                    Task { await store.search(searchText) }
                }
            if searchText.isEmpty == false {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// Sidebar footer: sign-in state. Signed out → one-click start; the
    /// forum approval page opens in the browser and the paste-code sheet
    /// appears here. Signed in → username + sign out.
    private var accountSection: some View {
        Group {
            if let user = store.signedInUser {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(DesignTokens.accent)
                    Text(user)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Sign out") { store.signOut() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            } else if store.signInStage == .idle {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Button("Sign in with racket.discourse") { store.beginSignIn() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    private var signInSheetBinding: Binding<Bool> {
        Binding(get: { store.signInStage == .awaitingCode },
                set: { if !$0 { store.cancelSignIn() } })
    }

    private var scopeTitle: String {
        switch store.scope {
        case .latest:
            return "Latest"
        case .notifications:
            return "Notifications"
        case .category(let id, _):
            return store.categoryName(id)
        }
    }

    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: {
                // a selected topic wins; otherwise reflect the scope row
                if let topic = store.selectedTopic {
                    return .topic(topic.id)
                }
                return .scope(store.scope)
            },
            set: { item in
                switch item {
                case .scope(let scope):
                    if scope != store.scope || store.isSearchActive {
                        searchText = ""
                        store.clearSearch()
                        // onChange(of: store.scope) drives the load; fire
                        // directly for same-scope reloads (Latest row)
                        if scope == store.scope {
                            Task { await store.load(scope: scope) }
                        } else {
                            store.scope = scope
                        }
                    }
                case .topic(let id):
                    if store.scope == .notifications {
                        // a notification row: open its linked topic
                        if let n = store.notifications.first(where: { $0.id == id }),
                           let topicId = n.topicId {
                            Task { await store.openTopicId(topicId,
                                                           title: n.text) }
                        }
                    } else if let topic = store.displayTopics.first(where: { $0.id == id }) {
                        Task { await store.openTopic(topic) }
                    }
                case .none:
                    break
                }
            }
        )
    }
}

private struct TopicListRow: View {
    @EnvironmentObject private var store: ThreadlyStore
    let topic: TopicRow
    let searchResult: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 8) {
                if searchResult {
                    // search rows carry dates, not category ids
                    Text(Self.shortDate(topic.lastPosted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    CountStrip(counts: [
                        (symbol: "bubble.right", value: topic.postsCount)
                    ])
                } else {
                    let category = store.categoryName(topic.categoryId)
                    if category.isEmpty == false {
                        CategoryChip(
                            name: category,
                            color: store.categoryColor(topic.categoryId)
                        )
                    }
                    CountStrip(counts: [
                        (symbol: "bubble.right", value: topic.replyCount),
                        (symbol: "eye", value: topic.views),
                        (symbol: "heart", value: topic.likeCount)
                    ])
                }
            }
        }
        .padding(.vertical, 2)
    }

    private static func shortDate(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        let formatter = ThreadWebView.displayFormatter
        if let date = ThreadWebView.isoFormatter.date(from: iso) {
            return formatter.string(from: date)
        }
        return iso
    }
}

private struct NotificationListRow: View {
    let row: ThreadlyStore.NotificationRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.symbol)
                .foregroundStyle(DesignTokens.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.text)
                    .font(.callout)
                    .lineLimit(2)
                if row.createdAt.isEmpty == false {
                    Text(row.createdAt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

private struct DetailView: View {
    @EnvironmentObject private var store: ThreadlyStore

    var body: some View {
        Group {
            if let topic = store.selectedTopic {
                topicDetail(topic)
            } else if store.displayTopics.isEmpty && !store.loadingTopics {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "tray",
                    description: Text("This view has no topics right now. Pick another category, or search the archive.")
                )
            } else {
                ContentUnavailableView(
                    "Select a topic",
                    systemImage: "sidebar.left",
                    description: Text("Pick a thread from the sidebar to read it here.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            if let topic = store.selectedTopic {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.replySheetTopic = topic
                    } label: {
                        Label("Reply", systemImage: "text.bubble")
                    }
                    .disabled(store.replySheetTopic != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Link(destination: URL(string: "https://racket.discourse.group/t/\(topic.id)")!) {
                        Label("Open on the forum", systemImage: "safari")
                    }
                }
            }
        }
        .sheet(item: $store.replySheetTopic) { topic in
            ReplySheetView(topic: topic)
        }
    }

    private func topicDetail(_ topic: TopicRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    let category = store.categoryName(topic.categoryId)
                    if category.isEmpty == false {
                        CategoryChip(
                            name: category,
                            color: store.categoryColor(topic.categoryId)
                        )
                    }
                    CountStrip(counts: [
                        (symbol: "bubble.right", value: topic.postsCount),
                        (symbol: "eye", value: topic.views),
                        (symbol: "heart", value: topic.likeCount)
                    ])
                }
            }
            .padding()
            Divider()

            if store.loadingPosts {
                Spacer()
                ProgressView("Loading thread…")
                Spacer()
            } else if store.posts.isEmpty {
                Spacer()
                ContentUnavailableView(
                    "Empty thread",
                    systemImage: "text.bubble",
                    description: Text("No posts came back for this topic.")
                )
                Spacer()
            } else {
                ThreadWebView(
                    document: ThreadWebView.document(
                        title: topic.title,
                        posts: store.posts,
                        signedIn: store.signedInUser != nil
                    ),
                    store: store
                )
                .id(topic.id)
            }
        }
    }
}

// MARK: - Thread WebView

/// The whole thread renders as one HTML document in a single WKWebView —
/// the forum's own cooked HTML with a reader stylesheet, light and dark.
/// The like button rides a script-message bridge: JS posts "like:<id>",
/// the host runs the RPC, and the result is applied back with
/// threadlyLiked() so the button always reflects the server.
struct ThreadWebView: NSViewRepresentable {
    let document: String
    let store: ThreadlyStore?

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.store = store
        view.configuration.userContentController.add(context.coordinator, name: "threadly")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastLoaded != document {
            context.coordinator.lastLoaded = document
            view.loadHTMLString(document, baseURL: URL(string: "https://racket.discourse.group"))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastLoaded: String?
        weak var view: WKWebView?
        var store: ThreadlyStore?

        /// Links should open in the user's browser, not navigate the reader.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        nonisolated func userContentController(_ userContentController: WKUserContentController,
                                               didReceive message: WKScriptMessage) {
            guard message.name == "threadly",
                  let text = message.body as? String,
                  text.hasPrefix("like:"),
                  let postId = Int(text.dropFirst(5)) else { return }
            Task { @MainActor in
                guard let store = self.store else { return }
                self.view?.evaluateJavaScript("threadlyLikePending(\(postId))", completionHandler: nil)
                store.likePost(postId) { ok in
                    self.view?.evaluateJavaScript("threadlyLiked(\(postId), \(ok))",
                                                  completionHandler: nil)
                }
            }
        }
    }

    /// The forum's cooked HTML is already sanitized server-side; this only
    /// escapes the surrounding metadata and wraps everything in a reader
    /// stylesheet that follows the system appearance. A 680px column keeps
    /// long paragraphs readable; avatars give each post a face. Signed in,
    /// every post grows a like button wired to the script-message bridge.
    static func document(title: String, posts: [PostRow], signedIn: Bool = false) -> String {
        let body = posts.map { post -> String in
            let avatar = post.avatarURL.isEmpty
                ? ""
                : "<img class=\"avatar\" src=\"\(escape(post.avatarURL))\" onerror=\"this.style.display='none'\">"
            let like = signedIn && post.postId > 0
                ? "<button class=\"like\" id=\"like-\(post.postId)\" onclick=\"threadlyLike(\(post.postId))\" title=\"Like this post\">♡</button>"
                : ""
            let meta = """
            <div class="meta">\(avatar)\
            <span class="author">\(escape(post.author))</span>\
            <span class="dot">·</span>\
            <span>#\(post.number)</span>\
            <span class="dot">·</span>\
            <span class="date">\(escape(formatDate(post.createdAt)))</span>\
            \(like)
            </div>
            """
            return "<section class=\"post\">\(meta)\(post.html)</section>"
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          font-size: 15px; line-height: 1.6;
          margin: 0 auto; padding: 22px 28px 48px;
          max-width: 680px;
          background: transparent;
        }
        .post {
          padding: 16px 0 8px;
          border-bottom: 1px solid rgba(128,128,128,.2);
        }
        .post:first-child { padding-top: 0; }
        .meta {
          display: flex; align-items: center; gap: 7px;
          font-size: 12px; color: rgba(128,128,128,.95);
          margin-bottom: 8px;
        }
        .avatar {
          width: 26px; height: 26px; border-radius: 50%;
          margin-right: 2px;
        }
        .meta .author { font-weight: 600; color: #C15F3C; }
        .meta .dot { opacity: .45; }
        .meta .like {
          margin-left: auto;
          background: none; border: none; cursor: pointer;
          font-size: 15px; line-height: 1;
          color: rgba(128,128,128,.75); padding: 2px 6px;
        }
        .meta .like:hover { color: #C15F3C; }
        .meta .like:disabled { opacity: .35; cursor: default; }
        .meta .like.liked { color: #E0413E; }
        h1,h2,h3 { line-height: 1.3; }
        pre, code {
          font-family: ui-monospace, "SF Mono", Menlo, monospace;
          font-size: 13px;
        }
        code {
          background: rgba(128,128,128,.14);
          padding: 1px 5px; border-radius: 4px;
        }
        pre {
          background: rgba(128,128,128,.12);
          padding: 12px 14px; border-radius: 8px;
          overflow-x: auto;
        }
        pre code { background: none; padding: 0; }
        blockquote {
          margin: 8px 0; padding: 2px 14px;
          border-left: 3px solid rgba(193,95,60,.55);
          color: rgba(128,128,128,1);
        }
        img { max-width: 100%; height: auto; border-radius: 6px; }
        a { color: #C15F3C; }
        aside.quote { border-left: 3px solid rgba(193,95,60,.55); margin: 8px 0;
          padding: 6px 12px; background: rgba(128,128,128,.08); border-radius: 6px; }
        </style></head>
        <body>\(body)
        <script>
        function threadlyLike(id) {
          window.webkit.messageHandlers.threadly.postMessage("like:" + id);
        }
        function threadlyLikePending(id) {
          var b = document.getElementById('like-' + id);
          if (b) b.disabled = true;
        }
        function threadlyLiked(id, ok) {
          var b = document.getElementById('like-' + id);
          if (!b) return;
          b.disabled = false;
          if (ok) { b.classList.add('liked'); b.textContent = '♥'; }
        }
        </script></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter = ISO8601DateFormatter()

    static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func formatDate(_ iso: String) -> String {
        if let date = isoFormatter.date(from: iso) {
            return displayFormatter.string(from: date)
        }
        if let date = fallbackFormatter.date(from: iso) {
            return displayFormatter.string(from: date)
        }
        return iso
    }
}


// MARK: - Reply composer

/// The reply sheet. Signed in → a raw-Markdown editor (Discourse posts are
/// markdown); signed out → a pointer to the sign-in flow in the sidebar
/// footer, with a one-click start. Cancel wins over everything.
private struct ReplySheetView: View {
    @EnvironmentObject private var store: ThreadlyStore
    let topic: TopicRow
    @State private var raw = ""
    @FocusState private var focused: Bool

    private var canSubmit: Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && store.postingReply == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reply")
                    .font(.title3.weight(.semibold))
                Text(topic.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(topic.title)
            }

            if store.signedInUser == nil {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Sign in with your racket.discourse.group account to post a reply.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Not now") { store.replySheetTopic = nil }
                            .keyboardShortcut(.cancelAction)
                        Button("Sign in") {
                            store.replySheetTopic = nil
                            store.beginSignIn()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(.top, 4)
            } else {
                TextEditor(text: $raw)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                    .overlay(alignment: .topLeading) {
                        if raw.isEmpty {
                            Text("Write your reply in Markdown…")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.top, 16)
                                .padding(.leading, 13)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($focused)

                HStack(spacing: 10) {
                    Text("Markdown · as \(store.signedInUser ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.postingReply {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Cancel") { store.replySheetTopic = nil }
                        .keyboardShortcut(.cancelAction)
                        .disabled(store.postingReply)
                    Button("Reply") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear { focused = true }
    }

    private func submit() {
        guard canSubmit else { return }
        store.submitReply(to: topic, raw: raw)
    }
}

// MARK: - Sign-in sheet

/// Shown while the forum approval page is open in the browser: the user
/// pastes the code Discourse displays after approval.
private struct SignInSheetView: View {
    @EnvironmentObject private var store: ThreadlyStore
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish signing in")
                .font(.title3.weight(.semibold))
            Text("Approve Threadly on the forum page that just opened, copy the code it shows, and paste it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Paste the code", text: $code)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
            HStack {
                Spacer()
                Button("Cancel") { store.cancelSignIn() }
                    .keyboardShortcut(.cancelAction)
                Button("Complete sign-in") {
                    store.completeSignIn(code: code)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { focused = true }
    }
}
