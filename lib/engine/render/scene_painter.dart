import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import '../snow/snow_system.dart';
import '../world/winter_world.dart';
import 'world_renderer.dart';

/// Paints the whole overlay in one pass: far/mid snow, the desktop world
/// (piles, snowmen, icicles, debris), then near snow in front.
class ScenePainter extends CustomPainter {
  ScenePainter({
    required this.system,
    required this.world,
    required this.atlas,
    required WorldRenderer renderer,
    required super.repaint,
  }) : _world = renderer;

  final SnowSystem system;
  final WinterWorld world;
  final ui.Image atlas;
  final WorldRenderer _world;
  final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    var worldDrawn = false;
    for (final layer in system.activeLayers) {
      if (!worldDrawn && layer.spec.softSprite) {
        _world.paint(canvas, world);
        worldDrawn = true;
      }
      if (layer.count == 0) continue;
      canvas.drawRawAtlas(atlas, layer.transformsView, layer.rectsView,
          layer.colorsView, BlendMode.modulate, null, _paint);
    }
    if (!worldDrawn) _world.paint(canvas, world);
  }

  @override
  bool shouldRepaint(ScenePainter oldDelegate) =>
      oldDelegate.system != system || oldDelegate.world != world || oldDelegate.atlas != atlas || oldDelegate._world != _world;
}
