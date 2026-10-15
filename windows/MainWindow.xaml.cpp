#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

// CoreWebView2 projections (WebMessageReceived for the like bridge) come
// from the WebView2 NuGet's include-winrt directory.
#include <winrt/Microsoft.Web.WebView2.Core.h>

#include <sstream>
#include <stdexcept>

namespace winrt::RivetHost::implementation {
namespace {

namespace muxc = winrt::Microsoft::UI::Xaml::Controls;
namespace mx = winrt::Microsoft::UI::Xaml;

std::filesystem::path executable_path() {
  std::wstring buffer(32768, L'\0');
  auto const length = ::GetModuleFileNameW(nullptr, buffer.data(),
                                          static_cast<DWORD>(buffer.size()));
  if (length == 0 || length == buffer.size()) {
    throw std::runtime_error("GetModuleFileNameW failed");
  }
  buffer.resize(length);
  return std::filesystem::path(buffer);
}

std::string utf8(std::filesystem::path const& path) {
  auto const wide = path.wstring();
  if (wide.empty()) {
    return {};
  }
  auto const size = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                          wide.data(),
                                          static_cast<int>(wide.size()),
                                          nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  std::string result(static_cast<std::size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                            wide.data(), static_cast<int>(wide.size()),
                            result.data(), size, nullptr, nullptr) != size) {
    throw std::runtime_error("WideCharToMultiByte failed");
  }
  return result;
}

rivet::windows::RacketRuntimeConfig runtime_config() {
  auto const exe = executable_path();
  auto const root = exe.parent_path();
  auto const runtime = root / L"runtime";

  rivet::windows::RacketRuntimeConfig config;
  config.executable_path = utf8(exe);
  config.petite_boot = utf8(runtime / L"petite.boot");
  config.scheme_boot = utf8(runtime / L"scheme.boot");
  config.racket_boot = utf8(runtime / L"racket.boot");
  config.backend_bundle = utf8(root / L"res" / L"core.zo");
  config.module_name = rivet_app::kModuleName;
  config.entry_symbol = rivet_app::kEntryName;
  config.dll_dir = runtime.wstring();
  return config;
}

std::string narrow(winrt::hstring const& text) { return winrt::to_string(text); }

std::wstring wide(std::string const& text) {
  auto const h = winrt::to_hstring(text);
  return std::wstring(h.c_str());
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

// The thread reader: the forum's own cooked HTML with the family reader
// stylesheet, light and dark. Same 680px column and terracotta accents as
// the macOS shell. Signed in, every post grows a like button wired to the
// WebView2 WebMessage bridge ("like:<id>" / "unlike:<id>" out,
// threadlyLikeSettled() back in).
std::string reader_document(
    std::vector<std::vector<std::string>> const& posts, bool const signed_in) {
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
             row[5] + ")\" title=\"" +
             (liked ? "Unlike this post" : "Like this post") + "\">" +
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
  font-family: "Segoe UI Variable Text", "Segoe UI", sans-serif;
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
.meta .like .count, .meta .count {
  font-size: 12px; margin-left: 3px;
  color: rgba(128,128,128,.95);
}
.meta .like.liked .count { color: #E0413E; }
h1,h2,h3 { line-height: 1.3; }
pre, code { font-family: "Cascadia Mono", ui-monospace, Consolas, monospace; font-size: 13px; }
code { background: rgba(128,128,128,.14); padding: 1px 5px; border-radius: 4px; }
pre { background: rgba(128,128,128,.12); padding: 12px 14px; border-radius: 8px; overflow-x: auto; }
pre code { background: none; padding: 0; }
blockquote { margin: 8px 0; padding: 2px 14px; border-left: 3px solid rgba(193,95,60,.55); color: rgba(128,128,128,1); }
img { max-width: 100%; height: auto; border-radius: 6px; }
a { color: #C15F3C; }
aside.quote { border-left: 3px solid rgba(193,95,60,.55); margin: 8px 0; padding: 6px 12px; background: rgba(128,128,128,.08); border-radius: 6px; }
</style></head>
<body>)HTML"} +
           body + R"HTML(
<script>
function threadlyLike(id) {
  var b = document.getElementById('like-' + id);
  if (!b || b.disabled) return;
  window.chrome.webview.postMessage(
    (b.classList.contains('liked') ? 'unlike:' : 'like:') + id);
}
function threadlyLikePending(id) {
  var b = document.getElementById('like-' + id);
  if (b) b.disabled = true;
}
// Both directions settle here: the button always wakes up (a failed
// call must not leave it stuck), and on success the content repaints
// from the settled state so heart, count, and tooltip move together.
function threadlyLikeSettled(id, ok, liked) {
  var b = document.getElementById('like-' + id);
  if (!b) return;
  b.disabled = false;
  if (!ok) return;
  b.classList.toggle('liked', liked);
  b.title = liked ? 'Unlike this post' : 'Like this post';
  var n = b.querySelector('.count');
  var count = n ? (parseInt(n.textContent, 10) || 0) : 0;
  count += liked ? 1 : -1;
  if (count < 0) count = 0;
  b.innerHTML = (liked ? '\u2665' : '\u2661') +
    (count > 0 ? '<span class="count">' + count + '</span>' : '');
}
</script></body></html>)HTML";
}

}  // namespace

MainWindow::MainWindow() {
  InitializeComponent();
  Title(L"Threadly");
  // The WebView2 control is created in code, not XAML: a missing loader or
  // runtime must degrade to "reader unavailable" instead of crashing the
  // XAML parse and taking the whole app down.
  CreateReaderAsync();
  // Ordinary window close and OS session end (logoff/shutdown) both funnel
  // into the same orderly backend stop. The console-control callback runs
  // on its own thread, so it only touches the thread-safe stop() — never
  // XAML state.
  Closed([this](auto const&, auto const&) { StopBackendOrderly(); });
  try {
    rivet::system::InstallShutdownHook([this] { StopBackendOrderly(); });
  } catch (std::exception const&) {
    // Signal coverage is platform policy and never blocks startup; the
    // window-close path above still runs the orderly shutdown.
  }
  InitializeBackendAsync();
}

void MainWindow::StopBackendOrderly() {
  if (auto backend = std::atomic_load(&backend_); backend != nullptr) {
    backend->stop();
  }
}

winrt::fire_and_forget MainWindow::InitializeBackendAsync() {
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  auto backend = std::make_shared<rivet::windows::Backend>(runtime_config());

  try {
    // Booting the embedded runtime can block on file I/O, so only startup is
    // moved off the UI thread. RPC/State traffic below is completion-driven.
    co_await winrt::resume_background();
    backend->start();

    dispatcher.TryEnqueue([weak, backend = std::move(backend)]() mutable {
      if (auto window = weak.get()) {
        window->backend_ = std::move(backend);
        try {
          // Backend events arrive on the reader thread; bounce to the UI.
          window->backend_->set_event_handler(
              [weak](std::string const& name,
                     rivet::Value const& value) {
                try {
                  auto const event = rivet_app::decode_event(name, value);
                  if (std::holds_alternative<rivet_app::NotifyEvent>(event)) {
                    auto const message =
                        std::get<rivet_app::NotifyEvent>(event).value;
                    if (auto current = weak.get()) {
                      current->DispatcherQueue().TryEnqueue(
                          [weak, message] {
                            if (auto w = weak.get()) w->SetStatus(message);
                          });
                    }
                  } else if (std::holds_alternative<rivet_app::Open_urlEvent>(event)) {
                    // auth-begin and open-releases hand URLs over; open in
                    // the user's browser.
                    auto const url =
                        std::get<rivet_app::Open_urlEvent>(event).value;
                    if (auto current = weak.get()) {
                      current->DispatcherQueue().TryEnqueue([url] {
                        (void)winrt::Windows::System::Launcher::LaunchUriAsync(
                            winrt::Windows::Foundation::Uri(winrt::to_hstring(url)));
                      });
                    }
                  }
                } catch (...) {
                  // Unknown events are forward-compat; ignore.
                }
              });
          window->LoadLatest(false);
          window->LoadAuthStatus();
          window->StartAutoUpdateCheck();
        } catch (std::exception const& e) {
          window->SetErrorUi(e.what());
        }
      } else {
        // Never destroy the last Backend reference on its own reader thread.
        std::thread([backend = std::move(backend)]() mutable {
          backend->stop();
        }).detach();
      }
    });
  } catch (std::exception const& e) {
    auto message = std::string(e.what());
    dispatcher.TryEnqueue([weak, message = std::move(message)] {
      if (auto window = weak.get()) {
        window->SetErrorUi(message);
      }
    });
  }
}

void MainWindow::LoadLatest(bool const fresh) {
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  search_active_ = false;
  pending_scope_title_.clear();
  SearchBox().IsEnabled(false);
  try {
    rivet_app::API api(*backend);
    auto const dispatcher = DispatcherQueue();
    auto const weak = get_weak();
    (void)api.latest_list_async(0, fresh,
                                [dispatcher, weak](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
                                  dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
                                    if (auto window = weak.get()) {
                                      try {
                                        window->ApplyRows(result.get(), false);
                                      } catch (std::exception const& e) {
                                        window->SetErrorUi(e.what());
                                      }
                                      window->SearchBox().IsEnabled(true);
                                    }
                                  });
                                });
    (void)api.categories_list_async([dispatcher, weak](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
      dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
        if (auto window = weak.get()) {
          try {
            window->category_order_.clear();
            for (auto const& row : result.get()) {
              // category row = (id name slug color)
              if (row.size() < 3) continue;
              auto const id = std::strtoll(row[0].c_str(), nullptr, 10);
              window->categories_[id] = {wide(row[1]),
                                         row.size() >= 4 ? wide(row[3]) : L""};
              window->category_order_.push_back(
                  {id, wide(row[1]), wide(row[2])});
            }
            window->RefreshCategoryPicker();
          } catch (...) {
            // Category names are decoration; a failure never blocks browsing.
          }
        }
      });
    });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
    SearchBox().IsEnabled(true);
  }
}

void MainWindow::RefreshCategoryPicker() {
  suppress_category_ = true;
  auto items = CategoryPicker().Items();
  items.Clear();
  items.Append(winrt::box_value(winrt::hstring(L"Latest")));
  items.Append(winrt::box_value(winrt::hstring(L"Notifications")));
  for (auto const& [id, name, slug] : category_order_) {
    items.Append(winrt::box_value(name));
  }
  suppress_category_ = false;
  CategoryPicker().IsEnabled(true);
  CategoryPicker().SelectedIndex(0);
}

void MainWindow::CategoryPicker_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    winrt::Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (suppress_category_) return;
  auto const index = CategoryPicker().SelectedIndex();
  if (index <= 0) {
    if (search_active_ || SidebarTitle().Text() != L"Latest") {
      SearchBox().Text(L"");
      LoadLatest(false);
    }
    return;
  }
  if (index == 1) {
    LoadNotifications();
    return;
  }
  auto const slot = static_cast<std::size_t>(index - 2);
  if (slot >= category_order_.size()) return;
  auto const [id, name, slug] = category_order_[slot];
  LoadCategory(slug, id, name);
}

// Signed-in notifications reuse the topic-row pipeline: each row opens its
// linked topic. Unsigned-in users get the engine's error via the RPC.
void MainWindow::LoadNotifications() {
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  search_active_ = false;
  try {
    rivet_app::API api(*backend);
    auto const dispatcher = DispatcherQueue();
    auto const weak = get_weak();
    (void)api.notifications_list_async(
        [dispatcher, weak](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              try {
                window->topics_.clear();
                auto items = winrt::single_threaded_observable_vector<winrt::hstring>();
                for (auto const& row : result.get()) {
                  // notifications row = (id type-label read-flag created
                  //                       topic-id title username)
                  if (row.size() < 6) continue;
                  auto const topic_id = std::strtoll(row[4].c_str(), nullptr, 10);
                  auto const type = wide(row[1]);
                  auto const username = row.size() > 6 && !row[6].empty()
                                            ? wide(row[6]) + L" · "
                                            : L"";
                  auto const title = wide(row[5]);
                  auto const unread = row[2] != "1";

                  std::wstringstream line;
                  line << (unread ? L"● " : L"") << type << L" — "
                       << username << title << L"\n"
                       << wide(row[3]);
                  items.Append(winrt::hstring(line.str()));
                  window->topics_.push_back({topic_id, title});
                }
                window->suppress_selection_ = true;
                window->Topics().ItemsSource(items);
                window->suppress_selection_ = false;
                window->SidebarTitle().Text(L"Notifications");
                window->BackButton().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
                window->SetReadyUi();
                // the forum marks notifications read on view; mirror that
                rivet_app::API mark_api(*window->backend_);
                (void)mark_api.notifications_mark_read_async([](rivet_app::Result<void>) {});
              } catch (std::exception const& e) {
                window->SetErrorUi(e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::LoadCategory(std::wstring const& slug, std::int64_t const id,
                              std::wstring const& name) {
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  search_active_ = false;
  pending_scope_title_ = name;
  try {
    rivet_app::API api(*backend);
    auto const dispatcher = DispatcherQueue();
    auto const weak = get_weak();
    (void)api.category_topics_list_async(
        winrt::to_string(slug), std::to_string(id),
        [dispatcher, weak](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              try {
                window->ApplyRows(result.get(), false);
              } catch (std::exception const& e) {
                window->SetErrorUi(e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::RunSearch(std::string const& query) {
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  auto const first = query.find_first_not_of(" \t\n");
  if (first == std::string::npos) return;
  auto const last = query.find_last_not_of(" \t\n");
  std::string const trimmed = query.substr(first, last - first + 1);
  if (trimmed.empty()) return;

  search_active_ = true;
  BackButton().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
  try {
    rivet_app::API api(*backend);
    auto const dispatcher = DispatcherQueue();
    auto const weak = get_weak();
    (void)api.search_list_async(
        trimmed, [dispatcher, weak](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              try {
                window->ApplyRows(result.get(), true);
              } catch (std::exception const& e) {
                window->SetErrorUi(e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

void MainWindow::OpenTopic(std::int64_t const id) {
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    return;
  }
  open_topic_id_ = id;
  ApplySignInState();
  UpdateAIButtons(false);
  Loading().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);
  try {
    rivet_app::API api(*backend);
    auto const dispatcher = DispatcherQueue();
    auto const weak = get_weak();
    (void)api.topic_open_async(
        std::to_string(id),
        [dispatcher, weak](rivet_app::Result<std::vector<std::vector<std::string>>> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              window->Loading().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
              try {
                auto const document = reader_document(
                    result.get(), !window->signed_in_user_.empty());
                if (auto const reader = window->reader_) {
                  reader.NavigateToString(winrt::to_hstring(document));
                } else {
                  window->SetErrorUi(
                      "Reader unavailable; open the thread on the forum");
                }
              } catch (std::exception const& e) {
                window->SetErrorUi(e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    Loading().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
    SetErrorUi(e.what());
  }
}

void MainWindow::ApplyRows(
    std::vector<std::vector<std::string>> const& rows, bool const searchMode) {
  // latest row = (id title category-id posts-count reply-count views
  //               like-count last-posted-at)
  // search row = (id title created-at posts-count)
  topics_.clear();
  auto items = winrt::single_threaded_observable_vector<winrt::hstring>();
  for (auto const& row : rows) {
    if (row.size() < 4) continue;
    TopicRow topic;
    topic.id = std::strtoll(row[0].c_str(), nullptr, 10);
    topic.title = wide(row[1]);

    std::wstring meta;
    if (!searchMode && row.size() >= 8) {
      auto const category_id = std::strtoll(row[2].c_str(), nullptr, 10);
      if (auto const it = categories_.find(category_id);
          it != categories_.end() && !it->second.first.empty()) {
        meta += it->second.first + L"   ";
      }
      meta += wide(row[4]) + L" replies · " + wide(row[5]) + L" views";
      auto const& likes = row[6];
      if (likes != "0") meta += L" · " + wide(likes) + L" likes";
    } else {
      meta = wide(row[3]) + L" posts · " + wide(compact_date(row[2]));
    }

    std::wstringstream line;
    line << topic.title << L"\n" << meta;
    items.Append(winrt::hstring(line.str()));
    topics_.push_back(std::move(topic));
  }
  suppress_selection_ = true;
  Topics().ItemsSource(items);
  suppress_selection_ = false;
  SidebarTitle().Text(searchMode ? L"Search results"
                                 : (pending_scope_title_.empty() ? L"Latest"
                                                                 : pending_scope_title_));
  BackButton().Visibility(searchMode ? winrt::Microsoft::UI::Xaml::Visibility::Visible : winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
  SetReadyUi();
  // Auto-open the first row so the reader never sits empty.
  if (topics_.empty()) return;
  Topics().SelectedIndex(0);
}

void MainWindow::SearchBox_KeyDown(
    winrt::Windows::Foundation::IInspectable const&,
    winrt::Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args) {
  if (args.Key() == winrt::Windows::System::VirtualKey::Enter) {
    RunSearch(narrow(SearchBox().Text()));
  }
}

void MainWindow::Topics_SelectionChanged(
    winrt::Windows::Foundation::IInspectable const&,
    winrt::Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&) {
  if (suppress_selection_) return;
  auto const index = Topics().SelectedIndex();
  if (index >= 0 && static_cast<std::size_t>(index) < topics_.size()) {
    OpenTopic(topics_[static_cast<std::size_t>(index)].id);
  }
}

void MainWindow::Back_Click(winrt::Windows::Foundation::IInspectable const&,
                            Microsoft::UI::Xaml::RoutedEventArgs const&) {
  SearchBox().Text(L"");
  if (CategoryPicker().SelectedIndex() != 0) {
    CategoryPicker().SelectedIndex(0);
  } else {
    LoadLatest(false);
  }
}

void MainWindow::Refresh_Click(winrt::Windows::Foundation::IInspectable const&,
                               Microsoft::UI::Xaml::RoutedEventArgs const&) {
  if (search_active_) {
    Back_Click(nullptr, nullptr);
  } else if (CategoryPicker().SelectedIndex() > 0) {
    auto const slot = static_cast<std::size_t>(CategoryPicker().SelectedIndex() - 1);
    if (slot < category_order_.size()) {
      auto const [id, name, slug] = category_order_[slot];
      LoadCategory(slug, id, name);
    }
  } else {
    LoadLatest(true);
  }
}

// About Threadly: version, one-line description, license, and the two
// family links (product site + issue tracker) — the family About shape.
winrt::fire_and_forget MainWindow::OnAbout(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  auto panel = muxc::StackPanel{};
  panel.Spacing(4);
  auto tagline = muxc::TextBlock{};
  tagline.Text(L"Read the Racket community, outside the browser.");
  tagline.TextAlignment(mx::TextAlignment::Center);
  tagline.Margin({0, 0, 0, 8});
  auto license = muxc::TextBlock{};
  license.Text(L"Released under the GNU Affero General Public License v3.0.");
  license.TextAlignment(mx::TextAlignment::Center);
  license.FontSize(12);
  license.Opacity(0.75);
  auto website = muxc::HyperlinkButton{};
  website.Content(winrt::box_value(winrt::hstring(L"Website")));
  website.NavigateUri(winrt::Windows::Foundation::Uri{
      L"https://threadly.jrtx.site"});
  website.HorizontalAlignment(mx::HorizontalAlignment::Center);
  website.Padding({0, 0, 0, 0});
  auto issue = muxc::HyperlinkButton{};
  issue.Content(winrt::box_value(winrt::hstring(L"Report an Issue")));
  issue.NavigateUri(winrt::Windows::Foundation::Uri{
      L"https://github.com/turinglambdaai/threadly/issues"});
  issue.HorizontalAlignment(mx::HorizontalAlignment::Center);
  issue.Padding({0, 0, 0, 0});
  panel.Children().Append(tagline);
  panel.Children().Append(license);
  panel.Children().Append(website);
  panel.Children().Append(issue);

  auto dialog = muxc::ContentDialog{};
  dialog.Title(winrt::box_value(L"Threadly v" + wide(rivet_app::kVersion)));
  dialog.Content(winrt::box_value(panel));
  dialog.CloseButtonText(L"OK");
  dialog.XamlRoot(Content().XamlRoot());
  co_await dialog.ShowAsync();
}

void MainWindow::StatusBar_Close(winrt::Windows::Foundation::IInspectable const&,
                                 winrt::Windows::Foundation::IInspectable const&) {
  StatusBar().IsOpen(false);
}

void MainWindow::SetUpdateStatus(std::wstring const& message) {
  if (message.empty()) {
    StatusBar().IsOpen(false);
    return;
  }
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Informational);
  StatusBar().Message(winrt::hstring(message));
  StatusBar().IsOpen(true);
}

void MainWindow::CheckForUpdates_Click(winrt::Windows::Foundation::IInspectable const&,
                                       Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunUpdateCheck(/*silent=*/false);
}

void MainWindow::SetReadyUi() {
  if (StatusBar().IsOpen() &&
      StatusBar().Severity() ==
          Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error) {
    StatusBar().IsOpen(false);
  }
}

void MainWindow::SetErrorUi(std::string const& message) {
  Loading().Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Error);
  StatusBar().Message(winrt::to_hstring(message));
  StatusBar().IsOpen(true);
}

void MainWindow::SetStatus(std::string const& message) {
  StatusBar().Severity(Microsoft::UI::Xaml::Controls::InfoBarSeverity::Warning);
  StatusBar().Message(winrt::to_hstring(message));
  StatusBar().IsOpen(true);
}

winrt::Microsoft::UI::Xaml::Controls::WebView2 MainWindow::Reader() {
  return reader_;
}

winrt::fire_and_forget MainWindow::CreateReaderAsync() {
  auto const weak = get_weak();
  try {
    winrt::Microsoft::UI::Xaml::Controls::WebView2 webview;
    ReaderHost().Content(webview);
    co_await webview.EnsureCoreWebView2Async();
    if (auto window = weak.get()) {
      window->reader_ = webview;
      // Like bridge: the reader page posts "like:<id>" / "unlike:<id>"
      // (the button's own class picks the direction); bounce to the RPC
      // and apply the server's answer back into the page. The event
      // source dies with the reader control, and the handler only ever
      // touches the window through get_weak().
      webview.CoreWebView2().WebMessageReceived(
          [weak](winrt::Microsoft::Web::WebView2::Core::CoreWebView2 const&,
                 winrt::Microsoft::Web::WebView2::Core::CoreWebView2WebMessageReceivedEventArgs const& args) {
            auto const message = args.TryGetWebMessageAsString();
            auto const text = std::wstring(message.c_str(), message.size());
            bool like;
            wchar_t const* rest;
            if (text.rfind(L"like:", 0) == 0) {
              like = true;
              rest = text.c_str() + 5;
            } else if (text.rfind(L"unlike:", 0) == 0) {
              like = false;
              rest = text.c_str() + 7;
            } else {
              return;
            }
            auto const post_id = std::wcstoll(rest, nullptr, 10);
            if (auto window = weak.get()) {
              window->LikePost(post_id, like);
            }
          });
    }
  } catch (std::exception const& e) {
    if (auto window = weak.get()) {
      window->SetErrorUi(std::string{"Reader unavailable: "} + e.what());
    }
  } catch (...) {
    if (auto window = weak.get()) {
      window->SetErrorUi("WebView2 runtime unavailable; the reader is disabled");
    }
  }
}

// ---- account (M2 write path) ------------------------------------------------

void MainWindow::LoadAuthStatus() {
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) return;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    (void)api.auth_status_async(
        [dispatcher, weak](rivet_app::Result<rivet_app::AuthStatus> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              try {
                auto const status = result.get();
                window->signed_in_user_ =
                    status.status == "in" ? wide(status.username) : L"";
                window->ApplySignInState();
              } catch (...) {
                // auth state is decoration at startup; flows surface errors
              }
            }
          });
        });
  } catch (...) {
  }
}

void MainWindow::ApplySignInState() {
  auto const signed_in = !signed_in_user_.empty();
  winrt::Microsoft::UI::Xaml::Controls::ToolTipService::SetToolTip(
      AccountButton(),
      winrt::box_value(winrt::hstring(
          signed_in ? L"Signed in as " + signed_in_user_ +
                          L" (click to sign out)"
                    : L"Sign in with racket.discourse.group")));
  ReplyButton().IsEnabled(signed_in && open_topic_id_ != 0);
}

void MainWindow::Account_Click(winrt::Windows::Foundation::IInspectable const&,
                               Microsoft::UI::Xaml::RoutedEventArgs const&) {
  (void)AccountFlowAsync();
}

void MainWindow::Reply_Click(winrt::Windows::Foundation::IInspectable const&,
                             Microsoft::UI::Xaml::RoutedEventArgs const&) {
  (void)ReplyDialogAsync();
}

winrt::fire_and_forget MainWindow::AccountFlowAsync() {
  if (sign_in_running_) co_return;
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    SetErrorUi("Racket backend is not running");
    co_return;
  }
  if (!signed_in_user_.empty()) {
    (void)SignOutConfirmAsync();
    co_return;
  }

  sign_in_running_ = true;
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    // auth-begin generates the handshake keypair (openssl shell) on the
    // backend thread; the completion opens the browser and the paste sheet.
    (void)api.auth_begin_async(
        [dispatcher, weak](rivet_app::Result<std::string> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              try {
                // the browser open rides the open-url event (auth-begin
                // both fires it and returns the URL); show the paste sheet
                (void)result.get();
                (void)window->PasteCodeDialogAsync();
              } catch (std::exception const& e) {
                window->sign_in_running_ = false;
                window->SetErrorUi(e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    sign_in_running_ = false;
    SetErrorUi(e.what());
  }
}

winrt::fire_and_forget MainWindow::PasteCodeDialogAsync() {
  auto const weak = get_weak();
  muxc::TextBox box;
  box.PlaceholderText(L"Paste the code the forum shows");
  auto label = muxc::TextBlock{};
  label.Text(L"Approve Threadly in the browser that just opened, copy the "
             L"code it displays, and paste it here.");
  label.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);
  label.Margin(winrt::Microsoft::UI::Xaml::Thickness{0, 0, 0, 10});
  auto panel = muxc::StackPanel{};
  panel.Children().Append(label);
  panel.Children().Append(box);
  muxc::ContentDialog dialog;
  dialog.Title(winrt::box_value(winrt::hstring(L"Finish signing in")));
  dialog.Content(panel);
  dialog.PrimaryButtonText(L"Complete sign-in");
  dialog.CloseButtonText(L"Cancel");
  dialog.DefaultButton(muxc::ContentDialogButton::Primary);
  if (auto window = weak.get()) {
    dialog.XamlRoot(window->Content().XamlRoot());
  }
  auto const result = co_await dialog.ShowAsync();
  auto const code = narrow(box.Text());
  if (result != winrt::Microsoft::UI::Xaml::Controls::ContentDialogResult::Primary ||
      code.find_first_not_of(" \t\r\n") == std::string::npos) {
    if (auto window = weak.get()) window->sign_in_running_ = false;
    co_return;
  }

  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    if (auto window = weak.get()) window->sign_in_running_ = false;
    co_return;
  }
  auto const dispatcher = DispatcherQueue();
  try {
    rivet_app::API api(*backend);
    (void)api.auth_complete_async(
        code, [dispatcher, weak](rivet_app::Result<std::string> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              window->sign_in_running_ = false;
              try {
                (void)result.get();
                // the identity comes from auth-status; refresh it, and
                // confirm the flow in the status bar right away
                window->LoadAuthStatus();
                window->SetUpdateStatus(
                    L"Signed in. You can now reply and like posts.");
              } catch (std::exception const& e) {
                window->SetErrorUi(std::string{"Sign-in failed: "} + e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    sign_in_running_ = false;
    SetErrorUi(e.what());
  }
}

winrt::fire_and_forget MainWindow::SignOutConfirmAsync() {
  auto const weak = get_weak();
  auto label = muxc::TextBlock{};
  label.Text(L"Sign out of " + signed_in_user_ +
             L"? You will not be able to reply or like until you sign in "
             L"again.");
  label.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);
  muxc::ContentDialog dialog;
  dialog.Title(winrt::box_value(winrt::hstring(L"Sign out")));
  dialog.Content(label);
  dialog.PrimaryButtonText(L"Sign out");
  dialog.CloseButtonText(L"Cancel");
  dialog.DefaultButton(muxc::ContentDialogButton::Primary);
  if (auto window = weak.get()) {
    dialog.XamlRoot(window->Content().XamlRoot());
  }
  auto const result = co_await dialog.ShowAsync();
  if (result != winrt::Microsoft::UI::Xaml::Controls::ContentDialogResult::Primary) {
    co_return;
  }
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) co_return;
  auto const dispatcher = DispatcherQueue();
  try {
    rivet_app::API api(*backend);
    (void)api.auth_sign_out_async(
        [dispatcher, weak](rivet_app::Result<void> result) {
          dispatcher.TryEnqueue([weak, result = std::move(result)]() mutable {
            if (auto window = weak.get()) {
              try {
                result.get();
                window->signed_in_user_.clear();
                window->ApplySignInState();
                window->SetUpdateStatus(L"Signed out.");
              } catch (std::exception const& e) {
                window->SetErrorUi(std::string{"Sign-out failed: "} + e.what());
              }
            }
          });
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

winrt::fire_and_forget MainWindow::ReplyDialogAsync() {
  if (open_topic_id_ == 0 || signed_in_user_.empty()) co_return;
  auto const weak = get_weak();
  muxc::TextBox box;
  box.PlaceholderText(L"Write your reply in Markdown\u2026");
  box.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);
  box.AcceptsReturn(true);
  box.Height(170);
  auto label = muxc::TextBlock{};
  label.Text(L"Posting as " + signed_in_user_ +
             L". Discourse posts are Markdown.");
  label.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);
  label.Margin(winrt::Microsoft::UI::Xaml::Thickness{0, 0, 0, 10});
  auto panel = muxc::StackPanel{};
  panel.Children().Append(label);
  panel.Children().Append(box);
  muxc::ContentDialog dialog;
  dialog.Title(winrt::box_value(winrt::hstring(L"Reply")));
  dialog.Content(panel);
  dialog.PrimaryButtonText(L"Reply");
  dialog.CloseButtonText(L"Cancel");
  dialog.DefaultButton(muxc::ContentDialogButton::Primary);
  if (auto window = weak.get()) {
    dialog.XamlRoot(window->Content().XamlRoot());
  }
  auto const result = co_await dialog.ShowAsync();
  auto const body = narrow(box.Text());
  auto const topic_id = open_topic_id_;
  if (result != winrt::Microsoft::UI::Xaml::Controls::ContentDialogResult::Primary ||
      body.find_first_not_of(" \t\r\n") == std::string::npos) {
    co_return;
  }

  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) co_return;
  auto const dispatcher = DispatcherQueue();
  try {
    rivet_app::API api(*backend);
    (void)api.post_create_async(
        std::to_string(topic_id), body,
        [dispatcher, weak, topic_id](
            rivet_app::Result<std::vector<std::vector<std::string>>> res) {
          dispatcher.TryEnqueue(
              [weak, topic_id, res = std::move(res)]() mutable {
                if (auto window = weak.get()) {
                  try {
                    (void)res.get();
                    window->SetUpdateStatus(L"Reply posted.");
                    window->OpenTopic(topic_id);
                  } catch (std::exception const& e) {
                    window->SetErrorUi(std::string{"Reply failed: "} + e.what());
                  }
                }
              });
        });
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

// ---- M3 reading value-add (summary, translation) ----------------------------

void MainWindow::Summarize_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunAI(/*summarize=*/true);
}

void MainWindow::Translate_Click(
    winrt::Windows::Foundation::IInspectable const&,
    Microsoft::UI::Xaml::RoutedEventArgs const&) {
  RunAI(/*summarize=*/false);
}

void MainWindow::UpdateAIButtons(bool const busy) {
  bool const ready = open_topic_id_ != 0 && !busy;
  SummarizeButton().IsEnabled(ready);
  TranslateButton().IsEnabled(ready);
}

// Shows a live dialog immediately (the model can take tens of seconds)
// and streams the answer in when the RPC lands. The engine answers ""
// and fires a notify event on failure, so the dialog says so and the
// InfoBar carries the reason.
void MainWindow::RunAI(bool const summarize) {
  if (open_topic_id_ == 0) return;
  auto const weak = get_weak();
  auto const dispatcher = DispatcherQueue();
  auto const topic_id = std::to_string(open_topic_id_);

  auto label = muxc::TextBlock{};
  label.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);
  label.IsTextSelectionEnabled(true);
  label.Text(summarize ? L"Summarizing\u2026" : L"Translating\u2026");
  auto scroll = muxc::ScrollViewer{};
  scroll.Content(label);
  scroll.Height(340);
  scroll.Width(480);
  muxc::ContentDialog dialog;
  dialog.Title(winrt::box_value(winrt::hstring(summarize ? L"Summary"
                                                         : L"Translation")));
  dialog.Content(scroll);
  dialog.CloseButtonText(L"Close");
  dialog.DefaultButton(muxc::ContentDialogButton::Close);
  dialog.XamlRoot(Content().XamlRoot());
  (void)dialog.ShowAsync();
  UpdateAIButtons(true);

  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) {
    UpdateAIButtons(false);
    SetErrorUi("Racket backend is not running");
    return;
  }
  try {
    rivet_app::API api(*backend);
    auto const handler =
        [dispatcher, weak, label, summarize](
            rivet_app::Result<std::string> result) mutable {
          dispatcher.TryEnqueue(
              [weak, label, summarize, result = std::move(result)]() mutable {
                if (auto window = weak.get()) {
                  window->UpdateAIButtons(false);
                  try {
                    auto const text = result.get();
                    label.Text(text.empty()
                                   ? winrt::hstring(L"The model returned nothing.")
                                   : winrt::to_hstring(text));
                  } catch (std::exception const& e) {
                    label.Text(winrt::to_hstring(std::string{"Failed: "} +
                                                 e.what()));
                  }
                }
              });
        };
    if (summarize) {
      (void)api.ai_summarize_async(topic_id, handler);
    } else {
      (void)api.ai_translate_async(topic_id, handler);
    }
  } catch (std::exception const& e) {
    UpdateAIButtons(false);
    SetErrorUi(e.what());
  }
}

// like toggles by direction: the reader sends "like:<id>" for a post
// the user hasn't liked and "unlike:<id>" for one they have (the
// engine's was_deleted direction).
void MainWindow::LikePost(std::int64_t const post_id, bool const like) {
  if (signed_in_user_.empty()) return;
  auto const backend = std::atomic_load(&backend_);
  if (backend == nullptr || !backend->running()) return;
  if (auto const reader = reader_) {
    (void)reader.CoreWebView2().ExecuteScriptAsync(
        L"threadlyLikePending(" + std::to_wstring(post_id) + L")");
  }
  auto const dispatcher = DispatcherQueue();
  auto const weak = get_weak();
  try {
    rivet_app::API api(*backend);
    auto const settle =
        [dispatcher, weak, post_id, like](rivet_app::Result<bool> result) {
          dispatcher.TryEnqueue(
              [weak, post_id, like, result = std::move(result)]() mutable {
                if (auto window = weak.get()) {
                  bool ok = false;
                  try {
                    ok = result.get();
                  } catch (...) {
                  }
                  if (auto const reader = window->reader_) {
                    (void)reader.CoreWebView2().ExecuteScriptAsync(
                        L"threadlyLikeSettled(" + std::to_wstring(post_id) +
                        L", " + (ok ? L"true" : L"false") + L", " +
                        (like ? L"true" : L"false") + L")");
                  }
                  if (!ok) {
                    window->SetStatus(like ? "Couldn't like that post."
                                           : "Couldn't remove that like.");
                  }
                }
              });
        };
    if (like) {
      (void)api.like_post_async(std::to_string(post_id), settle);
    } else {
      (void)api.unlike_post_async(std::to_string(post_id), settle);
    }
  } catch (std::exception const& e) {
    SetErrorUi(e.what());
  }
}

}  // namespace winrt::RivetHost::implementation
