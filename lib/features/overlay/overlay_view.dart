import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../engine/render/scene_painter.dart';
import '../../engine/render/world_renderer.dart';
import 'overlay_controller.dart';
import 'stats_hud.dart';

/// Full-window transparent overlay. Built once; snow repaints through the
/// scheduler's repaint notifier, not through widget rebuilds.
class OverlayView extends StatelessWidget {
  const OverlayView({
    super.key,
    required this.controller,
    required this.atlas,
    required this.renderer,
  });

  final OverlayController controller;
  final ui.Image atlas;

  /// Owned by the app state so its GPU caches survive rebuilds.
  final WorldRenderer renderer;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        controller.setViewport(constraints.biggest);
        return Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) => controller.pointerDown(e.localPosition),
              onPointerMove: (e) => controller.pointerMove(e.localPosition),
              onPointerUp: (_) => controller.pointerUp(),
              onPointerCancel: (_) => controller.pointerUp(),
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: ScenePainter(
                      system: controller.system,
                      world: controller.world,
                      atlas: atlas,
                      renderer: renderer,
                      repaint: controller.scheduler.repaint,
                    ),
                  ),
                ),
              ),
            ),
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => controller.showStats
                  ? Positioned(
                      right: 16,
                      top: 40,
                      child: RepaintBoundary(child: StatsHud(controller: controller)),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        );
      },
    );
  }
}
