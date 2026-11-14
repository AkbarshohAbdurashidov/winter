import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Where the overlay window sits in the window stack.
enum OverlayLevel {
  /// Above normal application windows (snow falls over everything).
  aboveWindows,

  /// Just above the wallpaper, below desktop icons and all windows.
  desktop,
}

/// Events coming from the native side.
sealed class OverlayEvent {
  const OverlayEvent();
}

/// A menu-bar / tray menu item was chosen. [action] is a stable string id.
class MenuActionEvent extends OverlayEvent {
  const MenuActionEvent(this.action);
  final String action;
}

/// The overlay became visible/invisible (occluded, screens asleep, etc.).
class VisibilityEvent extends OverlayEvent {
  const VisibilityEvent({required this.visible, required this.reason});
  final bool visible;
  final String reason;
}

/// Display configuration changed (resolution, scale, monitors).
class DisplaysChangedEvent extends OverlayEvent {
  const DisplaysChangedEvent();
}

/// Desktop geometry in overlay coordinates (top-left origin, logical px).
class GeometryEvent extends OverlayEvent {
  const GeometryEvent({
    required this.screenWidth,
    required this.screenHeight,
    required this.menuBarHeight,
    required this.menuBarThickness,
    required this.dock,
    required this.windows,
  });

  final double screenWidth, screenHeight;

  /// 0 when the menu bar is auto-hidden (or in a full-screen space).
  final double menuBarHeight;
  final double menuBarThickness;

  /// Estimated Dock frame, or null when hidden / not at the bottom.
  final Rect? dock;

  /// Other apps' windows, front-to-back.
  final List<DesktopWindow> windows;
}

class DesktopWindow {
  const DesktopWindow(this.id, this.rect);
  final int id;
  final Rect rect;
}

/// State mirrored into the native menu so check marks stay in sync.
class OverlayMenuState {
  const OverlayMenuState({
    required this.paused,
    required this.level,
    required this.intensity,
    required this.quality,
    required this.showStats,
  });

  final bool paused;
  final OverlayLevel level;
  final String intensity;
  final String quality;
  final bool showStats;

  Map<String, Object> toMap() => {
        'paused': paused,
        'level': level.name,
        'intensity': intensity,
        'quality': quality,
        'showStats': showStats,
      };
}

/// Platform-neutral interface for the native overlay window.
///
/// Implementations must keep traffic low-frequency: nothing here is called
/// per frame.
abstract interface class OverlayPlatform {
  Stream<OverlayEvent> get events;
  Future<void> setClickThrough(bool enabled);
  Future<void> setLevel(OverlayLevel level);
  Future<void> updateMenuState(OverlayMenuState state);

  /// Areas where the overlay should capture the mouse (snow piles,
  /// snowballs, icicles). Everywhere else stays click-through.
  Future<void> setHitRegions(List<Rect> regions);

  /// Asks the native side to resend the desktop geometry.
  Future<void> requestGeometry();

  /// Native window state for diagnostics (empty if unsupported).
  Future<Map<String, Object?>> diagnostics();
  Future<void> dispose();
}

/// MethodChannel implementation shared by the macOS and Windows runners.
class MethodChannelOverlayPlatform implements OverlayPlatform {
  MethodChannelOverlayPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('winter/overlay') {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final StreamController<OverlayEvent> _events = StreamController.broadcast();

  @override
  Stream<OverlayEvent> get events => _events.stream;

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'menuAction':
        _events.add(MenuActionEvent(args as String));
      case 'visibility':
        final map = (args as Map).cast<String, Object?>();
        _events.add(VisibilityEvent(
          visible: map['visible'] == true,
          reason: map['reason'] as String? ?? 'unknown',
        ));
      case 'displaysChanged':
        _events.add(const DisplaysChangedEvent());
      case 'geometry':
        _events.add(_parseGeometry((args as Map).cast<String, Object?>()));
    }
    return null;
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // Running on a platform without the native overlay (tests, Linux).
    }
  }

  static GeometryEvent _parseGeometry(Map<String, Object?> m) {
    double d(Object? v) => (v as num?)?.toDouble() ?? 0;
    final dock = (m['dock'] as List?)?.cast<num>() ?? const [];
    final flat = (m['windows'] as List?)?.cast<num>() ?? const [];
    return GeometryEvent(
      screenWidth: d(m['screenW']),
      screenHeight: d(m['screenH']),
      menuBarHeight: d(m['menuBarH']),
      menuBarThickness: d(m['menuBarThickness']),
      dock: dock.length == 4
          ? Rect.fromLTWH(dock[0].toDouble(), dock[1].toDouble(), dock[2].toDouble(), dock[3].toDouble())
          : null,
      windows: [
        for (var i = 0; i + 4 < flat.length; i += 5)
          DesktopWindow(
            flat[i].toInt(),
            Rect.fromLTWH(flat[i + 1].toDouble(), flat[i + 2].toDouble(),
                flat[i + 3].toDouble(), flat[i + 4].toDouble()),
          ),
      ],
    );
  }

  @override
  Future<void> setHitRegions(List<Rect> regions) {
    final data = Float64List(regions.length * 4);
    for (var i = 0; i < regions.length; i++) {
      final r = regions[i];
      data[i * 4] = r.left;
      data[i * 4 + 1] = r.top;
      data[i * 4 + 2] = r.width;
      data[i * 4 + 3] = r.height;
    }
    return _invoke('setHitRegions', data);
  }

  @override
  Future<void> requestGeometry() => _invoke('requestGeometry');

  @override
  Future<Map<String, Object?>> diagnostics() async {
    try {
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('diagnostics');
      return r?.cast<String, Object?>() ?? const {};
    } on MissingPluginException {
      return const {};
    }
  }

  @override
  Future<void> setClickThrough(bool enabled) => _invoke('setClickThrough', enabled);

  @override
  Future<void> setLevel(OverlayLevel level) => _invoke('setLevel', level.name);

  @override
  Future<void> updateMenuState(OverlayMenuState state) =>
      _invoke('updateMenuState', state.toMap());

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
