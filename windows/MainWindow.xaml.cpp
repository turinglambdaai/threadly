#include "pch.h"
#include "MainWindow.xaml.h"
#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif
#include "GeneratedBackend.hpp"

#include <sstream>
#include <stdexcept>

namespace winrt::RivetHost::implementation {
namespace {

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
// the macOS shell.
std::string reader_document(
    std::vector<std::vector<std::string>> const& posts) {
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
           body + "</body></html>";
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
                  }
                } catch (...) {
                  // Unknown events are forward-compat; ignore.
                }
              });
          window->LoadLatest(false);
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
                window->BackButton().Visibility(Visibility::Visible);
                window->SetReadyUi();
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
                auto const document = reader_document(result.get());
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
}  // namespace winrt::RivetHost::implementation
