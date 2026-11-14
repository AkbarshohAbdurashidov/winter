import 'package:flutter/widgets.dart';

import '../../performance/frame_stats.dart';
import 'overlay_controller.dart';

/// Small diagnostics readout. Rebuilds at most once per second.
class StatsHud extends StatelessWidget {
  const StatsHud({super.key, required this.controller});

  final OverlayController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FrameStatsSnapshot>(
      valueListenable: controller.stats.snapshot,
      builder: (context, s, _) {
        final sys = controller.system;
        final text = 'FPS ${s.fps.toStringAsFixed(1)} / cap ${controller.scheduler.targetFps}\n'
            'interval ${s.frameIntervalMs.toStringAsFixed(1)} ms (worst ${s.worstIntervalMs.toStringAsFixed(1)})\n'
            'ui ${s.buildMs.toStringAsFixed(2)} ms  raster ${s.rasterMs.toStringAsFixed(2)} ms (worst ${s.worstRasterMs.toStringAsFixed(1)})\n'
            'flakes ${sys.liveFlakes}/${sys.targetFlakes}  layers ${sys.activeLayers.length}\n'
            'quality ${controller.quality.name}  weather ${controller.intensity.name}\n'
            'wind ${sys.wind.current.toStringAsFixed(0)} px/s';
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xB30B1426),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Text(
              text,
              style: const TextStyle(
                color: Color(0xFFE6EEFF),
                fontSize: 11,
                height: 1.35,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      },
    );
  }
}
