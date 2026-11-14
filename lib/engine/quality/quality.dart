/// Rendering quality presets. Phase 2 adds automatic selection.
enum QualityPreset { ultraLow, low, medium, high, ultra }

/// Concrete parameters for a quality level.
class QualityProfile {
  const QualityProfile({
    required this.layerCount,
    required this.densityScale,
    required this.targetFps,
    required this.maxFlakes,
    required this.bokeh,
  });

  /// Number of snow depth layers (1–3). 1 = mid layer only.
  final int layerCount;

  /// Multiplier on weather flake density.
  final double densityScale;

  /// Frame-rate cap. The display refresh rate is the real upper bound.
  final int targetFps;

  /// Hard cap on simulated flakes regardless of screen size / weather.
  final int maxFlakes;

  /// Whether near flakes use the soft out-of-focus sprite.
  final bool bokeh;

  static QualityProfile forPreset(QualityPreset preset) => switch (preset) {
        QualityPreset.ultraLow => const QualityProfile(
            layerCount: 1,
            densityScale: 0.35,
            targetFps: 30,
            maxFlakes: 300,
            bokeh: false,
          ),
        QualityPreset.low => const QualityProfile(
            layerCount: 2,
            densityScale: 0.6,
            targetFps: 30,
            maxFlakes: 800,
            bokeh: false,
          ),
        QualityPreset.medium => const QualityProfile(
            layerCount: 3,
            densityScale: 0.85,
            targetFps: 60,
            maxFlakes: 1600,
            bokeh: true,
          ),
        QualityPreset.high => const QualityProfile(
            layerCount: 3,
            densityScale: 1.0,
            targetFps: 60,
            maxFlakes: 3200,
            bokeh: true,
          ),
        QualityPreset.ultra => const QualityProfile(
            layerCount: 3,
            densityScale: 1.25,
            targetFps: 120,
            maxFlakes: 6000,
            bokeh: true,
          ),
      };

  /// Largest [maxFlakes] of any preset; buffers are allocated once at this size.
  static const int absoluteMaxFlakes = 6000;
}
