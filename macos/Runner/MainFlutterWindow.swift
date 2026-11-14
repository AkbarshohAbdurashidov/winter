import Cocoa
import FlutterMacOS

/// Transparent, borderless overlay covering the primary screen.
///
/// An `NSPanel` with `.nonactivatingPanel` so clicking snow, snowballs or
/// icicles never steals focus from the app the user is working in.
class MainFlutterWindow: NSPanel {
  private var overlay: OverlayController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    self.contentViewController = flutterViewController

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

    RegisterGeneratedPlugins(registry: flutterViewController)

    overlay = OverlayController(window: self, messenger: flutterViewController.engine.binaryMessenger)
    overlay?.applyLevel("aboveWindows")
    overlay?.fitToScreen()

    super.awakeFromNib()
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// Native side of the `winter/overlay` channel.
///
/// - window level, click-through and interactive hit regions
/// - desktop geometry (other apps' windows, Dock, menu bar), polled off the main thread
/// - status-bar menu, occlusion and sleep notifications
final class OverlayController: NSObject {
  private weak var window: NSWindow?
  private let channel: FlutterMethodChannel
  private let statusItem: NSStatusItem
  private var menuState: [String: Any] = [:]
  private var observers: [NSObjectProtocol] = []
  private var screensAsleep = false
  private var occluded = false

  // Interactive regions (top-left origin, primary-screen points).
  private var hitRegions: [CGRect] = []
  private var mouseTimer: Timer?
  private var interactive = false
  private var clickThroughEnabled = true

  // Geometry polling.
  private let geometryQueue = DispatchQueue(label: "winter.geometry", qos: .utility)
  private var geometryTimer: DispatchSourceTimer?
  private var lastGeometry: [String: AnyHashable] = [:]
  private let ownPid = ProcessInfo.processInfo.processIdentifier
  private var dockCache: (key: String, rect: CGRect?, time: CFAbsoluteTime)?

  init(window: NSWindow, messenger: FlutterBinaryMessenger) {
    self.window = window
    self.channel = FlutterMethodChannel(name: "winter/overlay", binaryMessenger: messenger)
    self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    super.init()

    NSApp.setActivationPolicy(.accessory)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Winter")
      button.image?.isTemplate = true
    }
    rebuildMenu()
    observe()
    startMouseTracking()
    startGeometryPolling()
  }

  deinit {
    mouseTimer?.invalidate()
    geometryTimer?.cancel()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
  }

  // MARK: Channel

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setClickThrough":
      clickThroughEnabled = (call.arguments as? Bool) ?? true
      updateInteractive(force: true)
      result(nil)
    case "setLevel":
      applyLevel(call.arguments as? String ?? "aboveWindows")
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
      hitRegions = rects
      result(nil)
    case "diagnostics":
      let f = window?.frame ?? .zero
      result([
        "visible": window?.isVisible ?? false,
        "rect": [f.minX, f.minY, f.maxX, f.maxY],
        "level": window?.level.rawValue ?? 0,
        "ignoringMouse": window?.ignoresMouseEvents ?? true,
        "scale": window?.backingScaleFactor ?? 1,
        "hitRegions": hitRegions.count,
      ])
    case "requestGeometry":
      lastGeometry = [:]
      geometryQueue.async { [weak self] in self?.pollGeometry() }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func applyLevel(_ level: String) {
    guard let window = window else { return }
    if level == "desktop" {
      window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    } else {
      // Above app windows, the Dock (20) and the menu bar (24).
      window.level = .statusBar
    }
    window.orderFrontRegardless()
  }

  private var primaryScreen: NSScreen? { NSScreen.screens.first }

  func fitToScreen() {
    guard let window = window, let screen = primaryScreen else { return }
    window.setFrame(screen.frame, display: true)
  }

  private func send(_ method: String, _ args: Any?) {
    channel.invokeMethod(method, arguments: args)
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
    guard let window = window, let screen = primaryScreen else { return }
    // Never switch in the middle of a press: either the user is dragging in
    // another app, or they are dragging a snowball here.
    if !force && NSEvent.pressedMouseButtons != 0 { return }
    var wantInteractive = !clickThroughEnabled
    if !wantInteractive && !hitRegions.isEmpty {
      let loc = NSEvent.mouseLocation
      let p = CGPoint(x: loc.x - screen.frame.minX, y: screen.frame.maxY - loc.y)
      wantInteractive = hitRegions.contains { $0.contains(p) }
    }
    if force || wantInteractive != interactive {
      interactive = wantInteractive
      window.ignoresMouseEvents = !wantInteractive
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

  /// Runs on `geometryQueue`. Sends only when something changed.
  private func pollGeometry() {
    guard let info = DispatchQueue.main.sync(execute: { () -> (CGRect, CGRect)? in
      guard let s = self.primaryScreen else { return nil }
      return (s.frame, s.visibleFrame)
    }) else { return }
    let (frame, visible) = info
    var menuBarHeight = max(0, frame.maxY - visible.maxY)
    var statusBottom: CGFloat = -1

    var flat: [Double] = []
    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
      for w in list {  // front-to-back order
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let pid = w[kCGWindowOwnerPID as String] as? Int32
        // Menu-bar status items (layer 25) are on screen only while the menu
        // bar is shown; their bottom edge is the menu bar's bottom edge. This
        // also tracks an auto-hiding menu bar as it slides in and out.
        if layer == Int(CGWindowLevelForKey(.statusWindow)), pid != ownPid,
           let b = w[kCGWindowBounds as String] as? [String: Any],
           let r = CGRect(dictionaryRepresentation: b as CFDictionary),
           r.minY > -60, r.minY <= 2, r.height <= 50 {
          statusBottom = max(statusBottom, r.maxY)
        }
        guard layer == 0,
              pid != ownPid,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary),
              rect.width >= 120, rect.height >= 60,
              let id = w[kCGWindowNumber as String] as? Int
        else { continue }
        flat.append(contentsOf: [Double(id), rect.minX, rect.minY, rect.width, rect.height])
      }
    }

    if statusBottom >= 0 { menuBarHeight = statusBottom }
    let dock = estimateDockRect(frame: frame, visible: visible)
    let geometry: [String: AnyHashable] = [
      "screenW": frame.width,
      "screenH": frame.height,
      "menuBarH": menuBarHeight,
      "menuBarThickness": NSStatusBar.system.thickness,
      "dock": dock.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
      "windows": flat,
    ]
    if geometry == lastGeometry { return }
    lastGeometry = geometry
    DispatchQueue.main.async { [weak self] in self?.send("geometry", geometry) }
  }

  /// The Dock's frame is not public API. Its height is known from the
  /// screen's visible frame; its width is estimated from the Dock's
  /// preferences and the running apps. Bottom-docked, non-hidden Dock only.
  private func estimateDockRect(frame: CGRect, visible: CGRect) -> CGRect? {
    let height = visible.minY - frame.minY
    guard height > 4 else { return nil }
    let now = CFAbsoluteTimeGetCurrent()
    let key = "\(frame)|\(visible)"
    if let c = dockCache, c.key == key, now - c.time < 5 { return c.rect }

    func pref(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, "com.apple.dock" as CFString) }
    let orientation = pref("orientation") as? String ?? "bottom"
    var rect: CGRect?
    if orientation == "bottom" {
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
      let appIcons = 1 + apps.count + recents.count + runningExtra  // Finder + pinned + recents + running
      let rightIcons = others.count + 1  // folders/stacks + Trash
      let separators = CGFloat(1 + ((showRecents && !recents.isEmpty) || runningExtra > 0 ? 1 : 0))
      let slot = tile * 1.0 + 4
      let width = CGFloat(appIcons + rightIcons) * slot + separators * 13 + (height - tile)
      // An overfull Dock shrinks its icons to fit, keeping ~36 pt margins.
      let w = min(width, frame.width - 72)
      // Top-left origin, points.
      rect = CGRect(x: (frame.width - w) / 2, y: frame.height - height, width: w, height: height)
    }
    dockCache = (key, rect, now)
    return rect
  }

  // MARK: Visibility

  private func observe() {
    let nc = NotificationCenter.default
    let ws = NSWorkspace.shared.notificationCenter

    observers.append(nc.addObserver(
      forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
    ) { [weak self] _ in
      guard let self = self, let window = self.window else { return }
      self.occluded = !window.occlusionState.contains(.visible)
      self.publishVisibility(reason: "occlusion")
    })

    observers.append(nc.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.fitToScreen()
      self?.dockCache = nil
      self?.send("displaysChanged", nil)
    })

    for (name, asleep) in [
      (NSWorkspace.screensDidSleepNotification, true),
      (NSWorkspace.willSleepNotification, true),
      (NSWorkspace.screensDidWakeNotification, false),
      (NSWorkspace.didWakeNotification, false),
    ] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.screensAsleep = asleep
        self?.publishVisibility(reason: asleep ? "sleep" : "wake")
      })
    }
    // App launches/quits change the Dock width.
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.geometryQueue.async { self?.dockCache = nil }
      })
    }
  }

  private func publishVisibility(reason: String) {
    send("visibility", ["visible": !occluded && !screensAsleep, "reason": reason])
  }

  // MARK: Menu

  private func rebuildMenu() {
    let menu = NSMenu()
    let paused = menuState["paused"] as? Bool ?? false
    menu.addItem(item(paused ? "Resume Snow" : "Pause Snow", "togglePause", key: "p"))
    menu.addItem(.separator())

    menu.addItem(submenu("Snowfall", key: "intensity", current: menuState["intensity"] as? String, options: [
      ("Light", "light"), ("Normal", "normal"), ("Heavy", "heavy"), ("Blizzard", "blizzard"),
    ]))
    menu.addItem(submenu("Quality", key: "quality", current: menuState["quality"] as? String, options: [
      ("Ultra Low", "ultraLow"), ("Low", "low"), ("Medium", "medium"), ("High", "high"), ("Ultra", "ultra"),
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
    menu.addItem(NSMenuItem(title: "Quit Winter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    statusItem.menu = menu
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

  @objc private func menuAction(_ sender: NSMenuItem) {
    guard let action = sender.representedObject as? String else { return }
    send("menuAction", action)
  }
}
