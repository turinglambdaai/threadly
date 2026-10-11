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

    /// Bottom strip: backend failures surface here (notify events), quiet
    /// when everything is fine.
    private var statusBar: some View {
        Group {
            if store.statusLine.isEmpty == false {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(store.statusLine)
                        .font(.caption)
                        .lineLimit(2)
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
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject private var store: ThreadlyStore
    @State private var searchText = ""

    var body: some View {
        List(selection: selectionBinding) {
            if store.isSearchActive {
                Section {
                    ForEach(store.displayTopics) { topic in
                        TopicListRow(topic: topic, store: store)
                            .tag(topic.id)
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
            } else {
                Section("Latest") {
                    ForEach(store.displayTopics) { topic in
                        TopicListRow(topic: topic, store: store)
                            .tag(topic.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 300)
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: "Search the archive"
        )
        .onSubmit(of: .search) {
            Task { await store.search(searchText) }
        }
        .onChange(of: searchText) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty,
               store.isSearchActive {
                store.clearSearch()
            }
        }
        .overlay {
            if store.loadingTopics && store.displayTopics.isEmpty {
                ProgressView("Loading topics…")
            } else if store.displayTopics.isEmpty {
                ContentUnavailableView(
                    "No topics",
                    systemImage: "text.bubble",
                    description: Text("The forum returned no topics.")
                )
            }
        }
    }

    private var selectionBinding: Binding<Int?> {
        Binding(
            get: { store.selectedTopic?.id },
            set: { id in
                guard let id,
                      let topic = store.displayTopics.first(where: { $0.id == id })
                else { return }
                Task { await store.openTopic(topic) }
            }
        )
    }
}

private struct TopicListRow: View {
    let topic: TopicRow
    let store: ThreadlyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(topic.title)
                .font(.body.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                let category = store.categoryName(topic.categoryId)
                if category.isEmpty == false {
                    Text(category)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(DesignTokens.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                }
                Text("\(topic.replyCount) replies")
                Text("\(topic.views) views")
                if topic.likeCount > 0 {
                    Label("\(topic.likeCount)", systemImage: "heart")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    Link(destination: URL(string: "https://racket.discourse.group/t/\(topic.id)")!) {
                        Label("Open on the forum", systemImage: "safari")
                    }
                }
            }
        }
    }

    private func topicDetail(_ topic: TopicRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(topic.title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    let category = store.categoryName(topic.categoryId)
                    if category.isEmpty == false {
                        Text(category)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(DesignTokens.accentSoft, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text("\(topic.postsCount) posts · \(topic.views) views · \(topic.likeCount) likes")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        posts: store.posts
                    )
                )
                .id(topic.id)
            }
        }
    }
}

// MARK: - Thread WebView

/// The whole thread renders as one HTML document in a single WKWebView —
/// the forum's own cooked HTML with a reader stylesheet, light and dark.
struct ThreadWebView: NSViewRepresentable {
    let document: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
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
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastLoaded: String?

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
    }

    /// The forum's cooked HTML is already sanitized server-side; this only
    /// escapes the surrounding metadata and wraps everything in a reader
    /// stylesheet that follows the system appearance.
    static func document(title: String, posts: [PostRow]) -> String {
        let body = posts.map { post -> String in
            let meta = """
            <div class="meta">
              <span class="author">\(escape(post.author))</span>
              <span class="dot">·</span>
              <span>#\(post.number)</span>
              <span class="dot">·</span>
              <span class="date">\(escape(formatDate(post.createdAt)))</span>
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
          font-size: 15px; line-height: 1.55;
          margin: 0; padding: 20px 28px 40px;
          background: transparent;
        }
        .post {
          padding: 14px 0 6px;
          border-bottom: 1px solid rgba(128,128,128,.22);
        }
        .post:first-child { padding-top: 0; }
        .meta { font-size: 12px; color: rgba(128,128,128,.9); margin-bottom: 6px; }
        .meta .author { font-weight: 600; color: #C15F3C; }
        .meta .dot { opacity: .5; }
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
        <body>\(body)</body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let fallbackFormatter = ISO8601DateFormatter()

    private static let displayFormatter: DateFormatter = {
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
