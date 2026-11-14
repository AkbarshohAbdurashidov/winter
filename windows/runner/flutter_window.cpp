// Windows overlay. Written on macOS and compiled only in CI; see
// docs/PHASES.md for what has been verified on real Windows hardware.
#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuBase = 1000;
constexpr UINT kMenuQuit = 999;
constexpr UINT_PTR kMouseTimer = 1;     // 30 Hz cursor check
constexpr UINT_PTR kGeometryTimer = 2;  // 20 Hz desktop geometry

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// Undocumented but stable since Windows 10 1607; used by window_manager and
// flutter_acrylic to give a Flutter window a transparent background.
void SetTransparentAccent(HWND hwnd) {
  HMODULE user32 = GetModuleHandle(L"user32.dll");
  if (!user32) return;
  struct ACCENTPOLICY {
    int nAccentState;
    int nFlags;
    int nColor;
    int nAnimationId;
  };
  struct WINCOMPATTRDATA {
    int nAttribute;
    PVOID pData;
    ULONG ulDataSize;
  };
  using SetWCA = BOOL(WINAPI*)(HWND, WINCOMPATTRDATA*);
  auto set_wca = reinterpret_cast<SetWCA>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (!set_wca) return;
  ACCENTPOLICY policy = {2 /* ACCENT_ENABLE_TRANSPARENTGRADIENT */, 2, 0, 0};
  WINCOMPATTRDATA data = {19 /* WCA_ACCENT_POLICY */, &policy, sizeof(policy)};
  set_wca(hwnd, &data);
}

bool IsCloaked(HWND hwnd) {
  DWORD cloaked = 0;
  return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &cloaked,
                                         sizeof(cloaked))) &&
         cloaked != 0;
}

struct EnumContext {
  HWND self;
  std::vector<std::pair<HWND, RECT>> windows;  // front-to-back
};

BOOL CALLBACK CollectWindow(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<EnumContext*>(lparam);
  if (hwnd == ctx->self || !IsWindowVisible(hwnd) || IsIconic(hwnd) ||
      IsCloaked(hwnd)) {
    return TRUE;
  }
  LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  if ((ex & WS_EX_TOOLWINDOW) && !(ex & WS_EX_APPWINDOW)) return TRUE;
  if (ex & WS_EX_NOACTIVATE) return TRUE;
  if (GetWindowTextLength(hwnd) == 0) return TRUE;
  wchar_t cls[64] = {};
  GetClassName(hwnd, cls, 64);
  const std::wstring c(cls);
  if (c == L"Progman" || c == L"WorkerW" || c == L"Shell_TrayWnd" ||
      c == L"Shell_SecondaryTrayWnd" || c == L"Windows.UI.Core.CoreWindow") {
    return TRUE;
  }
  RECT r{};
  // Excludes the invisible resize borders that GetWindowRect includes.
  if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &r,
                                   sizeof(r)))) {
    GetWindowRect(hwnd, &r);
  }
  ctx->windows.emplace_back(hwnd, r);
  return TRUE;
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  MakeTransparent();
  FitToPrimaryMonitor();

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), "winter/overlay",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  taskbar_created_message_ = RegisterWindowMessage(L"TaskbarCreated");
  AddTrayIcon();
  display_notify_ = RegisterPowerSettingNotification(
      GetHandle(), &GUID_CONSOLE_DISPLAY_STATE, DEVICE_NOTIFY_WINDOW_HANDLE);

  SetIgnoreMouse(true);
  SetTimer(GetHandle(), kMouseTimer, 33, nullptr);
  SetTimer(GetHandle(), kGeometryTimer, 50, nullptr);

  flutter_controller_->engine()->SetNextFrameCallback([&]() { this->Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  KillTimer(GetHandle(), kMouseTimer);
  KillTimer(GetHandle(), kGeometryTimer);
  RemoveTrayIcon();
  if (display_notify_) {
    UnregisterPowerSettingNotification(display_notify_);
    display_notify_ = nullptr;
  }
  channel_ = nullptr;
  flutter_controller_ = nullptr;
  Win32Window::OnDestroy();
}

void FlutterWindow::MakeTransparent() {
  HWND hwnd = GetHandle();
  MARGINS margins = {-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(hwnd, &margins);
  SetTransparentAccent(hwnd);
}

void FlutterWindow::FitToPrimaryMonitor() {
  HMONITOR monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(monitor, &info)) return;
  monitor_.rect = info.rcMonitor;  // physical pixels (PerMonitorV2 manifest)
  monitor_.scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const RECT& r = monitor_.rect;
  HWND after = level_ == "desktop" ? HWND_BOTTOM : HWND_TOPMOST;
  SetWindowPos(GetHandle(), after, r.left, r.top, r.right - r.left,
               r.bottom - r.top, SWP_NOACTIVATE);
}

void FlutterWindow::ApplyLevel(const std::string& level) {
  level_ = level;
  HWND hwnd = GetHandle();
  if (level == "desktop") {
    // Approximation: bottom of the z-order (above desktop icons).
    SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  } else {
    SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

// Same technique as window_manager's setIgnoreMouseEvents. The actual style
// is checked every time (not a cached flag): something can clear
// WS_EX_TRANSPARENT behind our back, and a non-transparent full-screen
// overlay would swallow every click on the desktop.
void FlutterWindow::SetIgnoreMouse(bool ignore) {
  HWND hwnd = GetHandle();
  const LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  constexpr LONG_PTR kBits = WS_EX_TRANSPARENT | WS_EX_LAYERED;
  const bool current = (ex & kBits) == kBits;
  ignoring_mouse_ = ignore;
  if (ignore == current && (ignore || (ex & kBits) == 0)) return;
  if (ignore_state_known_ && ignore == last_requested_ignore_) style_reapplied_++;
  ignore_state_known_ = true;
  last_requested_ignore_ = ignore;
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, ignore ? (ex | kBits) : (ex & ~kBits));
}

void FlutterWindow::UpdateInteractive(bool force) {
  // Never switch mid-press: the user may be dragging in another app, or
  // dragging a snowball here.
  const bool pressed = (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;
  if (!force && pressed) return;
  bool interactive = !click_through_enabled_;
  if (!interactive && !hit_regions_.empty()) {
    POINT p;
    if (GetCursorPos(&p)) {
      for (const RECT& r : hit_regions_) {
        if (PtInRect(&r, p)) {
          interactive = true;
          break;
        }
      }
    }
  }
  SetIgnoreMouse(!interactive);
}

void FlutterWindow::PollGeometry() {
  if (!channel_) return;
  const double s = monitor_.scale > 0 ? monitor_.scale : 1;
  const double ox = monitor_.rect.left, oy = monitor_.rect.top;
  const double sw = (monitor_.rect.right - monitor_.rect.left) / s;
  const double sh = (monitor_.rect.bottom - monitor_.rect.top) / s;

  EnumContext ctx{GetHandle(), {}};
  EnumWindows(CollectWindow, reinterpret_cast<LPARAM>(&ctx));

  std::vector<double> flat;
  for (auto& [hwnd, r] : ctx.windows) {
    const double w = (r.right - r.left) / s, h = (r.bottom - r.top) / s;
    if (w < 120 || h < 60) continue;
    flat.push_back(static_cast<double>(reinterpret_cast<intptr_t>(hwnd) & 0x7fffffff));
    flat.push_back((r.left - ox) / s);
    flat.push_back((r.top - oy) / s);
    flat.push_back(w);
    flat.push_back(h);
  }

  // The taskbar plays the role of the Dock when it is at the bottom and not
  // auto-hidden.
  std::vector<double> dock;
  APPBARDATA abd{sizeof(APPBARDATA)};
  const UINT state = static_cast<UINT>(SHAppBarMessage(ABM_GETSTATE, &abd));
  if (!(state & ABS_AUTOHIDE) && SHAppBarMessage(ABM_GETTASKBARPOS, &abd) &&
      abd.uEdge == ABE_BOTTOM) {
    const RECT& t = abd.rc;
    dock = {(t.left - ox) / s, (t.top - oy) / s, (t.right - t.left) / s,
            (t.bottom - t.top) / s};
  }

  std::vector<double> signature = flat;
  signature.insert(signature.end(), dock.begin(), dock.end());
  signature.push_back(sw);
  signature.push_back(sh);
  if (signature == last_geometry_) return;
  last_geometry_ = std::move(signature);

  EncodableList windows_list(flat.begin(), flat.end());
  EncodableList dock_list(dock.begin(), dock.end());
  EncodableMap map{
      {EncodableValue("screenW"), EncodableValue(sw)},
      {EncodableValue("screenH"), EncodableValue(sh)},
      {EncodableValue("menuBarH"), EncodableValue(0.0)},  // no menu bar: icicles hang from the top edge
      {EncodableValue("menuBarThickness"), EncodableValue(0.0)},
      {EncodableValue("dock"), EncodableValue(dock_list)},
      {EncodableValue("windows"), EncodableValue(windows_list)},
  };
  channel_->InvokeMethod("geometry", std::make_unique<EncodableValue>(map));
}

void FlutterWindow::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = call.arguments();
  const std::string& method = call.method_name();
  if (method == "setClickThrough") {
    const bool* enabled = args ? std::get_if<bool>(args) : nullptr;
    click_through_enabled_ = enabled ? *enabled : true;
    UpdateInteractive(true);
    result->Success();
  } else if (method == "setLevel") {
    const std::string* level = args ? std::get_if<std::string>(args) : nullptr;
    ApplyLevel(level ? *level : "aboveWindows");
    result->Success();
  } else if (method == "updateMenuState") {
    const auto* map = args ? std::get_if<EncodableMap>(args) : nullptr;
    if (map) menu_state_ = *map;
    result->Success();
  } else if (method == "setHitRegions") {
    hit_regions_.clear();
    const auto* data = args ? std::get_if<std::vector<double>>(args) : nullptr;
    if (data) {
      const double s = monitor_.scale;
      const LONG ox = monitor_.rect.left, oy = monitor_.rect.top;
      for (size_t i = 0; i + 3 < data->size(); i += 4) {
        RECT r;
        r.left = ox + static_cast<LONG>((*data)[i] * s);
        r.top = oy + static_cast<LONG>((*data)[i + 1] * s);
        r.right = r.left + static_cast<LONG>((*data)[i + 2] * s + 1);
        r.bottom = r.top + static_cast<LONG>((*data)[i + 3] * s + 1);
        hit_regions_.push_back(r);
      }
    }
    result->Success();
  } else if (method == "diagnostics") {
    HWND hwnd = GetHandle();
    RECT r{};
    GetWindowRect(hwnd, &r);
    const LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    HWND child = GetWindow(hwnd, GW_CHILD);
    RECT cr{};
    if (child) GetWindowRect(child, &cr);
    EncodableMap map{
        {EncodableValue("visible"), EncodableValue(IsWindowVisible(hwnd) == TRUE)},
        {EncodableValue("rect"), EncodableValue(EncodableList{
             EncodableValue(static_cast<int>(r.left)), EncodableValue(static_cast<int>(r.top)),
             EncodableValue(static_cast<int>(r.right)), EncodableValue(static_cast<int>(r.bottom))})},
        {EncodableValue("childRect"), EncodableValue(EncodableList{
             EncodableValue(static_cast<int>(cr.left)), EncodableValue(static_cast<int>(cr.top)),
             EncodableValue(static_cast<int>(cr.right)), EncodableValue(static_cast<int>(cr.bottom))})},
        {EncodableValue("childVisible"), EncodableValue(child != nullptr && IsWindowVisible(child) == TRUE)},
        {EncodableValue("exStyle"), EncodableValue(static_cast<int64_t>(ex))},
        {EncodableValue("topmost"), EncodableValue((ex & WS_EX_TOPMOST) != 0)},
        {EncodableValue("ignoringMouse"), EncodableValue(ignoring_mouse_)},
        {EncodableValue("scale"), EncodableValue(monitor_.scale)},
        {EncodableValue("hitRegions"), EncodableValue(static_cast<int>(hit_regions_.size()))},
        {EncodableValue("trayAdded"), EncodableValue(tray_added_)},
        {EncodableValue("styleReapplied"), EncodableValue(style_reapplied_)},
    };
    result->Success(EncodableValue(map));
  } else if (method == "requestGeometry") {
    last_geometry_.clear();
    PollGeometry();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

std::string FlutterWindow::StateString(const char* key) const {
  auto it = menu_state_.find(EncodableValue(key));
  if (it == menu_state_.end()) return "";
  const auto* s = std::get_if<std::string>(&it->second);
  return s ? *s : "";
}

bool FlutterWindow::StateBool(const char* key) const {
  auto it = menu_state_.find(EncodableValue(key));
  if (it == menu_state_.end()) return false;
  const auto* b = std::get_if<bool>(&it->second);
  return b && *b;
}

void FlutterWindow::AddTrayIcon() {
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATA);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kTrayId;
  tray_icon_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  tray_icon_.uCallbackMessage = kTrayMessage;
  tray_icon_.hIcon =
      LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_icon_.szTip, L"Winter");
  tray_added_ = Shell_NotifyIcon(NIM_ADD, &tray_icon_) == TRUE;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_added_) {
    Shell_NotifyIcon(NIM_DELETE, &tray_icon_);
    tray_added_ = false;
  }
}

void FlutterWindow::ShowTrayMenu() {
  menu_actions_.clear();
  auto add = [this](HMENU menu, const wchar_t* label, const std::string& action,
                    bool checked) {
    UINT id = kMenuBase + static_cast<UINT>(menu_actions_.size());
    menu_actions_.push_back(action);
    AppendMenu(menu, MF_STRING | (checked ? MF_CHECKED : MF_UNCHECKED), id,
               label);
  };
  auto sub = [&](HMENU root, const wchar_t* title, const char* key,
                 std::vector<std::pair<const wchar_t*, std::string>> options) {
    HMENU m = CreatePopupMenu();
    const std::string current = StateString(key);
    for (auto& [label, value] : options) {
      add(m, label, std::string(key) + ":" + value, current == value);
    }
    AppendMenu(root, MF_POPUP, reinterpret_cast<UINT_PTR>(m), title);
  };

  HMENU menu = CreatePopupMenu();
  add(menu, StateBool("paused") ? L"Resume Snow" : L"Pause Snow",
      "togglePause", false);
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  sub(menu, L"Snowfall", "intensity",
      {{L"Light", "light"},
       {L"Normal", "normal"},
       {L"Heavy", "heavy"},
       {L"Blizzard", "blizzard"}});
  sub(menu, L"Quality", "quality",
      {{L"Ultra Low", "ultraLow"},
       {L"Low", "low"},
       {L"Medium", "medium"},
       {L"High", "high"},
       {L"Ultra", "ultra"}});
  sub(menu, L"Position", "level",
      {{L"Above Windows", "aboveWindows"}, {L"Behind Windows", "desktop"}});
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  add(menu, L"Clear All Snow", "clearSnow", false);
  add(menu, L"Show Performance Stats", "toggleStats", StateBool("showStats"));
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, kMenuQuit, L"Quit Winter");

  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(GetHandle());  // required so the menu closes properly
  UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY,
                            pt.x, pt.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);

  if (cmd == kMenuQuit) {
    DestroyWindow(GetHandle());
  } else if (cmd >= kMenuBase && cmd - kMenuBase < menu_actions_.size()) {
    SendMenuAction(menu_actions_[cmd - kMenuBase]);
  }
}

void FlutterWindow::SendMenuAction(const std::string& action) {
  if (channel_) {
    channel_->InvokeMethod("menuAction",
                           std::make_unique<EncodableValue>(action));
  }
}

void FlutterWindow::PublishVisibility(const char* reason) {
  if (!channel_) return;
  EncodableMap map{
      {EncodableValue("visible"), EncodableValue(!display_off_ && !suspended_)},
      {EncodableValue("reason"), EncodableValue(std::string(reason))},
  };
  channel_->InvokeMethod("visibility", std::make_unique<EncodableValue>(map));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_added_ = false;  // Explorer restarted
    AddTrayIcon();
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_TIMER:
      if (wparam == kMouseTimer) {
        UpdateInteractive(false);
        return 0;
      }
      if (wparam == kGeometryTimer) {
        PollGeometry();
        // The taskbar and other topmost windows can rise above us; re-assert
        // our place about once a second.
        if (level_ != "desktop" && ++topmost_tick_ >= 20) {
          topmost_tick_ = 0;
          SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        return 0;
      }
      break;
    case kTrayMessage:
      if (LOWORD(lparam) == WM_RBUTTONUP || LOWORD(lparam) == WM_LBUTTONUP) {
        ShowTrayMenu();
      }
      return 0;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_ERASEBKGND:
      return 1;  // never paint an opaque background
    case WM_WINDOWPOSCHANGING:
      if (level_ == "desktop") {
        auto* pos = reinterpret_cast<WINDOWPOS*>(lparam);
        pos->hwndInsertAfter = HWND_BOTTOM;
        pos->flags &= ~SWP_NOZORDER;
      }
      break;
    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
    case WM_SETTINGCHANGE: {
      LRESULT r = Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      FitToPrimaryMonitor();
      last_geometry_.clear();
      if (channel_) channel_->InvokeMethod("displaysChanged", nullptr);
      return r;
    }
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMSUSPEND) {
        suspended_ = true;
        PublishVisibility("sleep");
      } else if (wparam == PBT_APMRESUMEAUTOMATIC) {
        suspended_ = false;
        PublishVisibility("wake");
      } else if (wparam == PBT_POWERSETTINGCHANGE) {
        auto* setting = reinterpret_cast<POWERBROADCAST_SETTING*>(lparam);
        if (setting &&
            IsEqualGUID(setting->PowerSetting, GUID_CONSOLE_DISPLAY_STATE)) {
          display_off_ = setting->Data[0] == 0;  // 0 off, 1 on, 2 dimmed
          PublishVisibility(display_off_ ? "displayOff" : "displayOn");
        }
      }
      return TRUE;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
