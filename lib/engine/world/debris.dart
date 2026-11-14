import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/fast_random.dart';
import '../render/flake_atlas.dart';

/// Kinds of short-lived physical particles.
abstract final class DebrisKind {
  static const snowClump = 0;
  static const iceShard = 1;
  static const water = 2;
  static const iceDust = 3;
}

/// Something the debris can hit. Returns the surface y at [x] if a particle
/// moving from [prevY] to [y] crosses it, otherwise `null`.
typedef SurfaceProbe = double? Function(double x, double prevY, double y, int kind);

/// Called when a snow clump lands so its snow can be added to a pile.
typedef SnowLanded = void Function(double x, double y, double area);

/// Pooled particles with gravity, bounce and fade (snow clumps, ice shards,
/// water drops, ice dust). Rendered with one `drawRawAtlas` call.
class DebrisSystem {
  DebrisSystem({this.capacity = 1500, int seed = 99}) : _rng = FastRandom(seed) {
    _x = Float32List(capacity);
    _y = Float32List(capacity);
    _vx = Float32List(capacity);
    _vy = Float32List(capacity);
    _rot = Float32List(capacity);
    _vrot = Float32List(capacity);
    _size = Float32List(capacity);
    _life = Float32List(capacity);
    _maxLife = Float32List(capacity);
    _grace = Float32List(capacity);
    _kind = Uint8List(capacity);
    _bounces = Uint8List(capacity);
    _resting = Uint8List(capacity);
    _transforms = Float32List(capacity * 4);
    _rects = Float32List(capacity * 4);
    _colors = Int32List(capacity);
  }

  final int capacity;
  final FastRandom _rng;
  static const double gravity = 1500;

  late final Float32List _x, _y, _vx, _vy, _rot, _vrot, _size, _life, _maxLife, _grace;
  late final Uint8List _kind, _bounces, _resting;
  late final Float32List _transforms, _rects;
  late final Int32List _colors;
  int _count = 0;

  int get count => _count;
  FastRandom get rng => _rng;

  int _viewCount = -1;
  late Float32List _tView, _rView;
  late Int32List _cView;

  Float32List get transformsView {
    _ensure();
    return _tView;
  }

  Float32List get rectsView {
    _ensure();
    return _rView;
  }

  Int32List get colorsView {
    _ensure();
    return _cView;
  }

  void _ensure() {
    if (_viewCount == _count) return;
    _viewCount = _count;
    _tView = Float32List.sublistView(_transforms, 0, _count * 4);
    _rView = Float32List.sublistView(_rects, 0, _count * 4);
    _cView = Int32List.sublistView(_colors, 0, _count);
  }

  void clear() => _count = 0;

  /// Spawns a particle; silently dropped when the pool is full.
  void spawn({
    required int kind,
    required double x,
    required double y,
    double vx = 0,
    double vy = 0,
    required double size,
    double life = 4,
    double vrot = 0,

    /// Seconds before the particle may collide (snow thrown off a window
    /// must not land straight back on it).
    double grace = 0,
  }) {
    if (_count >= capacity) return;
    final i = _count++;
    _x[i] = x;
    _y[i] = y;
    _vx[i] = vx;
    _vy[i] = vy;
    _rot[i] = _rng.range(0, math.pi * 2);
    _vrot[i] = vrot;
    _size[i] = size;
    _life[i] = life;
    _maxLife[i] = life;
    _grace[i] = grace;
    _kind[i] = kind;
    _bounces[i] = 0;
    _resting[i] = 0;
    final cell = switch (kind) {
      DebrisKind.iceShard => 2,
      DebrisKind.water => 3,
      _ => 0,
    };
    final j = i * 4;
    _rects[j] = cell * FlakeAtlas.cellSize;
    _rects[j + 1] = 0;
    _rects[j + 2] = (cell + 1) * FlakeAtlas.cellSize;
    _rects[j + 3] = FlakeAtlas.cellSize;
  }

  void _remove(int i) {
    final last = --_count;
    if (i == last) return;
    _x[i] = _x[last];
    _y[i] = _y[last];
    _vx[i] = _vx[last];
    _vy[i] = _vy[last];
    _rot[i] = _rot[last];
    _vrot[i] = _vrot[last];
    _size[i] = _size[last];
    _life[i] = _life[last];
    _maxLife[i] = _maxLife[last];
    _grace[i] = _grace[last];
    _kind[i] = _kind[last];
    _bounces[i] = _bounces[last];
    _resting[i] = _resting[last];
    for (var k = 0; k < 4; k++) {
      _transforms[i * 4 + k] = _transforms[last * 4 + k];
      _rects[i * 4 + k] = _rects[last * 4 + k];
    }
    _colors[i] = _colors[last];
  }

  void step(double dt, double screenHeight, SurfaceProbe probe, SnowLanded onSnowLanded) {
    const half = FlakeAtlas.cellSize / 2;
    for (var i = _count - 1; i >= 0; i--) {
      final kind = _kind[i];
      var life = _life[i] - dt;
      if (life <= 0 || _y[i] > screenHeight + 40) {
        _remove(i);
        continue;
      }
      _life[i] = life;

      if (_resting[i] == 0) {
        final drag = kind == DebrisKind.iceDust ? 2.5 : 0.3;
        _vx[i] -= _vx[i] * drag * dt;
        _vy[i] += (kind == DebrisKind.iceDust ? gravity * 0.25 : gravity) * dt;
        final prevY = _y[i];
        final x = _x[i] + _vx[i] * dt;
        var y = prevY + _vy[i] * dt;
        _rot[i] += _vrot[i] * dt;

        if (_grace[i] > 0) _grace[i] -= dt;
        if (_vy[i] > 0 && _grace[i] <= 0) {
          final hit = probe(x, prevY, y, kind);
          if (hit != null) {
            switch (kind) {
              case DebrisKind.snowClump:
                onSnowLanded(x, hit, _size[i] * _size[i] * 2.2);
                _remove(i);
                continue;
              case DebrisKind.water:
                _splash(x, hit);
                _remove(i);
                continue;
              case DebrisKind.iceDust:
                _remove(i);
                continue;
              default: // ice shard: bounce, then come to rest
                y = hit;
                if (_bounces[i] < 2 && _vy[i] > 120) {
                  _bounces[i]++;
                  _vy[i] = -_vy[i] * 0.32;
                  _vx[i] *= 0.6;
                  _vrot[i] *= 0.5;
                } else {
                  _resting[i] = 1;
                  _vx[i] = 0;
                  _vy[i] = 0;
                  _vrot[i] = 0;
                  _life[i] = math.min(life, _rng.range(1.2, 2.5));
                }
            }
          }
        }
        _x[i] = x;
        _y[i] = y;
      }

      // Render buffers.
      final t = _life[i] / _maxLife[i];
      final fade = t < 0.3 ? t / 0.3 : 1.0;
      final base = switch (kind) {
        DebrisKind.snowClump => 0.95,
        DebrisKind.iceShard => 0.9,
        DebrisKind.water => 0.8,
        _ => 0.6,
      };
      final rgb = switch (kind) {
        DebrisKind.snowClump => 0xF4F8FF,
        DebrisKind.iceShard => 0xFFFFFF,
        DebrisKind.water => 0xFFFFFF,
        _ => 0xE2F1FF,
      };
      _colors[i] = (((base * fade * 255).round() & 0xFF) << 24 | rgb).toSigned(32);

      final size = _size[i];
      final scale = size / half;
      // Water drops stretch along their velocity while falling.
      final rot = kind == DebrisKind.water ? 0.0 : _rot[i];
      final c = math.cos(rot) * scale, s = math.sin(rot) * scale;
      final j = i * 4;
      _transforms[j] = c;
      _transforms[j + 1] = s;
      _transforms[j + 2] = _x[i] - c * half + s * half;
      _transforms[j + 3] = _y[i] - s * half - c * half;
    }
  }

  void _splash(double x, double y) {
    final n = 2 + (_rng.nextDouble() * 3).floor();
    for (var k = 0; k < n; k++) {
      spawn(
        kind: DebrisKind.iceDust,
        x: x,
        y: y - 1,
        vx: _rng.range(-60, 60),
        vy: _rng.range(-110, -40),
        size: _rng.range(0.8, 1.6),
        life: 0.5,
      );
    }
  }
}
