// Threadly Linux host — GTK4 + WebKitGTK reader over one embedded Racket
// CS backend. Layout mirrors the macOS shell: a sidebar of forum topics
// (search on top, list below) and a reader pane rendering the forum's own
// cooked HTML. Boot the runtime off the UI thread; dispatch every RPC
// completion and backend event back through g_idle_add before touching
// widgets. A generation counter drops completions from superseded loads
// (refresh during an in-flight search, topic switch during a slow fetch).
#include <gtk/gtk.h>
// webkitgtk 6.0 ships a lowercase umbrella header.
#include <jsc/jsc.h>
#include <webkit/webkit.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <utility>
#include <variant>
#include <vector>

#include "GeneratedBackend.hpp"
#include "system_services.hpp"
#include "theme.hpp"

namespace {

constexpr char kForumBase[] = "https://racket.discourse.group";
constexpr char kAccent[] = "#C15F3C";

struct TopicRow {
  std::int64_t id{0};
  std::string title;
  std::int64_t category_id{0};
  std::int64_t posts{0};
  std::int64_t replies{0};
  std::int64_t views{0};
  std::int64_t likes{0};
  std::string last_posted;
};

struct Category {
  std::string name;
  std::string slug;
  std::string color;  // bare hex from the forum, e.g. "0088CC"
};

using Rows = std::vector<std::vector<std::string>>;

struct AppState {
  GtkWindow* window{nullptr};
  GtkSearchEntry* search{nullptr};
  GtkButton* back_button{nullptr};
  GtkButton* refresh_button{nullptr};
  GtkButton* reply_button{nullptr};
  GtkButton* account_button{nullptr};
  GtkButton* summarize_button{nullptr};
  GtkButton* translate_button{nullptr};
  GtkDropDown* category_picker{nullptr};
  GtkLabel* scope_heading{nullptr};
  GtkListBox* topic_list{nullptr};
  GtkStack* reader{nullptr};
  WebKitWebView* web_view{nullptr};
  GtkLabel* status{nullptr};

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::unique_ptr<rivet_app::API> api;

  std::mutex startup_mutex;
  std::thread startup_thread;
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  std::string startup_error;
  std::atomic<bool> shutting_down{false};

  std::vector<TopicRow> topics;
  std::map<std::int64_t, Category> categories;
  bool notifications_active{false};
  // Ordered (id, name, slug) in the forum's own order; the drop-down's
  // selected index maps to this minus one (0 = Latest).
  std::vector<std::tuple<std::int64_t, std::string, std::string>> category_order;
  bool search_active{false};
  bool suppress_row_signal{false};
  bool suppress_category_signal{false};
  // Drops completions from superseded loads; every load bumps it.
  std::uint64_t generation{0};
  // M2 write path: identity gates the composer and like buttons; the
  // reader's current topic is what the composer targets.
  std::string signed_in_user;
  std::int64_t open_topic_id{0};
};

AppState g_state;

void perform_orderly_shutdown();

std::filesystem::path executable_path() {
  return std::filesystem::read_symlink("/proc/self/exe");
}

// Rivet keeps runtime/res beside the executable in development and packages.
struct RuntimeLayout {
  std::filesystem::path petite_boot;
  std::filesystem::path scheme_boot;
  std::filesystem::path racket_boot;
  std::filesystem::path core;
};

std::optional<RuntimeLayout> discover_runtime_layout() {
  std::filesystem::path const exe = executable_path();
  RuntimeLayout layout{
      exe.parent_path() / "runtime" / "petite.boot",
      exe.parent_path() / "runtime" / "scheme.boot",
      exe.parent_path() / "runtime" / "racket.boot",
      exe.parent_path() / "res" / "core.zo",
  };
  if (std::filesystem::exists(layout.petite_boot) &&
      std::filesystem::exists(layout.scheme_boot) &&
      std::filesystem::exists(layout.racket_boot) &&
      std::filesystem::exists(layout.core)) {
    return layout;
  }
  return std::nullopt;
}

// ---- text helpers ---------------------------------------------------------

std::string escape_markup(std::string const& text) {
  std::string out;
  out.reserve(text.size());
  for (char const c : text) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      default: out += c;
    }
  }
  return out;
}

std::string escape_html(std::string const& text) {
  std::string out;
  out.reserve(text.size());
  for (char const c : text) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      default: out += c;
    }
  }
  return out;
}

std::string compact_date(std::string const& iso) {
  return iso.size() >= 10 ? iso.substr(0, 10) : iso;
}

Category category_for(std::int64_t id) {
  auto const it = g_state.categories.find(id);
  if (it != g_state.categories.end()) return it->second;
  return {};
}

// ---- reader document ---------------------------------------------------------

// The thread reader: the forum's own cooked HTML with the family reader
// stylesheet, light and dark. Same 680px column and terracotta accents as
// the macOS shell. Signed in, every post grows a like button wired to the
// script-message bridge ("like:<id>" out, threadlyLiked() back in).
std::string reader_document(Rows const& posts, bool const signed_in) {
  std::string body;
  for (auto const& row : posts) {
    if (row.size() < 5) continue;
    // topic-post row = (author avatar-url cooked-html created-at
    //                   post-number post-id)
    std::string const& author = row[0];
    std::string const& avatar = row[1];
    std::string const& cooked = row[2];
    std::string const date = compact_date(row[3]);
    std::string like;
    if (signed_in && row.size() >= 6) {
      // topic-post rows carry the forum's like state (count + acted flag)
      bool const liked = row.size() >= 8 && row[7] == "1";
      std::string const count =
          row.size() >= 7 && row[6] != "0"
              ? "<span class=\"count\">" + row[6] + "</span>"
              : "";
      like = "<button class=\"like" + std::string(liked ? " liked" : "") +
             "\" id=\"like-" + row[5] + "\" onclick=\"threadlyLike(" +
             row[5] + ")\" title=\"Like this post\">" +
             (liked ? "&#9829;" : "&#9825;") + count + "</button>";
    } else if (row.size() >= 7 && row[6] != "0") {
      like = "<span class=\"count\">" + row[6] + " &#9829;</span>";
    }
    body += "<section class=\"post\"><div class=\"meta\">";
    if (!avatar.empty()) {
      body += "<img class=\"avatar\" src=\"" + escape_html(avatar) +
              "\" onerror=\"this.style.display='none'\">";
    }
    body += "<span class=\"author\">" + escape_html(author) + "</span>";
    body += "<span class=\"dot\">·</span><span>#" + row[4] + "</span>";
    if (!date.empty()) {
      body += "<span class=\"dot\">·</span><span>" + escape_html(date) +
              "</span>";
    }
    body += like;
    body += "</div>" + cooked + "</section>";
  }

  return std::string{R"HTML(<!doctype html>
<html><head><meta charset="utf-8"><style>
:root { color-scheme: light dark; }
body {
  font-family: "Adwaita Sans", Cantarell, -apple-system, "Segoe UI", sans-serif;
  font-size: 15px; line-height: 1.6;
  margin: 0 auto; padding: 22px 28px 48px;
  max-width: 680px;  background: transparent;
}
.post { padding: 16px 0 8px; border-bottom: 1px solid rgba(128,128,128,.2); }
.post:first-child { padding-top: 0; }
.meta {
  display: flex; align-items: center; gap: 7px;
  font-size: 12px; color: rgba(128,128,128,.95);
  margin-bottom: 8px;
}
.avatar { width: 26px; height: 26px; border-radius: 50%; margin-right: 2px; }
.meta .author { font-weight: 600; color: )HTML"} +
         kAccent + R"HTML(; }
.meta .dot { opacity: .45; }
.meta .like {
  margin-left: auto;
  background: none; border: none; cursor: pointer;
  font-size: 15px; line-height: 1;
  color: rgba(128,128,128,.75); padding: 2px 6px;
}
.meta .like:hover { color: )HTML" +
         kAccent + R"HTML(; }
.meta .like:disabled { opacity: .35; cursor: default; }
.meta .like.liked { color: #E0413E; }
.meta .like .count, .meta .count {
  font-size: 12px; margin-left: 3px;
  color: rgba(128,128,128,.95);
}
.meta .like.liked .count { color: #E0413E; }
h1,h2,h3 { line-height: 1.3; }
pre, code { font-family: "Adwaita Mono", ui-monospace, Menlo, monospace; font-size: 13px; }
code { background: rgba(128,128,128,.14); padding: 1px 5px; border-radius: 4px; }
pre { background: rgba(128,128,128,.12); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
pre code { background: none; padding: 0; }
blockquote { margin: 8px 0; padding: 2px 14px; border-left: 3px solid rgba(193,95,60,.55); color: rgba(128,128,128,1); }
img { max-width: 100%; height: auto; border-radius: 6px; }
a { color: )HTML" +
         kAccent + R"HTML(; }
aside.quote { border-left: 3px solid rgba(193,95,60,.55); margin: 8px 0; padding: 6px 12px; background: rgba(128,128,128,.08); border-radius: 6px; }
</style></head>
<body>)HTML" +
         body + R"HTML(
<script>
function threadlyLike(id) {
  var b = document.getElementById('like-' + id);
  if (b && b.classList.contains('liked')) return;  // already liked
  window.webkit.messageHandlers.threadly.postMessage("like:" + id);
}
function threadlyLikePending(id) {
  var b = document.getElementById('like-' + id);
  if (b) b.disabled = true;
}
function threadlyLiked(id, ok) {
  var b = document.getElementById('like-' + id);
  if (!b || !ok) return;
  b.disabled = false;
  b.classList.add('liked');
  var count = b.querySelector('.count');
  if (!count) {
    count = document.createElement('span');
    count.className = 'count';
    b.appendChild(count);
  }
  count.textContent = (parseInt(count.textContent || '0', 10) || 0) + 1;
  var heart = document.createTextNode('\u2665');
  b.insertBefore(heart, count);
}
</script></body></html>)HTML";
}

// ---- small UI state helpers ----------------------------------------------------

void status_show(std::string const& text) {
  gtk_label_set_text(g_state.status, text.c_str());
  gtk_widget_set_visible(GTK_WIDGET(g_state.status), !text.empty());
}

void reader_loading() { gtk_stack_set_visible_child_name(g_state.reader, "loading"); }

void reader_ready() { gtk_stack_set_visible_child_name(g_state.reader, "web"); }

void reader_welcome() { gtk_stack_set_visible_child_name(g_state.reader, "welcome"); }

// ---- sidebar rendering -----------------------------------------------------------

void apply_rows(std::vector<TopicRow> rows, bool const search_mode) {
  g_state.suppress_row_signal = true;
  for (GtkWidget* child = gtk_widget_get_first_child(GTK_WIDGET(g_state.topic_list));
       child != nullptr;) {
    GtkWidget* next = gtk_widget_get_next_sibling(child);
    gtk_list_box_remove(g_state.topic_list, child);
    child = next;
  }
  g_state.topics = std::move(rows);

  for (TopicRow const& topic : g_state.topics) {
    auto* row_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_widget_set_margin_top(row_box, 6);
    gtk_widget_set_margin_bottom(row_box, 6);
    gtk_widget_set_margin_start(row_box, 4);
    gtk_widget_set_margin_end(row_box, 4);

    auto* title = gtk_label_new(escape_markup(topic.title).c_str());
    gtk_label_set_use_markup(GTK_LABEL(title), TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(title), PANGO_ELLIPSIZE_END);
    gtk_label_set_lines(GTK_LABEL(title), 2);
    gtk_label_set_wrap(GTK_LABEL(title), TRUE);
    gtk_widget_set_halign(title, GTK_ALIGN_START);

    std::string counts;
    if (!search_mode) {
      Category const category = category_for(topic.category_id);
      if (!category.name.empty()) {
        std::string const color =
            category.color.empty() ? "888888" : category.color;
        counts += "<span foreground=\"#" + color + "\" size=\"x-small\"><b>" +
                  escape_markup(category.name) + "</b></span>   ";
      }
      counts += "<span size=\"x-small\">" + std::to_string(topic.replies) +
                " replies · " + std::to_string(topic.views) + " views";
      if (topic.likes > 0) {
        counts += " · " + std::to_string(topic.likes) + " likes";
      }
      counts += "</span>";
    } else {
      counts += "<span size=\"x-small\">" + std::to_string(topic.posts) +
                " posts · " + compact_date(topic.last_posted) + "</span>";
    }
    auto* meta = gtk_label_new(counts.c_str());
    gtk_label_set_use_markup(GTK_LABEL(meta), TRUE);
    gtk_widget_set_halign(meta, GTK_ALIGN_START);

    gtk_box_append(GTK_BOX(row_box), title);
    gtk_box_append(GTK_BOX(row_box), meta);

    auto* row = gtk_list_box_row_new();
    gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(row), row_box);
    gtk_list_box_append(g_state.topic_list, row);
  }
  g_state.suppress_row_signal = false;
}

void update_scope_heading();
void load_latest(bool fresh);
void load_category(std::int64_t id, std::string const& slug);
void load_notifications();
void open_topic(TopicRow const& topic);

// ---- completion plumbing -----------------------------------------------------------

using RowsResultPayload = std::pair<std::uint64_t, rivet_app::Result<Rows>>;

RowsResultPayload* wrap_result(std::uint64_t const generation,
                               rivet_app::Result<Rows>&& result) {
  return new RowsResultPayload(generation, std::move(result));
}

void apply_result(std::uint64_t const generation, Rows& rows,
                  bool const ok, std::string const& error) {
  (void)generation;
  std::vector<TopicRow> parsed;
  for (auto const& row : rows) {
    // latest row = (id title category-id posts-count reply-count views
    //               like-count last-posted-at)
    // search row = (id title created-at posts-count)
    if (row.size() < 4) continue;
    TopicRow topic;
    topic.id = std::strtoll(row[0].c_str(), nullptr, 10);
    topic.title = row[1];
    if (row.size() >= 8) {
      topic.category_id = std::strtoll(row[2].c_str(), nullptr, 10);
      topic.posts = std::strtoll(row[3].c_str(), nullptr, 10);
      topic.replies = std::strtoll(row[4].c_str(), nullptr, 10);
      topic.views = std::strtoll(row[5].c_str(), nullptr, 10);
      topic.likes = std::strtoll(row[6].c_str(), nullptr, 10);
      topic.last_posted = row[7];
    } else {
      topic.last_posted = row[2];
      topic.posts = std::strtoll(row[3].c_str(), nullptr, 10);
    }
    parsed.push_back(std::move(topic));
  }

  apply_rows(std::move(parsed), g_state.search_active);
  update_scope_heading();
  gtk_widget_set_visible(GTK_WIDGET(g_state.back_button),
                         g_state.search_active ? TRUE : FALSE);
  status_show("");
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.search), TRUE);
  // Auto-open the first row so the reader never sits empty.
  gtk_list_box_select_row(
      g_state.topic_list, gtk_list_box_get_row_at_index(g_state.topic_list, 0));
}

int on_rows_delivered(gpointer user_data) {
  std::unique_ptr<RowsResultPayload> payload(
      static_cast<RowsResultPayload*>(user_data));
  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    return G_SOURCE_REMOVE;
  }
  if (payload->first != g_state.generation) {
    return G_SOURCE_REMOVE;
  }
  try {
    Rows rows = payload->second.get();
    apply_result(payload->first, rows, true, "");
  } catch (std::exception const& error) {
    status_show(std::string{"Couldn't load topics: "} + error.what());
    reader_welcome();
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.search), TRUE);
  } catch (...) {
    status_show("Couldn't load topics: unknown backend failure");
    reader_welcome();
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.search), TRUE);
  }
  return G_SOURCE_REMOVE;
}

int on_categories_delivered(gpointer user_data) {
  std::unique_ptr<rivet_app::Result<Rows>> result(
      static_cast<rivet_app::Result<Rows>*>(user_data));
  try {
    g_state.suppress_category_signal = true;
    auto* model = GTK_STRING_LIST(gtk_drop_down_get_model(g_state.category_picker));
    gtk_string_list_append(model, "Latest");
    for (auto const& row : result->get()) {
      // category row = (id name slug color)
      if (row.size() < 3) continue;
      auto const id = std::strtoll(row[0].c_str(), nullptr, 10);
      Category category;
      category.name = row[1];
      category.slug = row[2];
      if (row.size() >= 4) category.color = row[3];
      g_state.categories[id] = category;
      g_state.category_order.emplace_back(id, row[1], row[2]);
      gtk_string_list_append(model, row[1].c_str());
    }
    g_state.suppress_category_signal = false;
    gtk_drop_down_set_selected(g_state.category_picker, 0);
  } catch (...) {
    g_state.suppress_category_signal = false;
    // Category names are decoration; a failure here never blocks browsing.
  }
  return G_SOURCE_REMOVE;
}

int on_posts_delivered(gpointer user_data) {
  std::unique_ptr<rivet_app::Result<Rows>> result(
      static_cast<rivet_app::Result<Rows>*>(user_data));
  try {
    std::string const document =
        reader_document(result->get(), !g_state.signed_in_user.empty());
    webkit_web_view_load_html(g_state.web_view, document.c_str(), kForumBase);
    reader_ready();
  } catch (std::exception const& error) {
    status_show(std::string{"Couldn't open the topic: "} + error.what());
    reader_ready();
  } catch (...) {
    status_show("Couldn't open the topic: unknown backend failure");
    reader_ready();
  }
  return G_SOURCE_REMOVE;
}

// ---- write path helpers (likes, composer, account) -------------------------------

void run_reader_js(std::string const& js) {
  if (g_state.web_view == nullptr) return;
  webkit_web_view_evaluate_javascript(g_state.web_view, js.c_str(),
                                      static_cast<gssize>(js.size()), nullptr,
                                      nullptr, nullptr, nullptr, nullptr);
}

void update_write_ui() {
  if (g_state.reply_button != nullptr) {
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.reply_button),
                             !g_state.signed_in_user.empty() &&
                                     g_state.open_topic_id != 0
                                 ? TRUE
                                 : FALSE);
  }
  if (g_state.account_button != nullptr) {
    gtk_widget_set_tooltip_text(
        GTK_WIDGET(g_state.account_button),
        g_state.signed_in_user.empty()
            ? "Sign in with racket.discourse.group"
            : ("Signed in as " + g_state.signed_in_user +
               " (click to sign out)")
                  .c_str());
  }
}

int on_like_delivered(gpointer user_data) {
  std::unique_ptr<std::pair<std::int64_t, bool>> payload(
      static_cast<std::pair<std::int64_t, bool>*>(user_data));
  if (!g_state.shutting_down.load(std::memory_order_acquire)) {
    run_reader_js("threadlyLiked(" + std::to_string(payload->first) + "," +
                  (payload->second ? "true" : "false") + ")");
    if (!payload->second) status_show("Couldn't like that post.");
  }
  return G_SOURCE_REMOVE;
}

void like_post(std::int64_t const post_id) {
  if (g_state.api == nullptr || g_state.signed_in_user.empty()) return;
  run_reader_js("threadlyLikePending(" + std::to_string(post_id) + ")");
  (void)g_state.api->like_post_async(
      std::to_string(post_id), [post_id](rivet_app::Result<bool> result) mutable {
        bool ok = false;
        try {
          ok = result.get();
        } catch (...) {
        }
        g_idle_add(
            [](gpointer user_data) -> int { return on_like_delivered(user_data); },
            new std::pair<std::int64_t, bool>(post_id, ok));
      });
}

// The reader page posts "like:<id>" from the per-post button.
void on_script_message(WebKitUserContentManager*, JSCValue* value, gpointer) {
  if (value == nullptr || !jsc_value_is_string(value)) return;
  char* text = jsc_value_to_string(value);
  std::string const message = text != nullptr ? text : "";
  g_free(text);
  if (message.rfind("like:", 0) == 0) {
    like_post(std::strtoll(message.c_str() + 5, nullptr, 10));
  }
}

int on_auth_status_delivered(gpointer user_data) {
  std::unique_ptr<rivet_app::Result<rivet_app::AuthStatus>> result(
      static_cast<rivet_app::Result<rivet_app::AuthStatus>*>(user_data));
  try {
    auto const status = result->get();
    g_state.signed_in_user =
        status.status == "in" ? status.username : std::string{};
  } catch (...) {
    // identity is decoration at startup; flows surface errors
  }
  update_write_ui();
  return G_SOURCE_REMOVE;
}

void load_auth_status() {
  if (g_state.api == nullptr) return;
  (void)g_state.api->auth_status_async([](rivet_app::Result<rivet_app::AuthStatus> result) mutable {
    g_idle_add(
        [](gpointer user_data) -> int { return on_auth_status_delivered(user_data); },
        new rivet_app::Result<rivet_app::AuthStatus>(std::move(result)));
  });
}

int on_simple_status_delivered(gpointer user_data) {
  std::unique_ptr<std::string> message(static_cast<std::string*>(user_data));
  if (!g_state.shutting_down.load(std::memory_order_acquire)) {
    status_show(*message);
  }
  load_auth_status();  // re-sync identity/tooltip after account changes
  return G_SOURCE_REMOVE;
}

int on_paste_code(gpointer user_data) {
  // Modal paste sheet: the browser holds the approval page and code.
  std::unique_ptr<std::string> url(static_cast<std::string*>(user_data));
  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    return G_SOURCE_REMOVE;
  }
  GtkWidget* paste = gtk_window_new();
  gtk_window_set_transient_for(GTK_WINDOW(paste), g_state.window);
  gtk_window_set_modal(GTK_WINDOW(paste), TRUE);
  gtk_window_set_title(GTK_WINDOW(paste), "Finish signing in");
  gtk_window_set_default_size(GTK_WINDOW(paste), 480, 140);
  gtk_window_set_resizable(GTK_WINDOW(paste), FALSE);

  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_margin_top(box, 14);
  gtk_widget_set_margin_start(box, 14);
  gtk_widget_set_margin_end(box, 14);
  gtk_widget_set_margin_bottom(box, 14);
  auto* label = gtk_label_new(
      "Approve Threadly in the browser that just opened, copy the code it "
      "shows, and paste it here.");
  gtk_label_set_wrap(GTK_LABEL(label), TRUE);
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  auto* entry = gtk_entry_new();
  // placeholder-text as a property — the setter's availability differs
  // across GTK 4 minor versions (same reason the search entry uses this).
  g_object_set(entry, "placeholder-text", "Paste the code", nullptr);
  auto* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_halign(buttons, GTK_ALIGN_END);
  auto* cancel = gtk_button_new_with_label("Cancel");
  auto* ok = gtk_button_new_with_label("Complete sign-in");
  gtk_widget_add_css_class(ok, "suggested-action");
  gtk_box_append(GTK_BOX(buttons), cancel);
  gtk_box_append(GTK_BOX(buttons), ok);
  gtk_box_append(GTK_BOX(box), label);
  gtk_box_append(GTK_BOX(box), entry);
  gtk_box_append(GTK_BOX(box), buttons);
  gtk_window_set_child(GTK_WINDOW(paste), box);

  struct PasteContext {
    GtkWidget* window;
    GtkWidget* entry;
  };
  auto* context = new PasteContext{paste, entry};
  g_signal_connect_data(
      ok, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer user_data) {
        auto* context = static_cast<PasteContext*>(user_data);
        gchar const* text = gtk_editable_get_text(GTK_EDITABLE(context->entry));
        std::string const code = text != nullptr ? text : "";
        gtk_window_destroy(GTK_WINDOW(context->window));
        if (g_state.api == nullptr ||
            code.find_first_not_of(" \t\r\n") == std::string::npos) {
          return;
        }
        (void)g_state.api->auth_complete_async(
            code, [](rivet_app::Result<std::string> result) mutable {
              std::string message;
              try {
                (void)result.get();
                message = "Signed in. You can now reply and like posts.";
              } catch (std::exception const& error) {
                message = std::string{"Sign-in failed: "} + error.what();
              }
              g_idle_add(
                  [](gpointer user_data) -> int {
                    return on_simple_status_delivered(user_data);
                  },
                  new std::string(std::move(message)));
            });
      }),
      context, [](gpointer user_data, GClosure*) { delete static_cast<PasteContext*>(user_data); },
      GConnectFlags(0));
  g_signal_connect_swapped(cancel, "clicked",
                           G_CALLBACK(gtk_window_destroy), paste);
  gtk_window_present(GTK_WINDOW(paste));
  return G_SOURCE_REMOVE;
}

int on_sign_in_url(gpointer user_data) {
  std::unique_ptr<std::string> url(static_cast<std::string*>(user_data));
  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    return G_SOURCE_REMOVE;
  }
  // The browser open rides the backend's open-url event (auth-begin both
  // fires it and returns the URL); this only opens the paste sheet.
  g_idle_add(on_paste_code, new std::string(*url));
  return G_SOURCE_REMOVE;
}

int on_sign_out_confirmed(gpointer) {
  if (g_state.api != nullptr) {
    (void)g_state.api->auth_sign_out_async(
        [](rivet_app::Result<void> result) mutable {
          std::string message;
          try {
            result.get();
            message = "Signed out.";
          } catch (std::exception const& error) {
            message = std::string{"Sign-out failed: "} + error.what();
          }
          g_idle_add(
              [](gpointer user_data) -> int {
                return on_simple_status_delivered(user_data);
              },
              new std::string(std::move(message)));
        });
  }
  return G_SOURCE_REMOVE;
}

void on_account_clicked(GtkButton*, gpointer) {
  if (g_state.api == nullptr) return;
  if (!g_state.signed_in_user.empty()) {
    // confirm, then sign out
    GtkWidget* confirm = gtk_message_dialog_new(
        g_state.window, GTK_DIALOG_MODAL, GTK_MESSAGE_QUESTION,
        GTK_BUTTONS_OK_CANCEL, "Sign out of %s?", g_state.signed_in_user.c_str());
    gtk_message_dialog_format_secondary_text(
        GTK_MESSAGE_DIALOG(confirm),
        "You will not be able to reply or like until you sign in again.");
    gtk_window_set_title(GTK_WINDOW(confirm), "Sign out");
    g_signal_connect(
        confirm, "response",
        G_CALLBACK(+[](GtkDialog* dialog, gint response, gpointer) {
          gtk_window_destroy(GTK_WINDOW(dialog));
          if (response == GTK_RESPONSE_OK) {
            g_idle_add(on_sign_out_confirmed, nullptr);
          }
        }),
        nullptr);
    gtk_window_present(GTK_WINDOW(confirm));
    return;
  }
  (void)g_state.api->auth_begin_async(
      [](rivet_app::Result<std::string> result) mutable {
        std::string url;
        std::string error;
        try {
          url = result.get();
        } catch (std::exception const& e) {
          error = e.what();
        }
        if (!error.empty()) {
          g_idle_add(
              [](gpointer user_data) -> int {
                return on_simple_status_delivered(user_data);
              },
              new std::string("Sign-in failed: " + error));
          return;
        }
        g_idle_add(
            [](gpointer user_data) -> int { return on_sign_in_url(user_data); },
            new std::string(std::move(url)));
      });
}

int on_reply_result_delivered(gpointer user_data) {
  std::unique_ptr<std::string> error(static_cast<std::string*>(user_data));
  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    return G_SOURCE_REMOVE;
  }
  if (error->empty()) {
    status_show("Reply posted.");
    // reload the thread so the new post appears
    for (TopicRow const& topic : g_state.topics) {
      if (topic.id == g_state.open_topic_id) {
        open_topic(topic);
        break;
      }
    }
  } else {
    status_show("Reply failed: " + *error);
  }
  return G_SOURCE_REMOVE;
}

int on_reply_composer(gpointer) {
  if (g_state.shutting_down.load(std::memory_order_acquire) ||
      g_state.open_topic_id == 0 || g_state.signed_in_user.empty()) {
    return G_SOURCE_REMOVE;
  }
  GtkWidget* composer = gtk_window_new();
  gtk_window_set_transient_for(GTK_WINDOW(composer), g_state.window);
  gtk_window_set_modal(GTK_WINDOW(composer), TRUE);
  gtk_window_set_title(GTK_WINDOW(composer), "Reply");
  gtk_window_set_default_size(GTK_WINDOW(composer), 560, 320);

  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_margin_top(box, 14);
  gtk_widget_set_margin_start(box, 14);
  gtk_widget_set_margin_end(box, 14);
  gtk_widget_set_margin_bottom(box, 14);
  auto* label = gtk_label_new(
      ("Posting as " + g_state.signed_in_user +
       ". Discourse posts are Markdown.")
          .c_str());
  gtk_label_set_xalign(GTK_LABEL(label), 0.0);
  auto* scrolled = gtk_scrolled_window_new();
  gtk_widget_set_vexpand(scrolled, TRUE);
  auto* text_view = gtk_text_view_new();
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(text_view), GTK_WRAP_WORD_CHAR);
  gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(text_view)),
                           "", 0);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), text_view);
  auto* buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  gtk_widget_set_halign(buttons, GTK_ALIGN_END);
  auto* cancel = gtk_button_new_with_label("Cancel");
  auto* ok = gtk_button_new_with_label("Reply");
  gtk_widget_add_css_class(ok, "suggested-action");
  gtk_box_append(GTK_BOX(buttons), cancel);
  gtk_box_append(GTK_BOX(buttons), ok);
  gtk_box_append(GTK_BOX(box), label);
  gtk_box_append(GTK_BOX(box), scrolled);
  gtk_box_append(GTK_BOX(box), buttons);
  gtk_window_set_child(GTK_WINDOW(composer), box);

  struct ReplyContext {
    GtkWidget* window;
    GtkTextView* text_view;
  };
  auto* context = new ReplyContext{composer, GTK_TEXT_VIEW(text_view)};
  g_signal_connect_data(
      ok, "clicked",
      G_CALLBACK(+[](GtkButton*, gpointer user_data) {
        auto* context = static_cast<ReplyContext*>(user_data);
        auto* buffer = gtk_text_view_get_buffer(context->text_view);
        GtkTextIter begin;
        GtkTextIter end;
        gtk_text_buffer_get_bounds(buffer, &begin, &end);
        gchar* raw = gtk_text_buffer_get_text(buffer, &begin, &end, FALSE);
        std::string const body = raw != nullptr ? raw : "";
        g_free(raw);
        std::int64_t const topic_id = g_state.open_topic_id;
        gtk_window_destroy(GTK_WINDOW(context->window));
        if (g_state.api == nullptr ||
            body.find_first_not_of(" \t\r\n") == std::string::npos) {
          return;
        }
        (void)g_state.api->post_create_async(
            std::to_string(topic_id), body,
            [](rivet_app::Result<Rows> result) mutable {
              std::string error;
              try {
                (void)result.get();
              } catch (std::exception const& e) {
                error = e.what();
              }
              g_idle_add(
                  [](gpointer user_data) -> int {
                    return on_reply_result_delivered(user_data);
                  },
                  new std::string(std::move(error)));
            });
      }),
      context, [](gpointer user_data, GClosure*) { delete static_cast<ReplyContext*>(user_data); },
      GConnectFlags(0));
  g_signal_connect_swapped(cancel, "clicked",
                           G_CALLBACK(gtk_window_destroy), composer);
  gtk_window_present(GTK_WINDOW(composer));
  return G_SOURCE_REMOVE;
}

void on_reply_clicked(GtkButton*, gpointer) {
  g_idle_add(on_reply_composer, nullptr);
}

// ---- M3 reading value-add (summary, translation) ---------------------------

void set_ai_buttons_sensitive(gboolean const sensitive);

struct AIResult {
  GObject* label;      // strong ref — the window may already be closed
  GObject* spinner;
  std::string text;
};

int on_ai_delivered(gpointer user_data) {
  std::unique_ptr<AIResult> result(static_cast<AIResult*>(user_data));
  if (!g_state.shutting_down.load(std::memory_order_acquire)) {
    gtk_spinner_stop(GTK_SPINNER(result->spinner));
    gtk_label_set_text(GTK_LABEL(result->label), result->text.c_str());
    set_ai_buttons_sensitive(TRUE);
  }
  g_object_unref(result->label);
  g_object_unref(result->spinner);
  return G_SOURCE_REMOVE;
}

void set_ai_buttons_sensitive(gboolean const sensitive) {
  if (g_state.summarize_button != nullptr) {
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.summarize_button), sensitive);
  }
  if (g_state.translate_button != nullptr) {
    gtk_widget_set_sensitive(GTK_WIDGET(g_state.translate_button), sensitive);
  }
}

void run_ai(bool const summarize) {
  if (g_state.api == nullptr || g_state.open_topic_id == 0) return;
  GtkWidget* panel = gtk_window_new();
  gtk_window_set_transient_for(GTK_WINDOW(panel), g_state.window);
  gtk_window_set_modal(GTK_WINDOW(panel), TRUE);
  gtk_window_set_title(GTK_WINDOW(panel), summarize ? "Summary" : "Translation");
  gtk_window_set_default_size(GTK_WINDOW(panel), 560, 420);

  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_margin_top(box, 14);
  gtk_widget_set_margin_start(box, 14);
  gtk_widget_set_margin_end(box, 14);
  gtk_widget_set_margin_bottom(box, 14);
  auto* working = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  auto* spinner = gtk_spinner_new();
  gtk_spinner_start(GTK_SPINNER(spinner));
  auto* working_label =
      gtk_label_new(summarize ? "Asking the model\u2026" : "Translating\u2026");
  gtk_box_append(GTK_BOX(working), spinner);
  gtk_box_append(GTK_BOX(working), working_label);
  gtk_widget_set_halign(working, GTK_ALIGN_START);
  auto* scrolled = gtk_scrolled_window_new();
  gtk_widget_set_vexpand(scrolled, TRUE);
  auto* result_label = gtk_label_new("");
  gtk_label_set_selectable(GTK_LABEL(result_label), TRUE);
  gtk_label_set_wrap(GTK_LABEL(result_label), TRUE);
  gtk_label_set_xalign(GTK_LABEL(result_label), 0.0);
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), result_label);
  gtk_box_append(GTK_BOX(box), working);
  gtk_box_append(GTK_BOX(box), scrolled);
  gtk_window_set_child(GTK_WINDOW(panel), box);
  gtk_window_present(GTK_WINDOW(panel));

  set_ai_buttons_sensitive(FALSE);
  auto const topic_id = std::to_string(g_state.open_topic_id);
  // Strong refs: the panel may be closed before the answer lands, and
  // setting text on an unparented (still-referenced) label is harmless.
  auto* label_ref = G_OBJECT(g_object_ref(result_label));
  auto* spinner_ref = G_OBJECT(g_object_ref(spinner));
  auto const deliver = [label_ref, spinner_ref](std::string text) mutable {
    g_idle_add(
        [](gpointer user_data) -> int { return on_ai_delivered(user_data); },
        new AIResult{label_ref, spinner_ref, std::move(text)});
  };
  if (summarize) {
    (void)g_state.api->ai_summarize_async(
        topic_id, [deliver](rivet_app::Result<std::string> result) mutable {
          std::string text;
          try {
            auto const answer = result.get();
            text = answer.empty() ? "The model returned nothing." : answer;
          } catch (std::exception const& e) {
            text = std::string{"Failed: "} + e.what();
          }
          deliver(std::move(text));
        });
  } else {
    (void)g_state.api->ai_translate_async(
        topic_id, [deliver](rivet_app::Result<std::string> result) mutable {
          std::string text;
          try {
            auto const answer = result.get();
            text = answer.empty() ? "The model returned nothing." : answer;
          } catch (std::exception const& e) {
            text = std::string{"Failed: "} + e.what();
          }
          deliver(std::move(text));
        });
  }
}

void on_summarize_clicked(GtkButton*, gpointer) { run_ai(true); }

void on_translate_clicked(GtkButton*, gpointer) { run_ai(false); }

// ---- actions -------------------------------------------------------------------------

// Drop-down navigation: 0 = Latest, 1 = Notifications, n = category_order[n-2].
void on_picker_selected(GtkDropDown* dropdown, GParamSpec*, gpointer) {
  if (g_state.suppress_category_signal) return;
  auto const selected = gtk_drop_down_get_selected(dropdown);
  if (selected == GTK_INVALID_LIST_POSITION || selected == 0) {
    if (g_state.search_active ||
        !g_state.category_order.empty()) {
      load_latest(false);
    }
    return;
  }
  if (selected == 1) {
    load_notifications();
    return;
  }
  auto const slot = selected - 2;
  if (slot < g_state.category_order.size()) {
    auto const [id, name, slug] = g_state.category_order[slot];
    load_category(id, slug);
  }
}

void update_scope_heading() {
  if (g_state.scope_heading == nullptr) return;
  std::string title;
  if (g_state.search_active) {
    title = "Search results";
  } else if (g_state.category_order.empty()) {
    title = "Latest";
  } else {
    auto const selected = gtk_drop_down_get_selected(g_state.category_picker);
    if (selected == GTK_INVALID_LIST_POSITION || selected == 0) {
      title = "Latest";
    } else {
      title = std::get<1>(g_state.category_order[selected - 1]);
    }
  }
  gtk_label_set_markup(g_state.scope_heading,
                       ("<b>" + escape_markup(title) + "</b>").c_str());
}

void load_latest(bool const fresh) {
  if (g_state.api == nullptr) return;
  g_state.generation += 1;
  g_state.search_active = false;
  g_state.notifications_active = false;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.search), FALSE);
  (void)g_state.api->latest_list_async(
      0, fresh, [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_rows_delivered,
                   wrap_result(g_state.generation, std::move(result)));
      });
  // Categories load once; later refreshes reuse the drop-down contents.
  if (g_state.category_order.empty()) {
    (void)g_state.api->categories_list_async([](rivet_app::Result<Rows> result) {
      g_idle_add(on_categories_delivered,
                 new rivet_app::Result<Rows>(std::move(result)));
    });
  }
}

// A category page; same row shape as latest.
void load_category(std::int64_t const id, std::string const& slug) {
  if (g_state.api == nullptr) return;
  g_state.generation += 1;
  g_state.search_active = false;
  g_state.notifications_active = false;
  reader_loading();
  (void)g_state.api->category_topics_list_async(
      slug, std::to_string(id),
      [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_rows_delivered,
                   wrap_result(g_state.generation, std::move(result)));
      });
}

void run_search(std::string const& query) {
  if (g_state.api == nullptr) return;
  auto const first = query.find_first_not_of(" \t\n");
  if (first == std::string::npos) return;
  auto const last = query.find_last_not_of(" \t\n");
  std::string const trimmed = query.substr(first, last - first + 1);
  if (trimmed.empty()) return;

  g_state.generation += 1;
  g_state.search_active = true;
  g_state.notifications_active = false;
  reader_loading();
  (void)g_state.api->search_list_async(
      trimmed, [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_rows_delivered,
                   wrap_result(g_state.generation, std::move(result)));
      });
}

void open_topic(TopicRow const& topic) {
  if (g_state.api == nullptr) return;
  g_state.open_topic_id = topic.id;
  update_write_ui();
  reader_loading();
  (void)g_state.api->topic_open_async(
      std::to_string(topic.id), [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_posts_delivered,
                   new rivet_app::Result<Rows>(std::move(result)));
      });
}

// Signed-in notifications reuse the topic-row pipeline: id = the linked
// topic id (so a click opens the thread), title = "type — username · title".
void load_notifications() {
  if (g_state.api == nullptr) return;
  g_state.generation += 1;
  g_state.notifications_active = true;
  g_state.search_active = false;
  reader_loading();
  (void)g_state.api->notifications_list_async(
      [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_rows_delivered,
                   wrap_result(g_state.generation, std::move(result)));
        // the forum marks notifications read on view; mirror that
        if (g_state.api != nullptr) {
          (void)g_state.api->notifications_mark_read_async(
              [](rivet_app::Result<void>) {});
        }
      });
}

void on_row_selected(GtkListBox*, GtkListBoxRow* row, gpointer) {
  if (g_state.suppress_row_signal || row == nullptr) return;
  auto const index =
      static_cast<std::size_t>(gtk_list_box_row_get_index(row));
  if (index < g_state.topics.size()) {
    open_topic(g_state.topics[index]);
  }
}

void on_search_activate(GtkSearchEntry* entry, gpointer) {
  run_search(gtk_editable_get_text(GTK_EDITABLE(entry)));
}

void on_search_changed(GtkSearchEntry* entry, gpointer) {
  gchar const* text = gtk_editable_get_text(GTK_EDITABLE(entry));
  if ((text == nullptr || *text == '\0') && g_state.search_active) {
    load_latest(false);
  }
}

void on_back_clicked(GtkButton*, gpointer) {
  gtk_editable_set_text(GTK_EDITABLE(g_state.search), "");
  if (gtk_drop_down_get_selected(g_state.category_picker) != 0) {
    g_state.suppress_category_signal = true;
    gtk_drop_down_set_selected(g_state.category_picker, 0);
    g_state.suppress_category_signal = false;
  }
  load_latest(false);
}

void on_refresh_clicked(GtkButton*, gpointer) {
  if (g_state.search_active) {
    on_back_clicked(nullptr, nullptr);
  } else {
    load_latest(true);
  }
}

// ---- backend events ---------------------------------------------------------------------

int on_notify(gpointer user_data) {
  std::unique_ptr<std::string> message(static_cast<std::string*>(user_data));
  if (!g_state.shutting_down.load(std::memory_order_acquire)) {
    status_show(*message);
  }
  return G_SOURCE_REMOVE;
}

// ---- boot ---------------------------------------------------------------------------------

int on_backend_finished(gpointer) {
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }

  std::unique_ptr<rivet::linux_runtime::Backend> backend;
  std::string error;
  {
    std::lock_guard lock(g_state.startup_mutex);
    backend = std::move(g_state.startup_backend);
    error = std::move(g_state.startup_error);
  }

  if (g_state.shutting_down.load(std::memory_order_acquire)) {
    if (backend != nullptr) backend->stop();
    return G_SOURCE_REMOVE;
  }
  if (!error.empty()) {
    status_show("Backend error: " + error);
    return G_SOURCE_REMOVE;
  }
  if (backend == nullptr) {
    status_show("Backend error: startup completed without a backend");
    return G_SOURCE_REMOVE;
  }

  g_state.backend = std::move(backend);
  g_state.api = std::make_unique<rivet_app::API>(*g_state.backend);

  // racket_boot installs Racket CS signal handlers; install Rivet's shutdown
  // bridge after the Hello handshake so SIGTERM/SIGINT keep reaching the
  // native orderly close path.
  try {
    rivet::system::InstallShutdownHook(perform_orderly_shutdown);
  } catch (std::exception const& hook_error) {
    std::fputs((std::string{"shutdown hook unavailable: "} +
                hook_error.what() + "\n").c_str(), stderr);
  }

  // Backend events arrive on the reader thread; bounce to the main loop.
  g_state.backend->set_event_handler(
      [](std::string const& name, rivet::Value const& value) {
        try {
          auto const event = rivet_app::decode_event(name, value);
          if (std::holds_alternative<rivet_app::NotifyEvent>(event)) {
            g_idle_add(
                [](gpointer user_data) -> int { return on_notify(user_data); },
                new std::string(
                    std::get<rivet_app::NotifyEvent>(event).value));
          } else if (std::holds_alternative<rivet_app::Open_urlEvent>(event)) {
            // auth-begin and open-releases hand URLs over; open in the
            // user's browser.
            g_idle_add(
                [](gpointer user_data) -> int {
                  std::unique_ptr<std::string> url(
                      static_cast<std::string*>(user_data));
                  if (!g_state.shutting_down.load(std::memory_order_acquire)) {
                    (void)g_app_info_launch_default_for_uri(url->c_str(),
                                                           nullptr, nullptr);
                  }
                  return G_SOURCE_REMOVE;
                },
                new std::string(
                    std::get<rivet_app::Open_urlEvent>(event).value));
          }
        } catch (...) {
          // Unknown events are forward-compat; ignore.
        }
      });

  load_latest(false);
  load_auth_status();
  return G_SOURCE_REMOVE;
}

void start_backend() {
  auto layout = discover_runtime_layout();
  if (!layout.has_value()) {
    status_show(
        "Missing Rivet runtime layout (runtime/*.boot, res/core.zo) next to "
        "the executable. Build with raco rivet build/dev.");
    return;
  }

  rivet::linux_runtime::RacketRuntimeConfig config;
  config.executable_path = executable_path().string();
  config.petite_boot = layout->petite_boot.string();
  config.scheme_boot = layout->scheme_boot.string();
  config.racket_boot = layout->racket_boot.string();
  config.backend_bundle = layout->core.string();
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;

  g_state.startup_thread = std::thread([config = std::move(config)]() mutable {
    auto backend =
        std::make_unique<rivet::linux_runtime::Backend>(std::move(config));
    try {
      backend->start();
      {
        std::lock_guard lock(g_state.startup_mutex);
        g_state.startup_backend = std::move(backend);
      }
    } catch (std::exception const& e) {
      std::lock_guard lock(g_state.startup_mutex);
      g_state.startup_error = e.what();
    }
    g_idle_add(on_backend_finished, nullptr);
  });
}

// ---- UI construction -------------------------------------------------------------------------

GtkWidget* build_welcome() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
  gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
  auto* icon = gtk_image_new_from_icon_name("mail-thread-symbolic");
  gtk_image_set_pixel_size(GTK_IMAGE(icon), 48);
  auto* text = gtk_label_new("Select a topic to read it here.");
  gtk_widget_add_css_class(text, "dim-label");
  gtk_box_append(GTK_BOX(box), icon);
  gtk_box_append(GTK_BOX(box), text);
  return box;
}

GtkWidget* build_loading() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
  gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
  auto* spinner = gtk_spinner_new();
  gtk_spinner_start(GTK_SPINNER(spinner));
  auto* text = gtk_label_new("Loading…");
  gtk_widget_add_css_class(text, "dim-label");
  gtk_box_append(GTK_BOX(box), spinner);
  gtk_box_append(GTK_BOX(box), text);
  return box;
}

GtkWidget* build_sidebar() {
  auto* box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
  gtk_widget_set_margin_top(box, 10);
  gtk_widget_set_margin_start(box, 10);
  gtk_widget_set_margin_end(box, 10);
  gtk_widget_set_margin_bottom(box, 4);

  auto* header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
  auto* back = gtk_button_new_from_icon_name("go-previous-symbolic");
  gtk_widget_set_tooltip_text(back, "Back to latest");
  gtk_widget_set_visible(back, FALSE);
  auto* heading = gtk_label_new(nullptr);
  gtk_label_set_markup(GTK_LABEL(heading), "<b>Latest</b>");
  g_state.scope_heading = GTK_LABEL(heading);
  gtk_widget_set_halign(heading, GTK_ALIGN_START);
  gtk_widget_set_hexpand(heading, TRUE);
  auto* reply = gtk_button_new_from_icon_name("mail-reply-sender-symbolic");
  gtk_widget_set_tooltip_text(reply, "Reply to this topic");
  gtk_widget_set_sensitive(reply, FALSE);
  auto* account = gtk_button_new_from_icon_name("avatar-default-symbolic");
  gtk_widget_set_tooltip_text(account, "Sign in with racket.discourse.group");
  auto* summarize = gtk_button_new_with_label("Summarize");
  gtk_widget_set_tooltip_text(
      summarize, "AI summary of this thread (threadly ai-config)");
  gtk_widget_set_sensitive(summarize, FALSE);
  auto* translate = gtk_button_new_with_label("Translate");
  gtk_widget_set_tooltip_text(translate, "AI translation of this thread");
  gtk_widget_set_sensitive(translate, FALSE);
  auto* refresh = gtk_button_new_from_icon_name("view-refresh-symbolic");
  gtk_widget_set_tooltip_text(refresh, "Refresh");
  gtk_box_append(GTK_BOX(header), back);
  gtk_box_append(GTK_BOX(header), heading);
  gtk_box_append(GTK_BOX(header), summarize);
  gtk_box_append(GTK_BOX(header), translate);
  gtk_box_append(GTK_BOX(header), reply);
  gtk_box_append(GTK_BOX(header), account);
  gtk_box_append(GTK_BOX(header), refresh);
  g_state.back_button = GTK_BUTTON(back);
  g_state.refresh_button = GTK_BUTTON(refresh);
  g_state.reply_button = GTK_BUTTON(reply);
  g_state.account_button = GTK_BUTTON(account);
  g_state.summarize_button = GTK_BUTTON(summarize);
  g_state.translate_button = GTK_BUTTON(translate);
  g_signal_connect(reply, "clicked", G_CALLBACK(on_reply_clicked), nullptr);
  g_signal_connect(account, "clicked", G_CALLBACK(on_account_clicked), nullptr);
  g_signal_connect(summarize, "clicked", G_CALLBACK(on_summarize_clicked),
                   nullptr);
  g_signal_connect(translate, "clicked", G_CALLBACK(on_translate_clicked),
                   nullptr);

  // Discourse category navigation: a drop-down whose index 0 is Latest
  // and whose remaining entries are the forum's categories in order.
  auto* picker_model = gtk_string_list_new(nullptr);
  gtk_string_list_append(picker_model, "Latest");
  gtk_string_list_append(picker_model, "Notifications");
  auto* picker = gtk_drop_down_new(G_LIST_MODEL(picker_model), nullptr);
  gtk_widget_set_hexpand(picker, TRUE);

  auto* search = gtk_search_entry_new();
  // GtkSearchEntry exposes "placeholder-text" as a property (setter
  // availability differs across GTK 4 minor versions).
  g_object_set(search, "placeholder-text", "Search the archive", nullptr);
  gtk_widget_set_hexpand(search, TRUE);

  auto* scrolled = gtk_scrolled_window_new();
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scrolled),
                                 GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand(scrolled, TRUE);
  auto* list = gtk_list_box_new();
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(list), GTK_SELECTION_SINGLE);
  gtk_list_box_set_activate_on_single_click(GTK_LIST_BOX(list), TRUE);
  gtk_widget_add_css_class(list, "navigation-sidebar");
  gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scrolled), list);

  gtk_box_append(GTK_BOX(box), header);
  gtk_box_append(GTK_BOX(box), picker);
  gtk_box_append(GTK_BOX(box), search);
  gtk_box_append(GTK_BOX(box), scrolled);

  g_state.search = GTK_SEARCH_ENTRY(search);
  g_state.topic_list = GTK_LIST_BOX(list);
  g_state.category_picker = GTK_DROP_DOWN(picker);
  g_signal_connect(g_state.back_button, "clicked",
                   G_CALLBACK(on_back_clicked), nullptr);
  g_signal_connect(g_state.refresh_button, "clicked",
                   G_CALLBACK(on_refresh_clicked), nullptr);
  g_signal_connect(picker, "notify::selected",
                   G_CALLBACK(on_picker_selected), nullptr);
  return box;
}

void on_activate(GtkApplication* app, gpointer) {
  if (g_state.window != nullptr) {
    gtk_window_present(g_state.window);
    return;
  }

  // Pin the portal color scheme and theme-name variant to the same palette.
  (void)rivet::linux_ui::ApplyTheme();

  auto* window = gtk_application_window_new(app);
  gtk_window_set_title(GTK_WINDOW(window), "Threadly");
  gtk_window_set_default_size(GTK_WINDOW(window), 1100, 720);

  auto* pane = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL);
  gtk_paned_set_position(GTK_PANED(pane), 340);
  gtk_paned_set_start_child(GTK_PANED(pane), build_sidebar());
  gtk_paned_set_shrink_start_child(GTK_PANED(pane), FALSE);

  // The like bridge rides a named script message on the reader's content
  // manager; the JS side is the same window.webkit.messageHandlers API
  // Safari/WebView use.
  auto* content_manager = webkit_user_content_manager_new();
  webkit_user_content_manager_register_script_message_handler(
      content_manager, "threadly", nullptr);
  g_signal_connect(content_manager, "script-message-received::threadly",
                   G_CALLBACK(on_script_message), nullptr);
  auto* web = GTK_WIDGET(g_object_new(WEBKIT_TYPE_WEB_VIEW,
                                      "user-content-manager", content_manager,
                                      nullptr));
  auto* stack = gtk_stack_new();
  gtk_stack_add_named(GTK_STACK(stack), build_welcome(), "welcome");
  gtk_stack_add_named(GTK_STACK(stack), build_loading(), "loading");
  gtk_stack_add_named(GTK_STACK(stack), web, "web");
  gtk_paned_set_end_child(GTK_PANED(pane), stack);
  gtk_paned_set_shrink_end_child(GTK_PANED(pane), FALSE);

  auto* status = gtk_label_new("");
  gtk_widget_set_halign(status, GTK_ALIGN_START);
  gtk_widget_add_css_class(status, "dim-label");
  gtk_widget_set_margin_start(status, 10);
  gtk_widget_set_margin_bottom(status, 4);
  gtk_widget_set_visible(status, FALSE);
  gtk_label_set_ellipsize(GTK_LABEL(status), PANGO_ELLIPSIZE_END);

  auto* root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_box_append(GTK_BOX(root), pane);
  gtk_box_append(GTK_BOX(root), status);
  gtk_window_set_child(GTK_WINDOW(window), root);

  g_state.window = GTK_WINDOW(window);
  g_state.reader = GTK_STACK(stack);
  g_state.web_view = WEBKIT_WEB_VIEW(web);
  g_state.status = GTK_LABEL(status);

  g_signal_connect(g_state.topic_list, "row-selected",
                   G_CALLBACK(on_row_selected), nullptr);
  g_signal_connect(g_state.search, "activate", G_CALLBACK(on_search_activate),
                   nullptr);
  g_signal_connect(g_state.search, "search-changed",
                   G_CALLBACK(on_search_changed), nullptr);

  gtk_window_present(GTK_WINDOW(window));
  start_backend();
}

void on_shutdown(GApplication*, gpointer) {
  g_state.shutting_down.store(true, std::memory_order_release);
  if (g_state.startup_thread.joinable()) {
    g_state.startup_thread.join();
  }
  std::unique_ptr<rivet::linux_runtime::Backend> startup_backend;
  {
    std::lock_guard lock(g_state.startup_mutex);
    startup_backend = std::move(g_state.startup_backend);
  }
  if (startup_backend != nullptr) startup_backend->stop();
  if (g_state.backend != nullptr) g_state.backend->stop();
}

void perform_orderly_shutdown() { on_shutdown(nullptr, nullptr); }

}  // namespace

int main(int argc, char** argv) {
  auto* app = gtk_application_new("site.jrtx.threadly",
                                  G_APPLICATION_DEFAULT_FLAGS);
  g_signal_connect(app, "activate", G_CALLBACK(on_activate), nullptr);
  g_signal_connect(app, "shutdown", G_CALLBACK(on_shutdown), nullptr);
  int const status = g_application_run(G_APPLICATION(app), argc, argv);
  g_object_unref(app);
  return status;
}
