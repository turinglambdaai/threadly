#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "GeneratedBackend.hpp"
#include "system_services.hpp"
#if __has_include("winui_window.hpp")
// rivet main isolated the WinUI HWND bridge into its own header; older
// pins keep declaring NativeWindowHandle in system_services.hpp
#include "winui_window.hpp"
#endif

namespace winrt::RivetHost::implementation {

struct MainWindow : MainWindowT<MainWindow> {
  MainWindow();

  // Stable HWND access for platform-owned features such as global hotkeys,
  // clipboard listeners, window subclassing, topmost policy, and tray icons.
  [[nodiscard]] HWND WindowHandle() {
    return rivet::system::NativeWindowHandle(*this);
  }

  // Thread-safe orderly backend stop shared by the window-close path and
  // the console-control shutdown hook (logoff/CTRL events).
  void StopBackendOrderly();

  void SearchBox_KeyDown(winrt::Windows::Foundation::IInspectable const& sender,
                         winrt::Microsoft::UI::Xaml::Input::KeyRoutedEventArgs const& args);
  void Topics_SelectionChanged(winrt::Windows::Foundation::IInspectable const& sender,
                               winrt::Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void Back_Click(winrt::Windows::Foundation::IInspectable const& sender,
                  Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Refresh_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  winrt::fire_and_forget OnAbout(
      winrt::Windows::Foundation::IInspectable const& sender,
      Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void StatusBar_Close(winrt::Windows::Foundation::IInspectable const& sender,
                       winrt::Windows::Foundation::IInspectable const& args);
  void CheckForUpdates_Click(winrt::Windows::Foundation::IInspectable const& sender,
                             Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void CategoryPicker_SelectionChanged(
      winrt::Windows::Foundation::IInspectable const& sender,
      winrt::Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const& args);
  void Account_Click(winrt::Windows::Foundation::IInspectable const& sender,
                     Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Reply_Click(winrt::Windows::Foundation::IInspectable const& sender,
                   Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Summarize_Click(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::RoutedEventArgs const& args);
  void Translate_Click(winrt::Windows::Foundation::IInspectable const& sender,
                       Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  struct TopicRow {
    std::int64_t id{0};
    std::wstring title;
  };

  winrt::fire_and_forget InitializeBackendAsync();
  void LoadLatest(bool fresh);
  void LoadCategory(std::wstring const& slug, std::int64_t id,
                    std::wstring const& name);
  void LoadNotifications();
  void RefreshCategoryPicker();
  void RunSearch(std::string const& query);
  void OpenTopic(std::int64_t id);
  void ApplyRows(std::vector<std::vector<std::string>> const& rows,
                 bool searchMode);
  void SetReadyUi();
  void SetErrorUi(std::string const& message);
  void SetStatus(std::string const& message);
  void SetUpdateStatus(std::wstring const& message);

  // Account (M2 write path): sign-in via the forum's user API key flow,
  // identity tooltip, sign-out; gates the composer and the like buttons.
  void LoadAuthStatus();
  void ApplySignInState();
  winrt::fire_and_forget AccountFlowAsync();
  winrt::fire_and_forget PasteCodeDialogAsync();
  winrt::fire_and_forget SignOutConfirmAsync();
  winrt::fire_and_forget ReplyDialogAsync();
  void LikePost(std::int64_t post_id);
  void RunAI(bool const summarize);
  // Reader document assembly with the forum's like state on each post.
  void UpdateAIButtons(bool const busy);

  winrt::fire_and_forget CreateReaderAsync();
  winrt::Microsoft::UI::Xaml::Controls::WebView2 Reader();

  // Online update flow (MainWindow.Update.cpp)
  void StartAutoUpdateCheck();
  void RunSilentUpdateCheck();
  void RunUpdateCheck(bool silent);
  void HandleUpdateCheckResult(bool ok,
                               rivet_app::UpdateCheck const& check,
                               std::string const& failure, bool silent);
  void StartDownload();
  void PollUpdateState(std::shared_ptr<rivet::windows::Backend> const& backend);
  void HandleUpdatePoll(std::optional<rivet_app::UpdateState> const& state);
  void StopUpdateTimer();
  void FailDownload(std::string const& message);
  void ShowInstallConsent(std::wstring const& path);
  void InstallDownloadedUpdate(std::wstring const& zip_path);
  void HandleInstallMarkers();
  bool IsDevCopy();
  bool IsMsiInstall();
  // copy_button: when non-empty, a secondary button copies the dialog body
  // (the failure message) to the clipboard — update errors must leave the
  // screen with the user (family rule: error text is always copyable).
  void ShowUpdateDialog(std::wstring const& title, std::wstring const& body,
                        std::wstring const& primary_button,
                        std::wstring const& close_button,
                        std::function<void()> on_primary,
                        std::wstring const& copy_button = L"");

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::vector<TopicRow> topics_;
  std::map<std::int64_t, std::pair<std::wstring, std::wstring>> categories_;
  // Ordered category registry (id, name, slug) in the forum's own order;
  // the picker's index maps to this minus one (0 = Latest).
  std::vector<std::tuple<std::int64_t, std::wstring, std::wstring>> category_order_;
  winrt::Microsoft::UI::Xaml::Controls::WebView2 reader_{nullptr};
  std::wstring pending_scope_title_;
  bool search_active_{false};
  bool suppress_selection_{false};
  bool suppress_category_{false};
  bool update_downloading_{false};
  // Signed-in identity (empty when signed out) and the topic currently
  // shown in the reader — the reply composer targets it.
  std::wstring signed_in_user_;
  std::int64_t open_topic_id_{0};
  bool sign_in_running_{false};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer check_timer_{nullptr};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer update_timer_{nullptr};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}
