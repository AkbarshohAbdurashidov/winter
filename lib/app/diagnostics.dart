import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../features/overlay/overlay_controller.dart';
import '../platform/overlay_platform.dart';

/// Writes a JSON snapshot of the running overlay every few seconds when the
/// app is started with `--diagnostics <file>`. Used by the CI smoke test to
/// verify the Windows build on a machine nobody can look at.
class DiagnosticsWriter {
  DiagnosticsWriter(this.path, this.controller, this.platform);

  final String path;
  final OverlayController controller;
  final OverlayPlatform platform;
  Timer? _timer;
  int _geometryEvents = 0;
  GeometryEvent? _lastGeometry;
  StreamSubscription<OverlayEvent>? _sub;

  static String? pathFromArgs(List<String> args) {
    final i = args.indexOf('--diagnostics');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
  }

  void start() {
    _sub = platform.events.listen((e) {
      if (e is GeometryEvent) {
        _geometryEvents++;
        _lastGeometry = e;
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _write());
  }

  Future<void> _write() async {
    final s = controller.stats.snapshot.value;
    final w = controller.world;
    final g = _lastGeometry;
    final data = {
      'time': DateTime.now().toIso8601String(),
      'animating': controller.isAnimating,
      'fps': s.fps,
      'uiMs': s.buildMs,
      'rasterMs': s.rasterMs,
      'flakes': controller.system.liveFlakes,
      'viewport': [controller.system.size.width, controller.system.size.height],
      'geometryEvents': _geometryEvents,
      'screen': g == null ? null : [g.screenWidth, g.screenHeight],
      'menuBarHeight': g?.menuBarHeight,
      'dock': g?.dock == null ? null : [g!.dock!.left, g.dock!.top, g.dock!.width, g.dock!.height],
      'windows': g?.windows.length,
      'surfaces': w.active.length,
      'snowVolume': w.active.fold<double>(0, (a, s) => a + s.pile.totalVolume),
      'icicles': w.icicles.icicles.length,
      'debris': w.debris.count,
      'native': await platform.diagnostics(),
    };
    try {
      await File(path).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    } on FileSystemException {
      // Diagnostics must never take the app down.
    }
  }

  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
  }
}
