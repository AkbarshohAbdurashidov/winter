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

// Transparent, topmost overlay hosting the Flutter view: click-through except
// over interactive regions, desktop geometry (windows + taskbar) for snow
// accumulation, tray icon menu, and sleep / display-off pausing.
class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  struct Monitor {
    RECT rect{};       // physical pixels
    double scale = 1;  // physical px per logical px
  };

  void MakeTransparent();
  void FitToPrimaryMonitor();
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
  void SendMenuAction(const std::string& action);
  void PublishVisibility(const char* reason);
  std::string StateString(const char* key) const;
  bool StateBool(const char* key) const;

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  Monitor monitor_;
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
