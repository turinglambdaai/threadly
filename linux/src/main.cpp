// Threadly Linux host — GTK4 + WebKitGTK reader over one embedded Racket
// CS backend. Layout mirrors the macOS shell: a sidebar of forum topics
// (search on top, list below) and a reader pane rendering the forum's own
// cooked HTML. Boot the runtime off the UI thread; dispatch every RPC
// completion and backend event back through g_idle_add before touching
// widgets. A generation counter drops completions from superseded loads
// (refresh during an in-flight search, topic switch during a slow fetch).
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

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
  std::string color;  // bare hex from the forum, e.g. "0088CC"
};

using Rows = std::vector<std::vector<std::string>>;

struct AppState {
  GtkWindow* window{nullptr};
  GtkSearchEntry* search{nullptr};
  GtkButton* back_button{nullptr};
  GtkButton* refresh_button{nullptr};
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
  bool search_active{false};
  bool suppress_row_signal{false};
  // Drops completions from superseded loads; every load bumps it.
  std::uint64_t generation{0};
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
// the macOS shell.
std::string reader_document(Rows const& posts) {
  std::string body;
  for (auto const& row : posts) {
    if (row.size() < 5) continue;
    // topic-post row = (author avatar-url cooked-html created-at post-number)
    std::string const& author = row[0];
    std::string const& avatar = row[1];
    std::string const& cooked = row[2];
    std::string const date = compact_date(row[3]);
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
    body += "</div>" + cooked + "</section>";
  }

  return std::string{R"HTML(<!doctype html>
<html><head><meta charset="utf-8"><style>
:root { color-scheme: light dark; }
body {
  font-family: "Adwaita Sans", Cantarell, -apple-system, "Segoe UI", sans-serif;
  font-size: 15px; line-height: 1.6;
  margin: 0 auto; padding: 22px 28px 48px;
  max-width: 680px;
  background: transparent;
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
h1,h2,h3 { line-height: 1.3; }
pre, code { font-family: "Adwaita Mono", ui-monospace, Menlo, monospace; font-size: 13px; }
code { background: rgba(128,128,128,.14); padding: 1px 5px; border-radius: 4px; }
pre { background: rgba(128,128,128,.12); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
pre code { background: none; padding: 0; }
blockquote { margin: 8px 0; padding: 2px 14px; border-left: 3px solid rgba(193,95,60,.55); color: rgba(128,128,128,1); }
img { max-width: 100%; height: auto; border-radius: 6px; }
a { color: )HTML"} +
         kAccent + R"HTML(; }
aside.quote { border-left: 3px solid rgba(193,95,60,.55); margin: 8px 0; padding: 6px 12px; background: rgba(128,128,128,.08); border-radius: 6px; }
</style></head>
<body>)HTML"} +
         body + "</body></html>";
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
    for (auto const& row : result->get()) {
      // category row = (id name slug color)
      if (row.size() < 2) continue;
      Category category;
      category.name = row[1];
      if (row.size() >= 4) category.color = row[3];
      g_state.categories[std::strtoll(row[0].c_str(), nullptr, 10)] =
          std::move(category);
    }
  } catch (...) {
    // Category names are decoration; a failure here never blocks browsing.
  }
  return G_SOURCE_REMOVE;
}

int on_posts_delivered(gpointer user_data) {
  std::unique_ptr<rivet_app::Result<Rows>> result(
      static_cast<rivet_app::Result<Rows>*>(user_data));
  try {
    std::string const document = reader_document(result->get());
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

// ---- actions -------------------------------------------------------------------------

void load_latest(bool const fresh) {
  if (g_state.api == nullptr) return;
  g_state.generation += 1;
  g_state.search_active = false;
  gtk_widget_set_sensitive(GTK_WIDGET(g_state.search), FALSE);
  (void)g_state.api->latest_list_async(
      0, fresh, [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_rows_delivered,
                   wrap_result(g_state.generation, std::move(result)));
      });
  (void)g_state.api->categories_list_async([](rivet_app::Result<Rows> result) {
    g_idle_add(on_categories_delivered,
               new rivet_app::Result<Rows>(std::move(result)));
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
  reader_loading();
  (void)g_state.api->search_list_async(
      trimmed, [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_rows_delivered,
                   wrap_result(g_state.generation, std::move(result)));
      });
}

void open_topic(TopicRow const& topic) {
  if (g_state.api == nullptr) return;
  reader_loading();
  (void)g_state.api->topic_open_async(
      std::to_string(topic.id), [](rivet_app::Result<Rows> result) mutable {
        g_idle_add(on_posts_delivered,
                   new rivet_app::Result<Rows>(std::move(result)));
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
          }
        } catch (...) {
          // Unknown events are forward-compat; ignore.
        }
      });

  load_latest(false);
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
  gtk_widget_set_halign(heading, GTK_ALIGN_START);
  gtk_widget_set_hexpand(heading, TRUE);
  auto* refresh = gtk_button_new_from_icon_name("view-refresh-symbolic");
  gtk_widget_set_tooltip_text(refresh, "Refresh");
  gtk_box_append(GTK_BOX(header), back);
  gtk_box_append(GTK_BOX(header), heading);
  gtk_box_append(GTK_BOX(header), refresh);
  g_state.back_button = GTK_BUTTON(back);
  g_state.refresh_button = GTK_BUTTON(refresh);

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
  gtk_box_append(GTK_BOX(box), search);
  gtk_box_append(GTK_BOX(box), scrolled);

  g_state.search = GTK_SEARCH_ENTRY(search);
  g_state.topic_list = GTK_LIST_BOX(list);
  g_signal_connect(g_state.back_button, "clicked",
                   G_CALLBACK(on_back_clicked), nullptr);
  g_signal_connect(g_state.refresh_button, "clicked",
                   G_CALLBACK(on_refresh_clicked), nullptr);
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

  auto* web = webkit_web_view_new();
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
