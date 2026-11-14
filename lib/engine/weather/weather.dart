/// User-facing snowfall intensity presets.
enum SnowIntensity { light, normal, heavy, blizzard }

/// Numeric weather parameters consumed by the simulation.
///
/// Speeds are in logical pixels per second.
class WeatherParams {
  const WeatherParams({
    required this.flakesPerMegapixel,
    required this.windBase,
    required this.gustiness,
    required this.turbulence,
    required this.fallSpeedScale,
  });

  /// Target flake count per 1,000,000 logical px² before quality scaling.
  final double flakesPerMegapixel;

  /// Mean horizontal wind (positive = towards the right).
  final double windBase;

  /// 0 = no gusts. 1 = normal. Higher = stronger and more frequent gusts.
  final double gustiness;

  /// Spatial turbulence multiplier.
  final double turbulence;

  /// Multiplier on terminal fall velocity.
  final double fallSpeedScale;

  static WeatherParams forIntensity(SnowIntensity intensity) =>
      switch (intensity) {
        SnowIntensity.light => const WeatherParams(
            flakesPerMegapixel: 140,
            windBase: 8,
            gustiness: 0.6,
            turbulence: 0.6,
            fallSpeedScale: 0.85,
          ),
        SnowIntensity.normal => const WeatherParams(
            flakesPerMegapixel: 300,
            windBase: 18,
            gustiness: 1.0,
            turbulence: 1.0,
            fallSpeedScale: 1.0,
          ),
        SnowIntensity.heavy => const WeatherParams(
            flakesPerMegapixel: 700,
            windBase: 35,
            gustiness: 1.3,
            turbulence: 1.3,
            fallSpeedScale: 1.15,
          ),
        SnowIntensity.blizzard => const WeatherParams(
            flakesPerMegapixel: 1400,
            windBase: 170,
            gustiness: 2.2,
            turbulence: 2.4,
            fallSpeedScale: 1.5,
          ),
      };
}
