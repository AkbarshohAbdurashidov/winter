#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <shellapi.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// One display: rectangle in physical pixels and its scale factor.
struct MonitorInfo {
  RECT rect{};
  double scale = 1;  // physical px per logical px
  bool primary = false;
};

// Starts one overlay per connected display (the first one, on the primary
// display, also owns the tray icon) and keeps that set in sync when
// displays are added, removed or rearranged.
bool StartOverlays(const flutter::DartProject& project);
void StopOverlays();

// Transparent, topmost overlay for one display hosting its own Flutter
// engine: click-through except over interactive regions, desktop geometry
// (windows + taskbar on that display) for snow accumulation, tray icon menu
// (host only), and sleep / display-off pausing.
class FlutterWindow : public Win32Window {
 public:
  FlutterWindow(const flutter::DartProject& project, int screen_id,
                const MonitorInfo& monitor, bool is_host);
  virtual ~FlutterWindow();

  bool is_host() const { return is_host_; }
  const MonitorInfo& monitor() const { return monitor_; }
  void SetMonitor(const MonitorInfo& monitor);
  void SendMenuAction(const std::string& action);
  void NotifyDisplaysChanged();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void MakeTransparent();
  void FitToMonitor();
  void ApplyLevel(const std::string& level);
  void SetIgnoreMouse(bool ignore);
  void UpdateInteractive(bool force);
  void PollGeometry();
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowTrayMenu();
  void PublishVisibility(const char* reason);
  std::string StateString(const char* key) const;
  bool StateBool(const char* key) const;

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  int screen_id_ = 0;
  bool is_host_ = false;
  MonitorInfo monitor_;
  NOTIFYICONDATA tray_icon_{};
  bool tray_added_ = false;
  UINT taskbar_created_message_ = 0;
  HPOWERNOTIFY display_notify_ = nullptr;
  std::string level_ = "aboveWindows";
  flutter::EncodableMap menu_state_;
  std::vector<std::string> menu_actions_;
  bool display_off_ = false;
  bool suspended_ = false;

  // Interaction.
  std::vector<RECT> hit_regions_;  // physical pixels
  bool click_through_enabled_ = true;
  bool ignoring_mouse_ = false;
  bool ignore_state_known_ = false;
  bool last_requested_ignore_ = false;
  int style_reapplied_ = 0;  // times the click-through style had been lost

  // Geometry change detection.
  std::vector<double> last_geometry_;
  int topmost_tick_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
