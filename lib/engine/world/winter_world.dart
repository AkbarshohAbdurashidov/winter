import 'dart:math' as math;
import 'dart:ui';

import '../../core/fast_random.dart';
import '../../platform/overlay_platform.dart';
import '../snow/snow_layer.dart';
import 'debris.dart';
import 'icicles.dart';
import 'snow_pile.dart';
import 'snowmen.dart';

/// Kind of surface snow can lie on.
enum SurfaceKind { window, dock, floor }

/// A horizontal edge that collects snow. Positions are refreshed every frame
/// (windows are extrapolated between geometry updates).
class Surface {
  Surface(this.key, this.kind, double width, double maxHeight)
      : pile = SnowPile(width, maxHeight: maxHeight);

  final Object key;
  final SurfaceKind kind;
  final SnowPile pile;
  double left = 0, top = 0, width = 0;
  bool present = false;
  double lastSeen = 0;

  /// Windows in front of this one (plus the Dock): snow can't land where
  /// they cover the edge, and rendering is clipped by them.
  List<Rect> occluders = const [];

  double get right => left + width;

  bool visibleAt(double x) {
    if (occluders.isEmpty) return true;
    final p = Offset(x, top - 1);
    for (final r in occluders) {
      if (r.contains(p)) return false;
    }
    return true;
  }

  /// Top of the snow at overlay x (assumes x within the surface).
  double snowTopAt(double x) => top - pile.heightAt(x - left);
}

class _TrackedWindow {
  _TrackedWindow(this.id, this.rect, this.updatedAt);
  final int id;
  Rect rect;
  double updatedAt;
  Offset velocity = Offset.zero;
  double shakeEnergy = 0;
  double shakeCooldown = 0;
}

/// Everything that lives on the desktop besides falling snow: piles on
/// windows / Dock / floor, snowballs and snowmen, icicles, debris.
///
/// Implements [FlakeCollider] so mid-layer flakes land on surfaces.
class WinterWorld implements FlakeCollider {
  WinterWorld({int seed = 1234}) : _rng = FastRandom(seed);

  final FastRandom _rng;
  final DebrisSystem debris = DebrisSystem();
  final IcicleSystem icicles = IcicleSystem();
  final List<SnowBall> balls = [];
  final List<Snowman> snowmen = [];

  final Map<Object, Surface> _surfaces = {};
  final Map<int, _TrackedWindow> _windows = {};
  final List<Surface> active = []; // present surfaces, rebuilt on geometry change

  Size screen = Size.zero;
  Rect? dock;
  double _time = 0;

  /// Snow area (px²) added per landed flake.
  double depositArea = 10;

  SnowBall? _held;
  Offset _lastPointer = Offset.zero;
  Offset _pointerVelocity = Offset.zero;
  double _lastPointerTime = 0;

  static const double _maxWindowSnow = 24, _maxDockSnow = 30, _maxFloorSnow = 36;
  static const double _shakeThreshold = 5.5;

  double get time => _time;
  bool get isHolding => _held != null;

  // ---------------------------------------------------------------- geometry

  void applyGeometry(GeometryEvent g) {
    screen = Size(g.screenWidth, g.screenHeight);
    dock = g.dock;

    final now = _time;
    final seen = <int>{};
    for (final w in g.windows) {
      seen.add(w.id);
      final t = _windows[w.id];
      if (t == null) {
        _windows[w.id] = _TrackedWindow(w.id, w.rect, now);
        continue;
      }
      final dt = math.max(0.016, now - t.updatedAt);
      final v = (w.rect.topLeft - t.rect.topLeft) / dt;
      final sizeChanged = (w.rect.width - t.rect.width).abs() > 1;
      if (!sizeChanged) {
        // Sudden velocity changes (direction reversals) build shake energy.
        final dv = (v - t.velocity).distance;
        if (dv > 400) t.shakeEnergy += dv / 1000;
        t.velocity = v;
      } else {
        t.velocity = Offset.zero;
      }
      t
        ..rect = w.rect
        ..updatedAt = now;
    }
    _windows.removeWhere((id, _) => !seen.contains(id));

    // Rebuild the active surface list.
    for (final s in _surfaces.values) {
      s.present = false;
    }
    active.clear();
    final front = <Rect>[];
    for (final w in g.windows) {
      final s = _surfaces.putIfAbsent(
          w.id, () => Surface(w.id, SurfaceKind.window, w.rect.width, _maxWindowSnow));
      s.pile.resize(w.rect.width);
      s
        ..present = true
        ..lastSeen = now
        ..width = w.rect.width
        ..occluders = [...front, ?dock];
      active.add(s);
      front.add(w.rect);
    }

    final d = dock;
    if (d != null) {
      final s = _surfaces.putIfAbsent('dock', () => Surface('dock', SurfaceKind.dock, d.width, _maxDockSnow));
      s.pile.resize(d.width);
      s
        ..present = true
        ..lastSeen = now
        ..left = d.left
        ..top = d.top
        ..width = d.width
        ..occluders = const [];
      active.add(s);
    }
    _addFloor('floorL', 0, d?.left ?? screen.width, now);
    if (d != null) _addFloor('floorR', d.right, screen.width - d.right, now);

    _surfaces.removeWhere((_, s) => !s.present && now - s.lastSeen > 600);
    _updatePositions(0);
    icicles.layout(
      screenWidth: screen.width,
      screenHeight: screen.height,
      baseY: g.menuBarHeight,
    );
  }

  void _addFloor(String key, double left, double width, double now) {
    if (width < 4) return;
    final s = _surfaces.putIfAbsent(key, () => Surface(key, SurfaceKind.floor, width, _maxFloorSnow));
    if ((s.width - width).abs() > 0.5 || (s.left - left).abs() > 0.5) {
      s.pile.resize(width);
    }
    s
      ..present = true
      ..lastSeen = now
      ..left = left
      ..top = screen.height
      ..width = width
      ..occluders = const [];
    active.add(s);
  }

  /// Extrapolates moving windows so snow doesn't lag behind at 20 Hz polling.
  void _updatePositions(double dt) {
    for (final s in active) {
      if (s.kind != SurfaceKind.window) continue;
      final t = _windows[s.key];
      if (t == null) continue;
      final age = _time - t.updatedAt;
      final ahead = age < 0.12 ? math.min(age, 0.06) : 0.0;
      final r = t.rect.shift(t.velocity * ahead);
      s
        ..left = r.left
        ..top = r.top;
    }
  }

  // ------------------------------------------------------------------ queries

  @override
  bool tryLand(double x, double prevY, double y) {
    for (final s in active) {
      if (x < s.left || x > s.right) continue;
      final top = s.snowTopAt(x);
      if (prevY >= top || y < top) continue;
      if (!s.visibleAt(x)) continue;
      final p = switch (s.kind) {
        SurfaceKind.window => 0.45,
        SurfaceKind.dock => 0.6,
        SurfaceKind.floor => 1.0,
      };
      if (_rng.nextDouble() > p) continue;
      s.pile.deposit(x - s.left, depositArea);
      return true;
    }
    return false;
  }

  /// Snow/dock/floor top under x (used for icicles hitting the Dock).
  double groundAt(double x) {
    for (final s in active) {
      if (s.kind == SurfaceKind.window) continue;
      if (x >= s.left && x <= s.right) return s.snowTopAt(x);
    }
    return screen.height;
  }

  double? _probe(double x, double prevY, double y, int kind) {
    final anySurface = kind == DebrisKind.snowClump || kind == DebrisKind.water;
    double? best;
    for (final s in active) {
      if (!anySurface && s.kind == SurfaceKind.window) continue;
      if (x < s.left || x > s.right) continue;
      final top = s.snowTopAt(x);
      if (prevY > top || y < top) continue;
      if (!s.visibleAt(x)) continue;
      if (best == null || top < best) best = top;
    }
    return best;
  }

  void _snowLanded(double x, double y, double area) {
    for (final s in active) {
      if (x < s.left || x > s.right) continue;
      if ((s.snowTopAt(x) - y).abs() < 2) {
        s.pile.deposit(x - s.left, area);
        return;
      }
    }
  }

  // --------------------------------------------------------------- simulation

  void step(double dt) {
    _time += dt;
    _updatePositions(dt);

    for (final t in _windows.values) {
      t.shakeEnergy *= math.exp(-2.2 * dt);
      if (t.shakeCooldown > 0) t.shakeCooldown -= dt;
      if (t.shakeEnergy > _shakeThreshold && t.shakeCooldown <= 0) {
        t.shakeEnergy = 0;
        t.shakeCooldown = 0.8;
        _shakeOff(t);
      }
    }

    for (final s in active) {
      s.pile.settle();
      _emitSpill(s);
    }

    _stepBalls(dt);
    icicles.step(dt, debris, groundAt);
    debris.step(dt, screen.height, _probe, _snowLanded);
  }

  void _emitSpill(Surface s) {
    final p = s.pile;
    if (p.spillLeft > 8) {
      _spawnClump(s.left - 1, s.top - 2, -_rng.range(10, 40), p.spillLeft);
      p.spillLeft = 0;
    }
    if (p.spillRight > 8) {
      _spawnClump(s.right + 1, s.top - 2, _rng.range(10, 40), p.spillRight);
      p.spillRight = 0;
    }
  }

  void _spawnClump(double x, double y, double vx, double area, {double vy = 0, double grace = 0}) {
    debris.spawn(
      kind: DebrisKind.snowClump,
      x: x,
      y: y,
      vx: vx,
      vy: vy,
      size: math.sqrt(area / 2.2).clamp(1.2, 6.0),
      life: 8,
      vrot: _rng.range(-3, 3),
      grace: grace,
    );
  }

  void _shakeOff(_TrackedWindow t) {
    final s = _surfaces[t.id];
    if (s == null) return;
    final pile = s.pile;
    final v = t.velocity;
    for (var i = 0; i < pile.cellCount; i += 2) {
      final h = pile.heightAtCell(i);
      if (h < 0.4) continue;
      final x = s.left + i * SnowPile.cellWidth;
      final area = h * SnowPile.cellWidth * 2;
      _spawnClump(
        x,
        s.top - h * _rng.nextDouble(),
        v.dx * 0.35 + _rng.range(-70, 70),
        area,
        vy: math.min(0, v.dy * 0.3) - _rng.range(20, 160),
        grace: 0.5,
      );
    }
    pile.clear();
    for (final b in balls) {
      final sup = b.support;
      if (sup is SurfaceSupport && sup.key == t.id) {
        b
          ..state = BallState.falling
          ..support = null
          ..vx = v.dx * 0.25
          ..vy = -60;
      }
    }
  }

  void clearAll() {
    for (final s in _surfaces.values) {
      s.pile.clear();
    }
    balls.clear();
    snowmen.clear();
    debris.clear();
    icicles.falling.clear();
  }

  // -------------------------------------------------------------------- balls

  Surface? _surfaceByKey(Object key) {
    final s = _surfaces[key];
    return (s != null && s.present) ? s : null;
  }

  void _stepBalls(double dt) {
    // Resolve supported positions bottom-up: surface-supported first.
    for (var pass = 0; pass < 3; pass++) {
      for (final b in balls) {
        if (b.state != BallState.resting) continue;
        final sup = b.support;
        if (sup is SurfaceSupport && pass == 0) {
          final s = _surfaceByKey(sup.key);
          b.hidden = s == null;
          if (s != null) {
            b
              ..x = s.left + sup.localX
              ..y = s.top - sup.sink - b.radius * 0.88;
          }
        } else if (sup is BallSupport && pass > 0) {
          final below = sup.ball;
          if (!balls.contains(below) || below.state == BallState.falling) {
            b
              ..state = BallState.falling
              ..support = null;
            continue;
          }
          b
            ..hidden = below.hidden
            ..x = below.x
            ..y = below.stackY(b.radius);
        }
      }
    }

    for (final b in balls) {
      if (b.state != BallState.falling) continue;
      b.vy += DebrisSystem.gravity * dt;
      b.vx -= b.vx * 1.5 * dt;
      final prevY = b.y;
      b.x += b.vx * dt;
      b.angle += b.vx * dt / b.radius;
      final nextY = b.y + b.vy * dt;
      _landBall(b, prevY, nextY);
      if (b.state == BallState.falling) b.y = nextY;
      if (b.y - b.radius > screen.height + 50) b.hidden = true;
    }
    balls.removeWhere((b) => b.state == BallState.falling && b.y - b.radius > screen.height + 50);

    for (final m in snowmen) {
      m.age += dt;
    }
  }

  bool _hasBallOnTop(SnowBall b) {
    for (final o in balls) {
      final s = o.support;
      if (s is BallSupport && identical(s.ball, b)) return true;
    }
    return false;
  }

  void _landBall(SnowBall b, double prevY, double nextY) {
    // Stack on another ball? (A finished snowman doesn't stack.)
    for (final o in b.snowman == null ? balls : const <SnowBall>[]) {
      if (identical(o, b) || o.state != BallState.resting || o.hidden) continue;
      if (o.snowman != null || _hasBallOnTop(o)) continue;
      if ((b.x - o.x).abs() > (o.radius + b.radius) * 0.55) continue;
      final restY = o.stackY(b.radius);
      if (prevY <= restY + 1 && nextY >= restY) {
        b
          ..state = BallState.resting
          ..support = BallSupport(o)
          ..vx = 0
          ..vy = 0
          ..x = o.x
          ..y = restY;
        _checkSnowman(b);
        return;
      }
    }
    // Land on the nearest surface below.
    Surface? best;
    var bestY = double.infinity;
    for (final s in active) {
      if (b.x < s.left || b.x > s.right || !s.visibleAt(b.x)) continue;
      final restY = s.snowTopAt(b.x) - b.radius * 0.88;
      if (prevY <= restY + 1 && nextY >= restY && restY < bestY) {
        best = s;
        bestY = restY;
      }
    }
    if (best != null) {
      final sink = best.top - best.snowTopAt(b.x);
      b
        ..state = BallState.resting
        ..support = SurfaceSupport(best.key, b.x - best.left, sink)
        ..vx = 0
        ..vy = 0
        ..y = bestY;
    }
  }

  void _checkSnowman(SnowBall top) {
    final chain = <SnowBall>[top];
    var cur = top;
    while (true) {
      final s = cur.support;
      if (s is! BallSupport) break;
      cur = s.ball;
      chain.add(cur);
    }
    if (chain.length < 3) return;
    final three = chain.sublist(0, 3).reversed.toList(); // bottom → top
    final man = Snowman(three);
    for (final b in three) {
      b.snowman = man;
    }
    snowmen.add(man);
  }

  // -------------------------------------------------------------- interaction

  /// Returns true when the press hit something interactive.
  bool pointerDown(Offset p) {
    _lastPointer = p;
    _lastPointerTime = _time;
    _pointerVelocity = Offset.zero;

    final ic = icicles.hitTest(p);
    if (ic != null) {
      icicles.breakIcicle(ic);
      return true;
    }

    for (var i = balls.length - 1; i >= 0; i--) {
      final b = balls[i];
      if (b.hidden || !b.contains(p)) continue;
      // Grabbing any part of a snowman moves the whole snowman.
      final target = b.snowman?.base ?? b;
      target
        ..state = BallState.held
        ..support = null;
      _held = target;
      return true;
    }
    for (final m in snowmen) {
      if (!m.base.hidden && m.bounds.contains(p)) {
        _held = m.base
          ..state = BallState.held
          ..support = null;
        return true;
      }
    }

    // Start a new snowball from a pile.
    for (final s in active) {
      if (p.dx < s.left || p.dx > s.right || !s.visibleAt(p.dx)) continue;
      final h = s.pile.heightAt(p.dx - s.left);
      if (h < 2.5) continue;
      if (p.dy < s.top - h - 8 || p.dy > s.top + 4) continue;
      final lx = p.dx - s.left;
      final taken = s.pile.take(lx - 8, lx + 8, 3);
      final r = math.max(SnowBall.minRadius, math.sqrt(taken * 0.8 / math.pi));
      final ball = SnowBall(p.dx, p.dy - r * 0.3, r, _rng.nextUint32());
      balls.add(ball);
      _held = ball;
      return true;
    }
    return false;
  }

  void pointerMove(Offset p) {
    final b = _held;
    final dtp = math.max(1 / 240, _time - _lastPointerTime);
    final delta = p - _lastPointer;
    _pointerVelocity = Offset.lerp(_pointerVelocity, delta / dtp, 0.5)!;
    _lastPointer = p;
    _lastPointerTime = _time;
    if (b == null) return;

    b
      ..x = p.dx
      ..y = p.dy
      ..angle += delta.dx / b.radius;
    if (b.snowman != null) return;

    // Roll through snow: collect from any pile the ball touches.
    final dist = delta.distance;
    if (dist <= 0) return;
    for (final s in active) {
      if (b.x < s.left - b.radius || b.x > s.right + b.radius) continue;
      if (!s.visibleAt(b.x.clamp(s.left, s.right))) continue;
      final lx = b.x - s.left;
      final top = s.top - s.pile.heightAt(lx.clamp(0, s.width));
      final bottom = b.y + b.radius;
      if (bottom < top - 3 || b.y > s.top + b.radius * 0.5) continue;
      final depth = math.min(3.0, 0.4 + dist * 0.08);
      final taken = s.pile.take(lx - b.radius * 0.7, lx + b.radius * 0.7, depth);
      if (taken > 0) b.addArea(taken * 0.85);
    }
  }

  void pointerUp() {
    final b = _held;
    _held = null;
    if (b == null) return;
    final v = _pointerVelocity;
    b
      ..state = BallState.falling
      ..vx = v.dx.clamp(-600, 600) * 0.4
      ..vy = math.min(0, v.dy.clamp(-600, 600) * 0.3);
  }

  // ------------------------------------------------------------- hit regions

  /// Areas where the overlay must take mouse input.
  List<Rect> hitRegions() {
    final out = <Rect>[];
    icicles.collectHitRegions(out);
    for (final b in balls) {
      if (!b.hidden && b.snowman == null) out.add(b.bounds.inflate(2));
    }
    for (final m in snowmen) {
      if (!m.base.hidden) out.add(m.bounds);
    }
    for (final s in active) {
      _pileRuns(s, out);
      if (out.length > 400) break;
    }
    return out;
  }

  void _pileRuns(Surface s, List<Rect> out) {
    final pile = s.pile;
    const cw = SnowPile.cellWidth;
    var start = -1;
    var runMax = 0.0;
    void flush(int end) {
      if (start < 0) return;
      out.add(Rect.fromLTRB(s.left + start * cw, s.top - runMax - 6, s.left + end * cw, s.top + 2));
      start = -1;
      runMax = 0;
    }

    for (var i = 0; i < pile.cellCount; i++) {
      final h = pile.heightAtCell(i);
      final ok = h >= 3 && s.visibleAt(s.left + i * cw);
      if (ok) {
        if (start < 0) start = i;
        if (h > runMax) runMax = h;
      } else {
        flush(i);
      }
    }
    flush(pile.cellCount - 1);
  }
}
