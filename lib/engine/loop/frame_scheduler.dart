import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Drives simulation + repaint at a capped frame rate.
///
/// Frames are requested every vsync while running and simulation/repaint is
/// skipped until the cap interval has elapsed. While stopped, no frames are
/// requested at all, so the engine goes idle.
///
/// Measured on macOS (2026-11-14): sleeping between frames with a Timer cost
/// ~2x more CPU than staying on vsync, because the engine tears down and
/// restarts its display link for each frame.
class FrameScheduler {
  FrameScheduler({
    required this.onStep,
    this.onFrameRendered,
    this._targetFps = 60,
  });

  /// Simulation callback; `dt` is in seconds and clamped to avoid big jumps.
  final void Function(double dt) onStep;

  /// Called after each produced frame with the real interval since the last.
  final void Function(Duration interval)? onFrameRendered;

  /// Listeners repaint when this fires.
  final ChangeNotifier repaint = _RepaintNotifier();

  static const double maxStep = 1 / 15;

  /// Frames arriving this early (µs) are still accepted, absorbing vsync jitter.
  static const int _toleranceUs = 2000;

  int _targetFps;
  bool _running = false;
  bool _callbackPending = false;
  Duration? _lastFrame;

  bool get isRunning => _running;
  int get targetFps => _targetFps;
  set targetFps(int fps) => _targetFps = math.max(1, fps);

  void start() {
    if (_running) return;
    _running = true;
    _lastFrame = null;
    _request();
  }

  void stop() {
    _running = false;
    _lastFrame = null;
  }

  void dispose() {
    stop();
    repaint.dispose();
  }

  void _request() {
    if (!_running || _callbackPending) return;
    _callbackPending = true;
    SchedulerBinding.instance.scheduleFrameCallback(_onFrame);
  }

  void _onFrame(Duration timeStamp) {
    _callbackPending = false;
    if (!_running) return;

    final last = _lastFrame;
    if (last != null) {
      final interval = timeStamp - last;
      if (interval.inMicroseconds < 1e6 / _targetFps - _toleranceUs) {
        _request(); // not due yet: skip work, keep the display link warm
        return;
      }
      final dt = math.min(interval.inMicroseconds / 1e6, maxStep);
      if (dt > 0) onStep(dt);
      onFrameRendered?.call(interval);
    }
    _lastFrame = timeStamp;
    (repaint as _RepaintNotifier).fire();
    _request();
  }
}

class _RepaintNotifier extends ChangeNotifier {
  void fire() => notifyListeners();
}
