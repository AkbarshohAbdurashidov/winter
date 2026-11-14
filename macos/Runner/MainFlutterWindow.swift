import Cocoa
import FlutterMacOS

/// Borderless, transparent, non-activating panel used for every screen's
/// overlay. Clicking snow never steals focus from the user's app.
class OverlayPanel: NSPanel {
  func configureAsOverlay() {
    styleMask = [.borderless, .nonactivatingPanel]
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isReleasedWhenClosed = false
    ignoresMouseEvents = true
    acceptsMouseMovedEvents = true
    collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The window from MainMenu.xib. It becomes the overlay of the first screen;
/// `OverlayManager` creates one more overlay (with its own Flutter engine)
/// for each additional display.
class MainFlutterWindow: OverlayPanel {
  override func awakeFromNib() {
    let controller = ScreenOverlay.makeViewController(screenId: 0)
    self.contentViewController = controller
    configureAsOverlay()
    OverlayManager.shared.start(primaryPanel: self, controller: controller)
    super.awakeFromNib()
  }
}

// MARK: - One screen

/// The overlay for one display: its panel, Flutter view, channel and the
/// interactive regions reported by its Dart side.
final class ScreenOverlay: NSObject {
  let panel: OverlayPanel
  let controller: FlutterViewController
  let channel: FlutterMethodChannel
  let isPrimary: Bool
  var displayID: CGDirectDisplayID = 0

  // Main-thread state.
  var hitRegions: [CGRect] = []
  var interactive = false
  var occluded = false

  // Geometry-queue state.
  var lastGeometry: [String: AnyHashable] = [:]

  static func makeViewController(screenId: Int) -> FlutterViewController {
    let project = FlutterDartProject()
    // Keep command-line flags (e.g. --diagnostics) and add the screen id.
    project.dartEntrypointArguments = Array(CommandLine.arguments.dropFirst()) + ["--screen", "\(screenId)"]
    let controller = FlutterViewController(project: project)
    controller.backgroundColor = .clear
    RegisterGeneratedPlugins(registry: controller)
    return controller
  }

  init(panel: OverlayPanel, controller: FlutterViewController, isPrimary: Bool) {
    self.panel = panel
    self.controller = controller
    self.isPrimary = isPrimary
    self.channel = FlutterMethodChannel(
      name: "winter/overlay", binaryMessenger: controller.engine.binaryMessenger)
    super.init()
  }

  /// Creates an overlay (and Flutter engine) for an additional display.
  static func create(for screen: NSScreen, id: Int) -> ScreenOverlay {
    let controller = makeViewController(screenId: id)
    let panel = OverlayPanel(
      contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.contentViewController = controller
    panel.configureAsOverlay()
    return ScreenOverlay(panel: panel, controller: controller, isPrimary: false)
  }

  var screen: NSScreen? {
    NSScreen.screens.first { $0.displayID == displayID }
  }

  func send(_ method: String, _ args: Any?) {
    channel.invokeMethod(method, arguments: args)
  }

  func destroy() {
    channel.setMethodCallHandler(nil)
    panel.orderOut(nil)
    panel.contentViewController = nil
    controller.engine.shutDownEngine()
    panel.close()
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }
}

// MARK: - Manager

/// Owns everything shared between screens: the status-bar menu, desktop
/// geometry polling (one CGWindowList call for all screens), the cursor
/// check for interactive regions, and display/sleep notifications.
final class OverlayManager: NSObject {
  static let shared = OverlayManager()

  private var overlays: [ScreenOverlay] = []
  private var statusItem: NSStatusItem?
  private var menuState: [String: Any] = [:]
  private var level = "aboveWindows"
  private var clickThroughEnabled = true
  private var observers: [NSObjectProtocol] = []
  private var screensAsleep = false
  private var mouseTimer: Timer?
  private var nextScreenId = 1

  private let geometryQueue = DispatchQueue(label: "winter.geometry", qos: .utility)
  private var geometryTimer: DispatchSourceTimer?
  private let ownPid = ProcessInfo.processInfo.processIdentifier
  private var dockCache: [String: (rect: CGRect?, time: CFAbsoluteTime)] = [:]  // geometry queue

  func start(primaryPanel: OverlayPanel, controller: FlutterViewController) {
    NSApp.setActivationPolicy(.accessory)
    let primary = ScreenOverlay(panel: primaryPanel, controller: controller, isPrimary: true)
    primary.displayID = NSScreen.screens.first?.displayID ?? 0
    attach(primary)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Winter")
    item.button?.image?.isTemplate = true
    statusItem = item
    rebuildMenu()

    syncScreens()
    observe()
    startMouseTracking()
    startGeometryPolling()
  }

  private func attach(_ overlay: ScreenOverlay) {
    overlays.append(overlay)
    overlay.channel.setMethodCallHandler { [weak self, weak overlay] call, result in
      guard let self = self, let overlay = overlay else { return result(nil) }
      self.handle(call, from: overlay, result: result)
    }
  }

  // MARK: Screens

  /// Creates/removes overlays so that every display has exactly one.
  func syncScreens() {
    let screens = NSScreen.screens
    let ids = Set(screens.map(\.displayID))

    // Remove overlays of displays that are gone (the primary is reassigned).
    for overlay in overlays where !ids.contains(overlay.displayID) && !overlay.isPrimary {
      overlay.destroy()
    }
    overlays.removeAll { !ids.contains($0.displayID) && !$0.isPrimary }

    if let primary = overlays.first(where: \.isPrimary), !ids.contains(primary.displayID) {
      let taken = Set(overlays.filter { !$0.isPrimary }.map(\.displayID))
      primary.displayID = screens.first { !taken.contains($0.displayID) }?.displayID
        ?? screens.first?.displayID ?? 0
      if overlays.contains(where: { !$0.isPrimary && $0.displayID == primary.displayID }) {
        // Every remaining display already has an overlay; keep the primary on the first.
        primary.displayID = screens.first?.displayID ?? 0
      }
    }

    for screen in screens where !overlays.contains(where: { $0.displayID == screen.displayID }) {
      let overlay = ScreenOverlay.create(for: screen, id: nextScreenId)
      nextScreenId += 1
      overlay.displayID = screen.displayID
      attach(overlay)
    }

    for overlay in overlays {
      if let screen = overlay.screen {
        overlay.panel.setFrame(screen.frame, display: true)
      }
      applyLevel(to: overlay)
      overlay.panel.ignoresMouseEvents = !(overlay.interactive || !clickThroughEnabled)
    }
    geometryQueue.async { [weak self] in
      self?.dockCache.removeAll()
      self?.overlays.forEach { $0.lastGeometry = [:] }
    }
  }

  // MARK: Channel

  private func handle(_ call: FlutterMethodCall, from overlay: ScreenOverlay,
                      result: @escaping FlutterResult) {
    switch call.method {
    case "setClickThrough":
      clickThroughEnabled = (call.arguments as? Bool) ?? true
      updateInteractive(force: true)
      result(nil)
    case "setLevel":
      level = call.arguments as? String ?? "aboveWindows"
      overlays.forEach(applyLevel(to:))
      result(nil)
    case "updateMenuState":
      menuState = call.arguments as? [String: Any] ?? [:]
      rebuildMenu()
      result(nil)
    case "setHitRegions":
      var rects: [CGRect] = []
      if let data = call.arguments as? FlutterStandardTypedData {
        let values = data.data.withUnsafeBytes { Array($0.bindMemory(to: Float64.self)) }
        var i = 0
        while i + 3 < values.count {
          rects.append(CGRect(x: values[i], y: values[i + 1], width: values[i + 2], height: values[i + 3]))
          i += 4
        }
      }
      overlay.hitRegions = rects
      result(nil)
    case "requestGeometry":
      geometryQueue.async { [weak self, weak overlay] in
        overlay?.lastGeometry = [:]
        self?.pollGeometry()
      }
      result(nil)
    case "diagnostics":
      let f = overlay.panel.frame
      result([
        "visible": overlay.panel.isVisible,
        "rect": [f.minX, f.minY, f.maxX, f.maxY],
        "level": overlay.panel.level.rawValue,
        "ignoringMouse": overlay.panel.ignoresMouseEvents,
        "scale": overlay.panel.backingScaleFactor,
        "hitRegions": overlay.hitRegions.count,
        "screens": NSScreen.screens.count,
        "overlays": overlays.count,
        "primary": overlay.isPrimary,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func applyLevel(to overlay: ScreenOverlay) {
    if level == "desktop" {
      overlay.panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    } else {
      // Above app windows, the Dock (20) and the menu bar (24).
      overlay.panel.level = .statusBar
    }
    overlay.panel.orderFrontRegardless()
  }

  private func broadcast(_ method: String, _ args: Any?) {
    overlays.forEach { $0.send(method, args) }
  }

  // MARK: Interactive regions

  private func startMouseTracking() {
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.updateInteractive(force: false)
    }
    RunLoop.main.add(timer, forMode: .common)
    mouseTimer = timer
  }

  private func updateInteractive(force: Bool) {
    // Never switch in the middle of a press (dragging elsewhere, or dragging
    // a snowball here).
    if !force && NSEvent.pressedMouseButtons != 0 { return }
    let loc = NSEvent.mouseLocation
    for overlay in overlays {
      var want = !clickThroughEnabled
      if !want, !overlay.hitRegions.isEmpty, let screen = overlay.screen,
         screen.frame.contains(loc) {
        let p = CGPoint(x: loc.x - screen.frame.minX, y: screen.frame.maxY - loc.y)
        want = overlay.hitRegions.contains { $0.contains(p) }
      }
      if force || want != overlay.interactive {
        overlay.interactive = want
        overlay.panel.ignoresMouseEvents = !want
      }
    }
  }

  // MARK: Geometry

  private func startGeometryPolling() {
    let timer = DispatchSource.makeTimerSource(queue: geometryQueue)
    timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(50), leeway: .milliseconds(5))
    timer.setEventHandler { [weak self] in self?.pollGeometry() }
    timer.resume()
    geometryTimer = timer
  }

  private struct ScreenInfo {
    let overlay: ScreenOverlay
    let frame: CGRect      // Cocoa coordinates
    let visible: CGRect    // Cocoa coordinates
    let cgFrame: CGRect    // global top-left coordinates (CGWindowList space)
  }

  /// Runs on `geometryQueue`: one window-list query for all screens, then a
  /// per-screen message only when that screen's geometry changed.
  private func pollGeometry() {
    let infos: [ScreenInfo] = DispatchQueue.main.sync {
      let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
      return overlays.compactMap { overlay in
        guard let s = overlay.screen else { return nil }
        let f = s.frame
        let cg = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
        return ScreenInfo(overlay: overlay, frame: f, visible: s.visibleFrame, cgFrame: cg)
      }
    }
    if infos.isEmpty { return }

    var windows: [(id: Int, rect: CGRect)] = []
    var statusItems: [CGRect] = []
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
      for w in list {  // front-to-back order
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let pid = w[kCGWindowOwnerPID as String] as? Int32
        guard pid != ownPid,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
        if layer == Int(CGWindowLevelForKey(.statusWindow)), rect.height <= 50 {
          statusItems.append(rect)
          continue
        }
        guard layer == 0,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
              rect.width >= 120, rect.height >= 60,
              let id = w[kCGWindowNumber as String] as? Int else { continue }
        windows.append((id, rect))
      }
    }

    for info in infos {
      let screen = info.cgFrame
      var flat: [Double] = []
      for w in windows where w.rect.intersects(screen) {
        flat.append(contentsOf: [Double(w.id), w.rect.minX - screen.minX, w.rect.minY - screen.minY,
                                 w.rect.width, w.rect.height])
      }
      // Menu bar: status items on this screen's top edge are on screen only
      // while its menu bar is shown (also tracks an auto-hiding menu bar).
      var menuBarHeight = max(0, info.frame.maxY - info.visible.maxY)
      var statusBottom: CGFloat = -1
      for r in statusItems where r.midX >= screen.minX && r.midX <= screen.maxX
        && r.minY > screen.minY - 60 && r.minY <= screen.minY + 2 {
        statusBottom = max(statusBottom, r.maxY - screen.minY)
      }
      if statusBottom >= 0 { menuBarHeight = statusBottom }

      let dock = estimateDockRect(frame: info.frame, visible: info.visible)
      let geometry: [String: AnyHashable] = [
        "screenW": info.frame.width,
        "screenH": info.frame.height,
        "menuBarH": menuBarHeight,
        "menuBarThickness": NSStatusBar.system.thickness,
        "dock": dock.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
        "windows": flat,
      ]
      if geometry == info.overlay.lastGeometry { continue }
      info.overlay.lastGeometry = geometry
      let overlay = info.overlay
      DispatchQueue.main.async { overlay.send("geometry", geometry) }
    }
  }

  /// The Dock's frame is not public API. Its height comes from the screen's
  /// visible frame (only the screen showing the Dock has an inset); its
  /// width is estimated from the Dock's preferences and running apps.
  /// Bottom-docked, non-hidden Dock only. Result is in screen-local,
  /// top-left coordinates.
  private func estimateDockRect(frame: CGRect, visible: CGRect) -> CGRect? {
    let height = visible.minY - frame.minY
    guard height > 4 else { return nil }
    let now = CFAbsoluteTimeGetCurrent()
    let key = "\(frame)|\(visible)"
    if let c = dockCache[key], now - c.time < 5 { return c.rect }

    func pref(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, "com.apple.dock" as CFString) }
    var rect: CGRect?
    if (pref("orientation") as? String ?? "bottom") == "bottom" {
      let tile = CGFloat((pref("tilesize") as? NSNumber)?.doubleValue ?? 48)
      let apps = pref("persistent-apps") as? [[String: Any]] ?? []
      let others = pref("persistent-others") as? [[String: Any]] ?? []
      let showRecents = (pref("show-recents") as? NSNumber)?.boolValue ?? true
      let recents = showRecents ? (pref("recent-apps") as? [[String: Any]] ?? []) : []

      func bundleId(_ tile: [String: Any]) -> String? {
        ((tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String)?.lowercased()
      }
      var pinned = Set(apps.compactMap(bundleId))
      pinned.formUnion(recents.compactMap(bundleId))
      pinned.insert("com.apple.finder")
      let runningExtra = DispatchQueue.main.sync {
        NSWorkspace.shared.runningApplications.filter {
          $0.activationPolicy == .regular && !pinned.contains(($0.bundleIdentifier ?? "").lowercased())
        }.count
      }
      let appIcons = 1 + apps.count + recents.count + runningExtra
      let rightIcons = others.count + 1  // folders/stacks + Trash
      let separators = CGFloat(1 + ((showRecents && !recents.isEmpty) || runningExtra > 0 ? 1 : 0))
      let width = CGFloat(appIcons + rightIcons) * (tile + 4) + separators * 13 + (height - tile)
      // An overfull Dock shrinks its icons to fit, keeping ~36 pt margins.
      let w = min(width, frame.width - 72)
      rect = CGRect(x: (frame.width - w) / 2, y: frame.height - height, width: w, height: height)
    }
    dockCache[key] = (rect, now)
    return rect
  }

  // MARK: Notifications

  private func observe() {
    let nc = NotificationCenter.default
    let ws = NSWorkspace.shared.notificationCenter

    observers.append(nc.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self = self,
            let overlay = self.overlays.first(where: { $0.panel === note.object as AnyObject }) else { return }
      overlay.occluded = !overlay.panel.occlusionState.contains(.visible)
      self.publishVisibility(overlay, reason: "occlusion")
    })

    observers.append(nc.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.syncScreens()
      self?.broadcast("displaysChanged", nil)
    })

    for (name, asleep) in [
      (NSWorkspace.screensDidSleepNotification, true),
      (NSWorkspace.willSleepNotification, true),
      (NSWorkspace.screensDidWakeNotification, false),
      (NSWorkspace.didWakeNotification, false),
    ] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        guard let self = self else { return }
        self.screensAsleep = asleep
        self.overlays.forEach { self.publishVisibility($0, reason: asleep ? "sleep" : "wake") }
      })
    }
    // App launches/quits change the Dock width.
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.geometryQueue.async { self?.dockCache.removeAll() }
      })
    }
  }

  private func publishVisibility(_ overlay: ScreenOverlay, reason: String) {
    overlay.send("visibility", ["visible": !overlay.occluded && !screensAsleep, "reason": reason])
  }

  // MARK: Menu

  private func rebuildMenu() {
    let menu = NSMenu()
    let account = menuState["account"] as? [String: Any] ?? [:]
    let accountEnabled = account["enabled"] as? Bool ?? false
    let pro = !accountEnabled || (account["pro"] as? Bool ?? false)

    let paused = menuState["paused"] as? Bool ?? false
    menu.addItem(item(paused ? "Resume Snow" : "Pause Snow", "togglePause", key: "p"))
    menu.addItem(.separator())

    if accountEnabled {
      if account["pro"] as? Bool ?? false {
        let plan = account["planLabel"] as? String ?? ""
        menu.addItem(disabled("❄︎ Winter Pro" + (plan.isEmpty ? "" : " · \(plan)")))
      } else {
        menu.addItem(item("Get Winter Pro…", "account:upgrade"))
      }
      menu.addItem(.separator())
    }

    // Pro-only options stay visible; choosing one without Pro opens the paywall.
    let proTag = pro ? "" : "  (Pro)"
    menu.addItem(submenu("Snowfall", key: "intensity", current: menuState["intensity"] as? String, options: [
      ("Light", "light"), ("Normal", "normal"), ("Heavy" + proTag, "heavy"), ("Blizzard" + proTag, "blizzard"),
    ]))
    menu.addItem(submenu("Quality", key: "quality", current: menuState["quality"] as? String, options: [
      ("Ultra Low", "ultraLow"), ("Low", "low"), ("Medium", "medium"), ("High" + proTag, "high"), ("Ultra" + proTag, "ultra"),
    ]))
    menu.addItem(submenu("Position", key: "level", current: menuState["level"] as? String, options: [
      ("Above Windows", "aboveWindows"), ("On Desktop (behind windows)", "desktop"),
    ]))
    menu.addItem(.separator())
    menu.addItem(item("Clear All Snow", "clearSnow"))
    let stats = item("Show Performance Stats", "toggleStats")
    stats.state = (menuState["showStats"] as? Bool ?? false) ? .on : .off
    menu.addItem(stats)
    menu.addItem(.separator())

    if accountEnabled {
      if account["linking"] as? Bool ?? false {
        menu.addItem(disabled("Waiting for sign-in in your browser…"))
      } else if account["signedIn"] as? Bool ?? false {
        menu.addItem(disabled("Signed in as \(account["email"] as? String ?? "")"))
        menu.addItem(item("Manage Account…", "account:manage"))
        menu.addItem(item("Refresh Pro Status", "account:refresh"))
        menu.addItem(item("Sign Out", "account:signOut"))
      } else {
        menu.addItem(item("Sign In…", "account:signIn"))
      }
      menu.addItem(.separator())
    }
    menu.addItem(NSMenuItem(title: "Quit Winter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem?.menu = menu
  }

  private func disabled(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  private func item(_ title: String, _ action: String, key: String = "") -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: key)
    item.target = self
    item.representedObject = action
    return item
  }

  private func submenu(_ title: String, key: String, current: String?, options: [(String, String)]) -> NSMenuItem {
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for (label, value) in options {
      let child = item(label, "\(key):\(value)")
      child.state = (current == value) ? .on : .off
      sub.addItem(child)
    }
    parent.submenu = sub
    return parent
  }

  /// Menu actions go to every screen so all overlays stay in the same state.
  @objc private func menuAction(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? String else { return }
    broadcast("menuAction", action)
  }
}
