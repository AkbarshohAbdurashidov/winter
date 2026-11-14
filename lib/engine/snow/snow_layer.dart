import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/fast_random.dart';
import '../render/flake_atlas.dart';
import '../weather/wind_field.dart';
import 'layer_spec.dart';

/// Something falling flakes can land on. Returns true if the flake moving
/// from [prevY] to [y] at [x] was absorbed (it is then respawned at the top).
abstract interface class FlakeCollider {
  bool tryLand(double x, double prevY, double y);
}

/// One depth layer of falling snow, stored as struct-of-arrays.
///
/// All buffers are allocated once at [capacity]. Live particles are always
/// packed in `[0, count)`; removal is swap-with-last. The render buffers
/// (`transforms`, `rects`, `colors`) are written during [step] so drawing is a
/// single `drawRawAtlas` call with no per-frame allocation.
class SnowLayer {
  SnowLayer(this.spec, this.capacity, FastRandom rng)
      : _rng = rng,
        _x = Float32List(capacity),
        _y = Float32List(capacity),
        _vx = Float32List(capacity),
        _vy = Float32List(capacity),
        _radius = Float32List(capacity),
        _terminal = Float32List(capacity),
        _phase = Float32List(capacity),
        _phaseFreq = Float32List(capacity),
        _sway = Float32List(capacity),
        _transforms = Float32List(capacity * 4),
        _rects = Float32List(capacity * 4),
        _colors = Int32List(capacity);

  final LayerSpec spec;
  final int capacity;
  final FastRandom _rng;

  final Float32List _x, _y, _vx, _vy, _radius, _terminal;
  final Float32List _phase, _phaseFreq, _sway;
  final Float32List _transforms, _rects;
  final Int32List _colors;

  int _count = 0;
  int _target = 0;

  /// Set for the layer that interacts with windows (mid layer only).
  FlakeCollider? collider;
  bool useSoftSprite = false;

  int get count => _count;
  int get target => _target;

  // Cached exact-length views for drawRawAtlas; rebuilt only when count changes.
  int _viewCount = -1;
  late Float32List _transformsView, _rectsView;
  late Int32List _colorsView;

  Float32List get transformsView {
    _ensureViews();
    return _transformsView;
  }

  Float32List get rectsView {
    _ensureViews();
    return _rectsView;
  }

  Int32List get colorsView {
    _ensureViews();
    return _colorsView;
  }

  void _ensureViews() {
    if (_viewCount == _count) return;
    _viewCount = _count;
    _transformsView = Float32List.sublistView(_transforms, 0, _count * 4);
    _rectsView = Float32List.sublistView(_rects, 0, _count * 4);
    _colorsView = Int32List.sublistView(_colors, 0, _count);
  }

  /// Sets the desired particle count.
  ///
  /// Growth spawns flakes immediately ([fillScreen] scatters them over the
  /// whole screen, otherwise just above it so they drift in). Shrinking is
  /// graceful: surplus flakes are retired as they leave the screen.
  void setTarget(int target, double width, double height,
      {bool fillScreen = false}) {
    _target = target.clamp(0, capacity);
    while (_count < _target) {
      _spawn(_count, width, height,
          yMin: fillScreen ? -20 : -height * 0.35, yMax: fillScreen ? height : -10);
      _count++;
    }
  }

  /// Immediately drops all particles (used when a layer is disabled).
  void clear() {
    _count = 0;
    _target = 0;
  }

  void _spawn(int i, double width, double height,
      {required double yMin, required double yMax}) {
    final s = spec;
    final r = _rng;
    // Bias sizes towards small flakes (squared distribution).
    final sizeT = r.nextDouble() * r.nextDouble();
    final radius = s.radiusMin + (s.radiusMax - s.radiusMin) * sizeT;
    _radius[i] = radius;
    _x[i] = r.range(-20, width + 20);
    _y[i] = r.range(yMin, yMax);
    // Bigger flakes in a layer fall a little faster.
    final terminal = s.fallMin + (s.fallMax - s.fallMin) * (0.6 * sizeT + 0.4 * r.nextDouble());
    _terminal[i] = terminal;
    _vx[i] = 0;
    _vy[i] = terminal;
    _phase[i] = r.range(0, math.pi * 2);
    _phaseFreq[i] = r.range(0.6, 2.2);
    _sway[i] = r.range(s.swayMin, s.swayMax);

    final alpha = r.range(s.alphaMin, s.alphaMax);
    // Slightly cool moonlit white.
    _colors[i] = (((alpha * 255).round() & 0xFF) << 24 | 0xEEF4FF).toSigned(32);

    final cell = (useSoftSprite && s.softSprite) ? 1 : 0;
    final j = i * 4;
    _rects[j] = cell * FlakeAtlas.cellSize;
    _rects[j + 1] = 0;
    _rects[j + 2] = (cell + 1) * FlakeAtlas.cellSize;
    _rects[j + 3] = FlakeAtlas.cellSize;
  }

  void _copy(int from, int to) {
    _x[to] = _x[from];
    _y[to] = _y[from];
    _vx[to] = _vx[from];
    _vy[to] = _vy[from];
    _radius[to] = _radius[from];
    _terminal[to] = _terminal[from];
    _phase[to] = _phase[from];
    _phaseFreq[to] = _phaseFreq[from];
    _sway[to] = _sway[from];
    _colors[to] = _colors[from];
    final a = from * 4, b = to * 4;
    for (var k = 0; k < 4; k++) {
      _transforms[b + k] = _transforms[a + k];
      _rects[b + k] = _rects[a + k];
    }
  }

  /// Advances the layer by [dt] seconds and writes render buffers.
  void step(double dt, WindField wind, double width, double height,
      double fallScale) {
    final s = spec;
    final blend = math.min(1.0, dt * s.responsiveness);
    final fallBlend = math.min(1.0, dt * 3.0);
    const half = FlakeAtlas.cellSize / 2;
    final wrapMin = -40.0, wrapMax = width + 40.0;
    final wrapSpan = wrapMax - wrapMin;

    // Iterate backwards so swap-remove pulls an already-processed particle.
    for (var i = _count - 1; i >= 0; i--) {
      var y = _y[i];
      final radius = _radius[i];

      if (y - radius > height + 10) {
        if (_count > _target) {
          final last = _count - 1;
          if (i != last) _copy(last, i);
          _count = last;
          continue;
        }
        _respawnTop(i, width);
        y = _y[i];
      }

      var phase = _phase[i] + _phaseFreq[i] * dt;
      if (phase > 6.283185307179586) phase -= 6.283185307179586;
      _phase[i] = phase;

      final targetVx = wind.sample(y, s.depth) * s.windFactor + math.sin(phase) * _sway[i];
      final vx = _vx[i] + (targetVx - _vx[i]) * blend;
      final vy = _vy[i] + (_terminal[i] * fallScale - _vy[i]) * fallBlend;
      _vx[i] = vx;
      _vy[i] = vy;

      var x = _x[i] + vx * dt;
      if (x < wrapMin) {
        x += wrapSpan;
      } else if (x > wrapMax) {
        x -= wrapSpan;
      }
      final prevY = y;
      y += vy * dt;
      if (collider != null && collider!.tryLand(x, prevY, y)) {
        _respawnTop(i, width);
        x = _x[i];
        y = _y[i];
      }
      _x[i] = x;
      _y[i] = y;

      final scale = radius / half;
      final j = i * 4;
      _transforms[j] = scale;
      _transforms[j + 1] = 0;
      _transforms[j + 2] = x - radius;
      _transforms[j + 3] = y - radius;
    }
  }

  void _respawnTop(int i, double width) {
    _x[i] = _rng.range(-40, width + 40);
    _y[i] = -_radius[i] - _rng.range(0, 60);
    _vy[i] = _terminal[i];
  }

  /// Rescales positions after the drawable area changed.
  void resize(double oldW, double oldH, double newW, double newH) {
    if (oldW <= 0 || oldH <= 0) return;
    final sx = newW / oldW, sy = newH / oldH;
    for (var i = 0; i < _count; i++) {
      _x[i] *= sx;
      _y[i] *= sy;
    }
  }

  // Test hooks (read-only).
  double xAt(int i) => _x[i];
  double yAt(int i) => _y[i];
}
