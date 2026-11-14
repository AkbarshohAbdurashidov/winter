import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Immutable snapshot published about once per second.
@immutable
class FrameStatsSnapshot {
  const FrameStatsSnapshot({
    required this.fps,
    required this.frameIntervalMs,
    required this.worstIntervalMs,
    required this.buildMs,
    required this.rasterMs,
    required this.worstRasterMs,
  });

  static const empty = FrameStatsSnapshot(
    fps: 0,
    frameIntervalMs: 0,
    worstIntervalMs: 0,
    buildMs: 0,
    rasterMs: 0,
    worstRasterMs: 0,
  );

  /// Frames actually produced per second (after the FPS cap).
  final double fps;
  final double frameIntervalMs;
  final double worstIntervalMs;

  /// Engine-reported UI-thread (build/paint) and raster-thread times.
  final double buildMs;
  final double rasterMs;
  final double worstRasterMs;
}

/// Collects frame intervals and engine [FrameTiming]s into fixed ring buffers.
class FrameStats {
  FrameStats({this.window = 120});

  final int window;
  late final Float64List _intervals = Float64List(window);
  late final Float64List _build = Float64List(window);
  late final Float64List _raster = Float64List(window);
  int _intervalN = 0, _intervalI = 0;
  int _timingN = 0, _timingI = 0;
  int _framesSincePublish = 0;
  final Stopwatch _publishClock = Stopwatch();

  final ValueNotifier<FrameStatsSnapshot> snapshot =
      ValueNotifier(FrameStatsSnapshot.empty);

  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _publishClock.start();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  /// Call once per produced frame with the real interval since the last one.
  void recordInterval(Duration interval) {
    _intervals[_intervalI] = interval.inMicroseconds / 1000.0;
    _intervalI = (_intervalI + 1) % window;
    if (_intervalN < window) _intervalN++;
    _framesSincePublish++;
    if (_publishClock.elapsedMilliseconds >= 1000) _publish();
  }

  /// Resets FPS accounting (e.g. after a pause) so idle time isn't counted.
  void resetClock() {
    _framesSincePublish = 0;
    _publishClock
      ..reset()
      ..start();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _build[_timingI] = t.buildDuration.inMicroseconds / 1000.0;
      _raster[_timingI] = t.rasterDuration.inMicroseconds / 1000.0;
      _timingI = (_timingI + 1) % window;
      if (_timingN < window) _timingN++;
    }
  }

  void _publish() {
    final seconds = _publishClock.elapsedMicroseconds / 1e6;
    final fps = seconds > 0 ? _framesSincePublish / seconds : 0.0;
    resetClock();

    double avg(Float64List b, int n) {
      if (n == 0) return 0;
      var s = 0.0;
      for (var i = 0; i < n; i++) {
        s += b[i];
      }
      return s / n;
    }

    double worst(Float64List b, int n) {
      var m = 0.0;
      for (var i = 0; i < n; i++) {
        if (b[i] > m) m = b[i];
      }
      return m;
    }

    snapshot.value = FrameStatsSnapshot(
      fps: fps,
      frameIntervalMs: avg(_intervals, _intervalN),
      worstIntervalMs: worst(_intervals, _intervalN),
      buildMs: avg(_build, _timingN),
      rasterMs: avg(_raster, _timingN),
      worstRasterMs: worst(_raster, _timingN),
    );
  }

  void dispose() {
    detach();
    snapshot.dispose();
  }
}
