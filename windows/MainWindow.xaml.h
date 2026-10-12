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
  bool EnsureReaderAsyncStarted();
  winrt::fire_and_forget EnsureReaderAsync();

  std::shared_ptr<rivet::windows::Backend> backend_;
  std::vector<TopicRow> topics_;
  std::map<std::int64_t, std::pair<std::wstring, std::wstring>> categories_;
  bool search_active_{false};
  bool suppress_selection_{false};
  bool reader_started_{false};
};

}  // namespace winrt::RivetHost::implementation

namespace winrt::RivetHost::factory_implementation {

struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};

}
