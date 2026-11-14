import 'dart:math' as math;
import 'dart:ui';

import '../../core/fast_random.dart';
import 'debris.dart';

/// One icicle hanging from the menu bar (or the top screen edge).
class Icicle {
  Icicle({
    required this.x,
    required this.maxLength,
    required this.growthTime,
    required this.seed,
    required this.length,
    required this.dripTimer,
  });

  final double x;
  double maxLength;

  /// Seconds to grow from nothing to [maxLength].
  final double growthTime;
  final int seed;
  double length;
  double dripTimer;

  /// 0 = no drop forming, (0,1] = drop swelling at the tip.
  double dropPhase = 0;

  final Path path = Path();
  double _pathLength = -1;

  double get width => (3.2 + math.sqrt(length) * 1.55).clamp(3.5, 24.0);

  Rect get bounds => Rect.fromLTWH(x - width / 2, 0, width, length);
}

/// An icicle that broke off and is falling.
class FallingIcicle {
  FallingIcicle(this.x, this.y, this.length, this.width, this.path, this.spin);
  double x, y, length, width;
  double vy = 0, angle = 0;
  final double spin;
  final Path path;
}

/// Icicles along the bottom edge of the menu bar: they grow slowly, drip
/// water, break when clicked and shatter on the Dock/floor.
class IcicleSystem {
  IcicleSystem({int seed = 4242}) : _rng = FastRandom(seed);

  final FastRandom _rng;
  final List<Icicle> icicles = [];
  final List<FallingIcicle> falling = [];
  final Path ledge = Path();

  double _baseY = -1, _screenW = 0, _screenH = 0;
  double get baseY => _baseY;
  double get screenWidth => _screenW;

  /// Incremented each time an icicle breaks (renderers re-bake their cache).
  int breaks = 0;
  int ledgeVersion = 0;

  /// (Re)builds the row when the screen width or menu bar edge changes.
  void layout({required double screenWidth, required double screenHeight, required double baseY}) {
    if (screenWidth == _screenW && baseY == _baseY && screenHeight == _screenH) return;
    final keep = screenWidth == _screenW && screenHeight == _screenH;
    _screenW = screenWidth;
    _screenH = screenHeight;
    _baseY = baseY;
    if (!keep) _createRow();
    _buildLedge();
  }

  void _createRow() {
    icicles.clear();
    // Longest icicles stop a little above the middle of the screen.
    final maxAllowed = math.max(40.0, _screenH * 0.45 - _baseY);
    var x = _rng.range(6, 20);
    while (x < _screenW - 6) {
      final r = _rng.nextDouble();
      final maxLen = r < 0.62
          ? _rng.range(10, 55)
          : r < 0.9
              ? _rng.range(55, 150)
              : _rng.range(150, maxAllowed);
      icicles.add(Icicle(
        x: x,
        maxLength: math.min(maxLen, maxAllowed),
        // Long ones take longer; everything keeps growing for 5–25 minutes.
        growthTime: _rng.range(300, 900) * (0.6 + maxLen / maxAllowed),
        seed: _rng.nextUint32(),
        // Start partly grown so the menu bar looks frozen right away.
        length: math.min(maxLen, maxAllowed) * _rng.range(0.15, 0.35),
        dripTimer: _rng.range(2, 14),
      ));
      // Irregular spacing with occasional gaps and tight clusters.
      final gap = _rng.nextDouble();
      x += gap < 0.15 ? _rng.range(6, 12) : gap < 0.9 ? _rng.range(16, 46) : _rng.range(60, 140);
    }
  }

  void _buildLedge() {
    ledge.reset();
    ledge.moveTo(0, 0);
    final rng = FastRandom(7);
    for (var x = 0.0; x <= _screenW; x += 6) {
      ledge.lineTo(x, 2.5 + rng.range(0, 3.5));
    }
    ledge
      ..lineTo(_screenW, 0)
      ..close();
    ledgeVersion++;
  }

  Icicle? hitTest(Offset p) {
    final local = Offset(p.dx, p.dy - _baseY);
    for (final ic in icicles) {
      if (ic.length < 6) continue;
      final b = ic.bounds.inflate(4);
      if (b.contains(local)) return ic;
    }
    return null;
  }

  /// Rects (overlay coordinates) where clicks should break icicles.
  void collectHitRegions(List<Rect> out) {
    for (final ic in icicles) {
      if (ic.length < 6) continue;
      out.add(ic.bounds.inflate(4).shift(Offset(0, _baseY)));
    }
  }

  void breakIcicle(Icicle ic) {
    final keep = ic.length * _rng.range(0.08, 0.25);
    // Detach the lower part as a falling piece, with its own copy of the shape.
    final piece = Path();
    _buildIcicle(piece, ic, ic.length, offsetTop: keep);
    falling.add(FallingIcicle(
      ic.x,
      _baseY + keep,
      ic.length - keep,
      ic.width,
      piece,
      _rng.range(-0.35, 0.35),
    ));
    ic
      ..length = keep
      ..dropPhase = 0;
    breaks++;
  }

  /// [groundAt] returns the y of the Dock (or floor) top at x.
  void step(double dt, DebrisSystem debris, double Function(double x) groundAt) {
    for (final ic in icicles) {
      if (ic.length < ic.maxLength) {
        final rate = ic.maxLength / ic.growthTime;
        // Growth slows as the icicle approaches its final length.
        final slow = 1 - 0.7 * (ic.length / ic.maxLength);
        ic.length = math.min(ic.maxLength, ic.length + rate * slow * dt);
      }
      if (ic.length < 8) continue;

      if (ic.dropPhase > 0) {
        ic.dropPhase += dt / 1.4;
        if (ic.dropPhase >= 1) {
          ic.dropPhase = 0;
          debris.spawn(
            kind: DebrisKind.water,
            x: ic.x,
            y: _baseY + ic.length + 2,
            vy: 30,
            size: 2.2,
            life: 6,
          );
          ic.dripTimer = _rng.range(3, 16);
        }
      } else {
        ic.dripTimer -= dt;
        if (ic.dripTimer <= 0) ic.dropPhase = 0.001;
      }
    }

    for (var i = falling.length - 1; i >= 0; i--) {
      final f = falling[i];
      f.vy += DebrisSystem.gravity * dt;
      f.y += f.vy * dt;
      f.angle += f.spin * dt;
      final tipX = f.x - math.sin(f.angle) * f.length;
      final tipY = f.y + math.cos(f.angle) * f.length;
      final ground = groundAt(tipX);
      if (tipY >= ground) {
        _shatter(f, debris, ground);
        falling.removeAt(i);
      }
    }
  }

  void _shatter(FallingIcicle f, DebrisSystem debris, double groundY) {
    final shards = (8 + f.length / 5).clamp(8, 60).round();
    final impact = f.vy;
    for (var k = 0; k < shards; k++) {
      final along = _rng.nextDouble();
      final x = f.x - math.sin(f.angle) * f.length * along;
      final y = math.min(groundY - 1, f.y + math.cos(f.angle) * f.length * along);
      final size = f.width * _rng.range(0.25, 0.75) * (1 - along * 0.5);
      debris.spawn(
        kind: DebrisKind.iceShard,
        x: x,
        y: y,
        vx: _rng.range(-1, 1) * _rng.range(60, 320),
        vy: -_rng.range(0.15, 0.45) * impact * (0.4 + along),
        size: size.clamp(1.5, 12.0),
        life: _rng.range(2.5, 4.5),
        vrot: _rng.range(-14, 14),
      );
    }
    for (var k = 0; k < shards * 2; k++) {
      debris.spawn(
        kind: DebrisKind.iceDust,
        x: f.x + _rng.range(-8, 8),
        y: groundY - 2,
        vx: _rng.range(-220, 220),
        vy: -_rng.range(80, 420),
        size: _rng.range(0.8, 2.2),
        life: _rng.range(0.5, 1.2),
      );
    }
  }

  /// Path in icicle-local coordinates: base centre at (0, 0), pointing down.
  /// [offsetTop] cuts the top part off (for broken pieces).
  void _buildIcicle(Path path, Icicle ic, double length, {double offsetTop = 0}) {
    path.reset();
    final rng = FastRandom(ic.seed);
    final w = ic.width / 2;
    const segments = 7;
    final left = <Offset>[];
    final right = <Offset>[];
    for (var s = 0; s <= segments; s++) {
      final t = s / segments;
      final y = length * t;
      // Taper with a slight bulge and irregular ripples.
      final taper = math.pow(1 - t, 0.85).toDouble();
      final ripple = 1 + (rng.nextDouble() - 0.5) * 0.28;
      final half = math.max(0.35, w * taper * ripple);
      final lean = math.sin(t * 2.2 + ic.seed % 7) * 0.6;
      left.add(Offset(-half + lean, y));
      right.add(Offset(half + lean, y));
    }
    final tip = Offset(left.last.dx * 0.5 + right.last.dx * 0.5, length + 1.5);
    path.moveTo(left.first.dx, left.first.dy - offsetTop);
    for (var s = 1; s < left.length; s++) {
      final a = left[s - 1], b = left[s];
      path.quadraticBezierTo(a.dx, a.dy - offsetTop, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - offsetTop);
    }
    path.lineTo(tip.dx, tip.dy - offsetTop);
    for (var s = right.length - 1; s > 0; s--) {
      final a = right[s], b = right[s - 1];
      path.quadraticBezierTo(a.dx, a.dy - offsetTop, (a.dx + b.dx) / 2, (a.dy + b.dy) / 2 - offsetTop);
    }
    path.lineTo(right.first.dx, right.first.dy - offsetTop);
    path.close();
  }

  /// Returns the icicle's cached shape, rebuilding it when it has grown.
  Path pathFor(Icicle ic) {
    if ((ic.length - ic._pathLength).abs() > 0.4) {
      _buildIcicle(ic.path, ic, ic.length);
      ic._pathLength = ic.length;
    }
    return ic.path;
  }
}
