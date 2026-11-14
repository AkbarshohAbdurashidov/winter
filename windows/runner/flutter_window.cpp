// Windows overlay. Written on macOS and compiled only in CI; see
// docs/PHASES.md for what has been verified on real Windows hardware.
#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cstdlib>
#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayId = 1;
constexpr UINT kMenuBase = 1000;
constexpr UINT kMenuQuit = 999;
constexpr UINT_PTR kMouseTimer = 1;     // 30 Hz cursor check
constexpr UINT_PTR kGeometryTimer = 2;  // 20 Hz desktop geometry
constexpr UINT kSyncMonitorsMessage = WM_APP + 2;

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

BOOL CALLBACK CollectMonitor(HMONITOR monitor, HDC, LPRECT, LPARAM lparam) {
  auto* list = reinterpret_cast<std::vector<MonitorInfo>*>(lparam);
  MONITORINFO info{sizeof(MONITORINFO)};
  if (GetMonitorInfo(monitor, &info)) {
    MonitorInfo m;
    m.rect = info.rcMonitor;  // physical pixels (PerMonitorV2 manifest)
    m.scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
    m.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
    list->push_back(m);
  }
  return TRUE;
}

// Primary display first.
std::vector<MonitorInfo> EnumerateMonitors() {
  std::vector<MonitorInfo> list;
  EnumDisplayMonitors(nullptr, nullptr, CollectMonitor,
                      reinterpret_cast<LPARAM>(&list));
  std::stable_sort(list.begin(), list.end(),
                   [](const MonitorInfo& a, const MonitorInfo& b) {
                     return a.primary && !b.primary;
                   });
  return list;
}

bool SameRect(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

// Bottom taskbar on the given display (primary or secondary), unless
// auto-hidden. Physical pixels.
bool FindTaskbar(const RECT& mon, RECT* out) {
  APPBARDATA abd{sizeof(APPBARDATA)};
  const UINT state = static_cast<UINT>(SHAppBarMessage(ABM_GETSTATE, &abd));
  if (state & ABS_AUTOHIDE) return false;
  for (const wchar_t* cls : {L"Shell_TrayWnd", L"Shell_SecondaryTrayWnd"}) {
    HWND h = nullptr;
    while ((h = FindWindowEx(nullptr, h, cls, nullptr)) != nullptr) {
      if (!IsWindowVisible(h)) continue;
      RECT t{};
      if (!GetWindowRect(h, &t)) continue;
      const LONG w = t.right - t.left, ht = t.bottom - t.top;
      if (w > ht && ht > 4 && t.left >= mon.left - 2 &&
          t.right <= mon.right + 2 && std::abs(t.bottom - mon.bottom) <= 2 &&
          t.top > mon.top) {
        *out = t;
        return true;
      }
    }
  }
  return false;
}

flutter::DartProject g_project(L"data");
std::vector<std::string> g_base_args;
std::vector<std::unique_ptr<FlutterWindow>> g_overlays;
int g_next_screen_id = 0;

std::unique_ptr<FlutterWindow> CreateOverlay(const MonitorInfo& monitor,
                                             bool is_host) {
  const int id = g_next_screen_id++;
  flutter::DartProject project = g_project;
  std::vector<std::string> args = g_base_args;
  args.push_back("--screen");
  args.push_back(std::to_string(id));
  project.set_dart_entrypoint_arguments(std::move(args));
  auto window = std::make_unique<FlutterWindow>(project, id, monitor, is_host);
  if (!window->Create(L"Winter", Win32Window::Point(0, 0),
                      Win32Window::Size(800, 600))) {
    return nullptr;
  }
  if (is_host) window->SetQuitOnClose(true);
  return window;
}

// One overlay per display; the host stays on the primary display.
void SyncMonitors() {
  std::vector<MonitorInfo> monitors = EnumerateMonitors();
  if (monitors.empty()) return;
  std::vector<bool> covered(monitors.size(), false);

  for (auto& w : g_overlays) {
    if (w->is_host()) {
      w->SetMonitor(monitors[0]);
      covered[0] = true;
    }
  }
  for (auto it = g_overlays.begin(); it != g_overlays.end();) {
    if ((*it)->is_host()) {
      ++it;
      continue;
    }
    bool keep = false;
    for (size_t i = 0; i < monitors.size(); ++i) {
      if (!covered[i] && SameRect(monitors[i].rect, (*it)->monitor().rect)) {
        (*it)->SetMonitor(monitors[i]);
        covered[i] = keep = true;
        break;
      }
    }
    if (keep) {
      ++it;
    } else {
      it = g_overlays.erase(it);  // destroys the window and its engine
    }
  }
  for (size_t i = 0; i < monitors.size(); ++i) {
    if (covered[i]) continue;
    if (auto w = CreateOverlay(monitors[i], false)) {
      g_overlays.push_back(std::move(w));
    }
  }
  for (auto& w : g_overlays) w->NotifyDisplaysChanged();
}
}  // namespace

bool StartOverlays(const flutter::DartProject& project) {
  g_project = project;
  g_base_args = GetCommandLineArguments();
  std::vector<MonitorInfo> monitors = EnumerateMonitors();
  if (monitors.empty()) {
    MonitorInfo m;
    m.rect = {0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
    m.primary = true;
    monitors.push_back(m);
  }
  auto host = CreateOverlay(monitors[0], true);
  if (!host) return false;
  g_overlays.push_back(std::move(host));
  for (size_t i = 1; i < monitors.size(); ++i) {
    if (auto w = CreateOverlay(monitors[i], false)) {
      g_overlays.push_back(std::move(w));
    }
  }
  return true;
}

void StopOverlays() { g_overlays.clear(); }

namespace {
void BroadcastMenuAction(const std::string& action) {
  for (auto& w : g_overlays) w->SendMenuAction(action);
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             int screen_id, const MonitorInfo& monitor,
                             bool is_host)
    : project_(project),
      screen_id_(screen_id),
      is_host_(is_host),
      monitor_(monitor) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  MakeTransparent();
  FitToMonitor();

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

  if (is_host_) {
    taskbar_created_message_ = RegisterWindowMessage(L"TaskbarCreated");
    AddTrayIcon();
  }
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

void FlutterWindow::SetMonitor(const MonitorInfo& monitor) {
  monitor_ = monitor;
  FitToMonitor();
}

void FlutterWindow::NotifyDisplaysChanged() {
  last_geometry_.clear();
  if (channel_) channel_->InvokeMethod("displaysChanged", nullptr);
}

void FlutterWindow::FitToMonitor() {
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
    RECT overlap{};
    if (!IntersectRect(&overlap, &r, &monitor_.rect)) continue;
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
  RECT t{};
  if (FindTaskbar(monitor_.rect, &t)) {
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
        {EncodableValue("screenId"), EncodableValue(screen_id_)},
        {EncodableValue("primary"), EncodableValue(is_host_)},
        {EncodableValue("overlays"), EncodableValue(static_cast<int>(g_overlays.size()))},
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

const EncodableMap* FlutterWindow::AccountState() const {
  auto it = menu_state_.find(EncodableValue("account"));
  if (it == menu_state_.end()) return nullptr;
  return std::get_if<EncodableMap>(&it->second);
}

bool FlutterWindow::AccountBool(const char* key) const {
  const EncodableMap* account = AccountState();
  if (!account) return false;
  auto it = account->find(EncodableValue(key));
  if (it == account->end()) return false;
  const auto* b = std::get_if<bool>(&it->second);
  return b && *b;
}

std::wstring FlutterWindow::AccountText(const char* key) const {
  const EncodableMap* account = AccountState();
  if (!account) return L"";
  auto it = account->find(EncodableValue(key));
  if (it == account->end()) return L"";
  const auto* s = std::get_if<std::string>(&it->second);
  if (!s || s->empty()) return L"";
  const int n = MultiByteToWideChar(CP_UTF8, 0, s->data(), static_cast<int>(s->size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s->data(), static_cast<int>(s->size()), w.data(), n);
  return w;
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

  const bool account_enabled = AccountBool("enabled");
  const bool pro = !account_enabled || AccountBool("pro");
  // Pro-only options stay visible; choosing one without Pro opens the Pro request page.
  const std::wstring pro_tag = pro ? L"" : L"  (Pro)";
  const std::wstring heavy = L"Heavy" + pro_tag, blizzard = L"Blizzard" + pro_tag;
  const std::wstring high = L"High" + pro_tag, ultra = L"Ultra" + pro_tag;

  HMENU menu = CreatePopupMenu();
  add(menu, StateBool("paused") ? L"Resume Snow" : L"Pause Snow",
      "togglePause", false);
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  if (account_enabled) {
    if (AccountBool("pro")) {
      const std::wstring plan = AccountText("planLabel");
      const std::wstring label = L"Winter Pro" + (plan.empty() ? L"" : L" \u00B7 " + plan);
      AppendMenu(menu, MF_STRING | MF_GRAYED, 0, label.c_str());
    } else {
      add(menu, L"Get Winter Pro\u2026", "account:upgrade", false);
    }
    AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  }
  sub(menu, L"Snowfall", "intensity",
      {{L"Light", "light"},
       {L"Normal", "normal"},
       {heavy.c_str(), "heavy"},
       {blizzard.c_str(), "blizzard"}});
  sub(menu, L"Quality", "quality",
      {{L"Ultra Low", "ultraLow"},
       {L"Low", "low"},
       {L"Medium", "medium"},
       {high.c_str(), "high"},
       {ultra.c_str(), "ultra"}});
  sub(menu, L"Position", "level",
      {{L"Above Windows", "aboveWindows"}, {L"Behind Windows", "desktop"}});
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  add(menu, L"Clear All Snow", "clearSnow", false);
  add(menu, L"Show Performance Stats", "toggleStats", StateBool("showStats"));
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  if (account_enabled) {
    if (AccountBool("linking")) {
      AppendMenu(menu, MF_STRING | MF_GRAYED, 0, L"Waiting for sign-in in your browser\u2026");
    } else if (AccountBool("signedIn")) {
      const std::wstring who = L"Signed in as " + AccountText("email");
      AppendMenu(menu, MF_STRING | MF_GRAYED, 0, who.c_str());
      add(menu, L"Manage Account\u2026", "account:manage", false);
      add(menu, L"Refresh Pro Status", "account:refresh", false);
      add(menu, L"Sign Out", "account:signOut", false);
    } else {
      add(menu, L"Sign In\u2026", "account:signIn", false);
    }
    AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  }
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
    // Every display's overlay follows the same settings.
    BroadcastMenuAction(menu_actions_[cmd - kMenuBase]);
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
      FitToMonitor();
      last_geometry_.clear();
      // Re-enumerate displays outside this handler: it may destroy windows.
      if (is_host_ && message != WM_DPICHANGED) {
        PostMessage(hwnd, kSyncMonitorsMessage, 0, 0);
      }
      return r;
    }
    case kSyncMonitorsMessage: {
      MSG pending;  // coalesce bursts of display notifications
      while (PeekMessage(&pending, hwnd, kSyncMonitorsMessage,
                         kSyncMonitorsMessage, PM_REMOVE)) {
      }
      SyncMonitors();
      return 0;
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
