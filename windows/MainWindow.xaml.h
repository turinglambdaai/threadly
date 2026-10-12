#pragma once

#include "pch.h"
#include "MainWindow.g.h"
#include "system_services.hpp"

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
  void StatusBar_Close(winrt::Windows::Foundation::IInspectable const& sender,
                       winrt::Windows::Foundation::IInspectable const& args);
  void CheckForUpdates_Click(winrt::Windows::Foundation::IInspectable const& sender,
                             Microsoft::UI::Xaml::RoutedEventArgs const& args);

 private:
  struct TopicRow {
    std::int64_t id{0};
    std::wstring title;
  };

  winrt::fire_and_forget InitializeBackendAsync();
  void LoadLatest(bool fresh);
  void RunSearch(std::string const& query);
  void OpenTopic(std::int64_t id);
  void ApplyRows(std::vector<std::vector<std::string>> const& rows,
                 bool searchMode);
  void SetReadyUi();
  void SetErrorUi(std::string const& message);
  void SetStatus(std::string const& message);
  void SetUpdateStatus(std::wstring const& message);
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
  void ShowUpdateDialog(std::wstring const& title, std::wstring const& body,
                        std::wstring const& primary_button,
                        std::wstring const& close_button,
                        std::function<void()> on_primary);

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::vector<TopicRow> topics_;
  std::map<std::int64_t, std::pair<std::wstring, std::wstring>> categories_;
  winrt::Microsoft::UI::Xaml::Controls::WebView2 reader_{nullptr};
  bool search_active_{false};
  bool suppress_selection_{false};
  bool update_downloading_{false};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer check_timer_{nullptr};
  winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer update_timer_{nullptr};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}
