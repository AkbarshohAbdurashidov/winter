import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../world/icicles.dart';
import '../world/snowmen.dart';
import '../world/winter_world.dart';

/// Draws piles, snowballs, snowmen, icicles and debris.
///
/// Paths are cached per object and rebuilt only when the shape changed
/// (piles at most ~12 times per second), so steady-state painting allocates
/// almost nothing.
class WorldRenderer {
  WorldRenderer(this.atlas, this.devicePixelRatio);

  final ui.Image atlas;
  final double devicePixelRatio;

  // Icicle row baked into an image; redrawn only when shapes change.
  ui.Image? _icicleImage;
  double _icicleImageHeight = 0;
  final List<double> _bakedLengths = [];
  int _bakedLedgeVersion = -1;
  int _bakedFalling = 0;
  double _icicleBakedAt = -10;
  final Paint _imagePaint = Paint()..filterQuality = FilterQuality.medium;

  void dispose() {
    _icicleImage?.dispose();
    for (final c in _piles.values) {
      c.image?.dispose();
    }
  }

  /// Records [draw] (logical coords, [bounds]) into a GPU image at device resolution.
  ui.Image _bake(Rect bounds, void Function(Canvas c) draw) {
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    c.scale(devicePixelRatio);
    c.translate(-bounds.left, -bounds.top);
    draw(c);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      math.max(1, (bounds.width * devicePixelRatio).ceil()),
      math.max(1, (bounds.height * devicePixelRatio).ceil()),
    );
    picture.dispose();
    return image;
  }

  void _drawBaked(Canvas canvas, ui.Image image, Offset topLeft) {
    final w = image.width / devicePixelRatio, h = image.height / devicePixelRatio;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(topLeft.dx, topLeft.dy, w, h),
      _imagePaint,
    );
  }

  final Map<Object, _PileCache> _piles = {};

  final Paint _pileFill = Paint()
    ..shader = ui.Gradient.linear(
      const Offset(0, -36),
      Offset.zero,
      const [Color(0xFFFFFFFF), Color(0xFFF1F6FD), Color(0xFFCFDCEE)],
      const [0.0, 0.55, 1.0],
    );
  final Paint _pileEdge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.9
    ..color = const Color(0x8C8AA2C2);
  final Paint _pileShadow = Paint()..color = const Color(0x22102040);

  final Paint _iceFill = Paint()
    ..shader = ui.Gradient.linear(
      Offset.zero,
      const Offset(0, 220),
      const [Color(0xF2F2FAFF), Color(0xB3CBE7FA), Color(0x80A5D2F2)],
      const [0.0, 0.4, 1.0],
    );
  final Paint _iceEdge = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..color = const Color(0x997AA9CF);
  final Paint _iceHighlight = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..color = const Color(0xCCFFFFFF);
  final Paint _drop = Paint()..color = const Color(0xCCBFE0FA);

  final Paint _atlasPaint = Paint()..filterQuality = FilterQuality.low;
  final Paint _fill = Paint();
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;

  void paint(Canvas canvas, WinterWorld world) {
    _paintPiles(canvas, world);
    _paintBalls(canvas, world);
    _paintIcicles(canvas, world.icicles, world.time);
    final d = world.debris;
    if (d.count > 0) {
      canvas.drawRawAtlas(atlas, d.transformsView, d.rectsView, d.colorsView,
          BlendMode.modulate, null, _atlasPaint);
    }
  }

  // ------------------------------------------------------------------- piles

  void _paintPiles(Canvas canvas, WinterWorld world) {
    final now = world.time;
    for (final s in world.active) {
      final pile = s.pile;
      final cache = _piles.putIfAbsent(s.key, _PileCache.new);
      if (cache.version != pile.version && now - cache.builtAt > 0.1) {
        pile.buildPath(cache.path);
        final maxH = pile.maxCurrentHeight;
        cache
          ..version = pile.version
          ..builtAt = now
          ..maxHeight = maxH;
        cache.image?.dispose();
        cache.image = null;
        if (maxH >= 0.3) {
          final bounds = Rect.fromLTWH(-1, -maxH - 3, pile.width + 2, maxH + 6);
          cache.origin = bounds.topLeft;
          cache.image = _bake(bounds, (c) {
            if (s.kind == SurfaceKind.window) {
              c.drawRect(Rect.fromLTWH(0, 0, pile.width, 2), _pileShadow);
            }
            c.drawPath(cache.path, _pileFill);
            c.drawPath(cache.path, _pileEdge);
          });
        }
      }
      final image = cache.image;
      if (image == null) continue;

      final needsClip = s.occluders.isNotEmpty;
      if (needsClip) {
        canvas.save();
        _clipOccluders(canvas, s.occluders,
            Rect.fromLTRB(s.left, s.top - cache.maxHeight - 3, s.right, s.top + 3));
      }
      _drawBaked(canvas, image, Offset(s.left, s.top) + cache.origin);
      if (needsClip) canvas.restore();
    }
    if (_piles.length > world.active.length + 64) {
      final keys = {for (final s in world.active) s.key};
      _piles.removeWhere((k, c) {
        final drop = !keys.contains(k);
        if (drop) c.image?.dispose();
        return drop;
      });
    }
  }

  static void _clipOccluders(Canvas canvas, List<Rect> occluders, Rect content) {
    for (final r in occluders) {
      if (r.overlaps(content)) canvas.clipRect(r, clipOp: ui.ClipOp.difference);
    }
  }

  // ------------------------------------------------------------------- balls

  void _paintBalls(Canvas canvas, WinterWorld world) {
    for (final b in world.balls) {
      if (b.hidden || b.snowman != null) continue;
      _paintBall(canvas, b, shadow: b.support is SurfaceSupport);
    }
    for (final m in world.snowmen) {
      if (m.base.hidden) continue;
      _paintBall(canvas, m.base, shadow: m.base.support is SurfaceSupport);
      _paintArms(canvas, m);
      _paintBall(canvas, m.body, shadow: false);
      _paintBall(canvas, m.head, shadow: false);
      _paintDecorations(canvas, m);
    }
  }

  void _paintBall(Canvas canvas, SnowBall b, {required bool shadow}) {
    final c = Offset(b.x, b.y);
    final r = b.radius;
    if (shadow) {
      _fill
        ..shader = null
        ..color = const Color(0x2A0A1830);
      canvas.drawOval(Rect.fromCenter(center: c + Offset(0, r * 0.9), width: r * 2.1, height: r * 0.35), _fill);
    }
    _fill
      ..color = const Color(0xFFFFFFFF)
      ..shader = ui.Gradient.radial(
        c + Offset(-r * 0.35, -r * 0.4),
        r * 1.45,
        const [Color(0xFFFFFFFF), Color(0xFFEFF4FB), Color(0xFFC3D2E6), Color(0xFF9FB3CE)],
        const [0.0, 0.45, 0.85, 1.0],
      );
    canvas.drawCircle(c, r, _fill);
    _fill.shader = null;

    // Rolled-in texture that turns with the ball.
    final rng = math.Random(b.seed);
    _fill.color = const Color(0x307C93B3);
    for (var k = 0; k < 9; k++) {
      final a = rng.nextDouble() * math.pi * 2 + b.angle;
      final d = math.sqrt(rng.nextDouble()) * r * 0.82;
      final size = r * (0.04 + rng.nextDouble() * 0.06);
      canvas.drawCircle(c + Offset(math.cos(a) * d, math.sin(a) * d), size, _fill);
    }
    _stroke
      ..color = const Color(0x667E95B5)
      ..strokeWidth = 0.8;
    canvas.drawCircle(c, r, _stroke);
  }

  /// Decorations pop in one after another once three balls are stacked.
  static double _appear(Snowman m, int index) {
    final t = (m.age - 0.15 - index * 0.28) / 0.3;
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    // Ease-out with a small overshoot.
    final u = t - 1;
    return 1 + 2.2 * u * u * u + 1.2 * u * u;
  }

  void _paintArms(Canvas canvas, Snowman m) {
    final k = _appear(m, 0);
    if (k <= 0) return;
    final b = m.body;
    final len = b.radius * 1.25 * k;
    _stroke
      ..color = const Color(0xFF5B3A22)
      ..strokeWidth = math.max(1.6, b.radius * 0.085)
      ..strokeCap = StrokeCap.round;
    for (final side in const [-1.0, 1.0]) {
      final start = Offset(b.x + side * b.radius * 0.7, b.y - b.radius * 0.15);
      final angle = side < 0 ? math.pi + 0.45 : -0.45; // raised arms
      final dir = Offset(math.cos(angle), math.sin(angle));
      final end = start + dir * len;
      canvas.drawLine(start, end, _stroke);
      // Twigs.
      final twig = len * 0.32;
      final p1 = start + dir * (len * 0.62);
      final p2 = start + dir * (len * 0.82);
      canvas.drawLine(p1, p1 + Offset(math.cos(angle - side * 0.7), math.sin(angle - side * 0.7)) * twig, _stroke);
      canvas.drawLine(p2, p2 + Offset(math.cos(angle + side * 0.6), math.sin(angle + side * 0.6)) * twig * 0.8, _stroke);
    }
  }

  void _paintDecorations(Canvas canvas, Snowman m) {
    final h = m.head, b = m.body;
    final hr = h.radius;
    final f = m.facing;

    // Coal buttons.
    final kButtons = _appear(m, 1);
    if (kButtons > 0) {
      _fill.color = Color.fromRGBO(30, 30, 36, kButtons.clamp(0, 1));
      for (var i = 0; i < 3; i++) {
        canvas.drawCircle(Offset(b.x + f * b.radius * 0.06, b.y - b.radius * 0.45 + i * b.radius * 0.42),
            b.radius * 0.075 * kButtons, _fill);
      }
    }

    // Eyes + mouth.
    final kFace = _appear(m, 2);
    if (kFace > 0) {
      _fill.color = Color.fromRGBO(25, 25, 30, kFace.clamp(0, 1));
      for (final s in const [-1.0, 1.0]) {
        canvas.drawCircle(Offset(h.x + f * hr * 0.12 + s * hr * 0.3, h.y - hr * 0.22), hr * 0.1 * kFace, _fill);
      }
      for (var i = 0; i < 5; i++) {
        final a = math.pi * (0.25 + i * 0.125);
        canvas.drawCircle(
            Offset(h.x + f * hr * 0.1 + math.cos(a) * hr * 0.42, h.y + math.sin(a) * hr * 0.5 - hr * 0.02),
            hr * 0.055 * kFace,
            _fill);
      }
    }

    // Carrot nose.
    final kNose = _appear(m, 3);
    if (kNose > 0) {
      final base = Offset(h.x + f * hr * 0.1, h.y + hr * 0.02);
      final tip = base + Offset(f * hr * 0.95 * kNose, hr * 0.08);
      final nose = Path()
        ..moveTo(base.dx, base.dy - hr * 0.12)
        ..lineTo(tip.dx, tip.dy)
        ..lineTo(base.dx, base.dy + hr * 0.12)
        ..close();
      _fill
        ..color = const Color(0xFFFFFFFF)
        ..shader = ui.Gradient.linear(base, tip, const [Color(0xFFE86A17), Color(0xFFF59A3C)]);
      canvas.drawPath(nose, _fill);
      _fill.shader = null;
      _stroke
        ..color = const Color(0x80A0420A)
        ..strokeWidth = 0.8;
      for (var i = 1; i <= 2; i++) {
        final p = Offset.lerp(base, tip, i * 0.3)!;
        canvas.drawLine(p + Offset(0, -hr * 0.07), p + Offset(f * hr * 0.04, hr * 0.03), _stroke);
      }
    }

    // Knitted scarf around the neck with a hanging tail.
    final kScarf = _appear(m, 4);
    if (kScarf > 0) {
      final neckY = h.y + hr * 0.82;
      final w = hr * 1.95 * kScarf;
      final band = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(h.x, neckY), width: w, height: hr * 0.42), Radius.circular(hr * 0.2));
      _fill.color = const Color(0xFFC62B2B);
      canvas.drawRRect(band, _fill);
      final tail = Path()
        ..moveTo(h.x - f * hr * 0.45, neckY)
        ..lineTo(h.x - f * hr * 0.75, neckY + hr * 1.25 * kScarf)
        ..lineTo(h.x - f * hr * 0.35, neckY + hr * 1.3 * kScarf)
        ..lineTo(h.x - f * hr * 0.15, neckY)
        ..close();
      canvas.drawPath(tail, _fill);
      _stroke
        ..color = const Color(0xFFF2E6D0)
        ..strokeWidth = math.max(1, hr * 0.06);
      for (var i = -2; i <= 2; i++) {
        final x = h.x + i * hr * 0.32 * kScarf;
        canvas.drawLine(Offset(x, neckY - hr * 0.16), Offset(x, neckY + hr * 0.16), _stroke);
      }
      canvas.drawLine(Offset(h.x - f * hr * 0.66, neckY + hr * 0.95 * kScarf),
          Offset(h.x - f * hr * 0.32, neckY + hr * 0.98 * kScarf), _stroke);
    }

    // Top hat, dropping in from above.
    final kHat = _appear(m, 5);
    if (kHat > 0) {
      final drop = (1 - kHat.clamp(0, 1)) * hr * 1.5;
      canvas.save();
      canvas.translate(h.x + f * hr * 0.05, h.y - hr * 0.72 - drop);
      canvas.rotate(-f * 0.14);
      _fill.color = const Color(0xFF1B1B22);
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: hr * 1.7, height: hr * 0.16),
              Radius.circular(hr * 0.08)),
          _fill);
      canvas.drawRect(Rect.fromLTWH(-hr * 0.55, -hr * 1.0, hr * 1.1, hr * 0.95), _fill);
      _fill.color = const Color(0xFFB3202A);
      canvas.drawRect(Rect.fromLTWH(-hr * 0.55, -hr * 0.3, hr * 1.1, hr * 0.18), _fill);
      _fill.color = const Color(0x40FFFFFF);
      canvas.drawRect(Rect.fromLTWH(-hr * 0.45, -hr * 0.95, hr * 0.12, hr * 0.62), _fill);
      canvas.restore();
    }
  }

  // ----------------------------------------------------------------- icicles

  bool _icicleShapesChanged(IcicleSystem sys) {
    if (sys.ledgeVersion != _bakedLedgeVersion) return true;
    if (sys.icicles.length != _bakedLengths.length) return true;
    if (sys.breaks != _bakedFalling) return true;
    for (var i = 0; i < sys.icicles.length; i++) {
      if ((sys.icicles[i].length - _bakedLengths[i]).abs() > 0.75) return true;
    }
    return false;
  }

  void _paintIcicles(Canvas canvas, IcicleSystem sys, double now) {
    if (sys.icicles.isEmpty) return;
    final baseY = sys.baseY;

    final structural = sys.ledgeVersion != _bakedLedgeVersion ||
        sys.icicles.length != _bakedLengths.length ||
        sys.breaks != _bakedFalling;
    if (_icicleImage == null ||
        (_icicleShapesChanged(sys) && (structural || now - _icicleBakedAt > 1.0))) {
      var maxLen = 8.0;
      for (final ic in sys.icicles) {
        maxLen = math.max(maxLen, ic.length + 4);
      }
      final width = sys.icicles.isEmpty ? 1.0 : sys.screenWidth;
      _icicleImage?.dispose();
      _icicleImageHeight = maxLen;
      _icicleImage = _bake(Rect.fromLTWH(0, 0, width, maxLen), (c) {
        c.drawPath(sys.ledge, _iceFill);
        for (final ic in sys.icicles) {
          if (ic.length < 1) continue;
          final path = sys.pathFor(ic);
          c.save();
          c.translate(ic.x, 0);
          c.drawPath(path, _iceFill);
          c.drawPath(path, _iceEdge);
          if (ic.length > 10) {
            _iceHighlight.strokeWidth = math.max(0.8, ic.width * 0.12);
            c.drawLine(Offset(-ic.width * 0.18, 2), Offset(-ic.width * 0.05, ic.length * 0.7), _iceHighlight);
          }
          c.restore();
        }
      });
      _bakedLengths
        ..clear()
        ..addAll(sys.icicles.map((ic) => ic.length));
      _bakedLedgeVersion = sys.ledgeVersion;
      _bakedFalling = sys.breaks;
      _icicleBakedAt = now;
    }
    _drawBaked(canvas, _icicleImage!, Offset(0, baseY));

    // Live parts: water drops swelling at the tips.
    for (var i = 0; i < sys.icicles.length; i++) {
      final ic = sys.icicles[i];
      if (ic.dropPhase <= 0) continue;
      final r = 0.8 + ic.dropPhase * 1.6;
      final tipY = baseY + math.min(_bakedLengths[i], _icicleImageHeight);
      canvas.drawOval(Rect.fromCenter(center: Offset(ic.x, tipY + r), width: r * 1.8, height: r * 2.3), _drop);
    }

    for (final f in sys.falling) {
      canvas.save();
      canvas.translate(f.x, f.y);
      canvas.rotate(f.angle);
      canvas.drawPath(f.path, _iceFill);
      canvas.drawPath(f.path, _iceEdge);
      canvas.restore();
    }
  }
}

class _PileCache {
  final Path path = Path();
  ui.Image? image;
  Offset origin = Offset.zero;
  int version = -1;
  double builtAt = -1;
  double maxHeight = 0;
}

