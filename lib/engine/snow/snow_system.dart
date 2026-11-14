import 'dart:ui' show Size;

import '../../core/fast_random.dart';
import '../quality/quality.dart';
import '../weather/weather.dart';
import '../weather/wind_field.dart';
import 'layer_spec.dart';
import 'snow_layer.dart';

/// Owns the wind and all snow depth layers; applies weather and quality.
class SnowSystem {
  SnowSystem({int seed = 20261114})
      : wind = WindField(seed: seed ^ 0x5bd1e995),
        _rng = FastRandom(seed) {
    layers = [
      for (final spec in LayerSpec.all)
        SnowLayer(
          spec,
          (QualityProfile.absoluteMaxFlakes * spec.share).ceil() + 1,
          _rng,
        ),
    ];
  }

  final FastRandom _rng;
  final WindField wind;
  late final List<SnowLayer> layers;

  Size _size = Size.zero;
  WeatherParams _weather = WeatherParams.forIntensity(SnowIntensity.normal);
  QualityProfile _quality = QualityProfile.forPreset(QualityPreset.medium);
  bool _seeded = false;

  Size get size => _size;
  WeatherParams get weather => _weather;
  QualityProfile get quality => _quality;

  /// Layers enabled by the current quality profile, back-to-front.
  Iterable<SnowLayer> get activeLayers sync* {
    for (final l in layers) {
      if (_isEnabled(l.spec)) yield l;
    }
  }

  int get liveFlakes {
    var n = 0;
    for (final l in layers) {
      n += l.count;
    }
    return n;
  }

  int get targetFlakes {
    var n = 0;
    for (final l in layers) {
      n += l.target;
    }
    return n;
  }

  bool _isEnabled(LayerSpec spec) => switch (_quality.layerCount) {
        1 => identical(spec, LayerSpec.mid),
        2 => !identical(spec, LayerSpec.near),
        _ => true,
      };

  /// Routes landing checks of colliding layers (mid) to [collider].
  set collider(FlakeCollider? collider) {
    for (final l in layers) {
      if (l.spec.collides) l.collider = collider;
    }
  }

  void setSize(Size size) {
    if (size == _size) return;
    for (final l in layers) {
      l.resize(_size.width, _size.height, size.width, size.height);
    }
    _size = size;
    _applyTargets();
  }

  void setWeather(WeatherParams weather) {
    _weather = weather;
    wind
      ..baseSpeed = weather.windBase
      ..gustiness = weather.gustiness
      ..turbulence = weather.turbulence;
    _applyTargets();
  }

  void setQuality(QualityProfile quality) {
    _quality = quality;
    _applyTargets();
  }

  void _applyTargets() {
    if (_size.isEmpty) return;
    final megapixels = _size.width * _size.height / 1e6;
    final total = (megapixels * _weather.flakesPerMegapixel * _quality.densityScale)
        .clamp(0, _quality.maxFlakes.toDouble());

    var shareSum = 0.0;
    for (final l in layers) {
      if (_isEnabled(l.spec)) shareSum += l.spec.share;
    }
    for (final l in layers) {
      if (!_isEnabled(l.spec)) {
        l.clear();
        continue;
      }
      l.useSoftSprite = _quality.bokeh;
      final n = (total * l.spec.share / shareSum).round();
      l.setTarget(n, _size.width, _size.height, fillScreen: !_seeded || l.count == 0);
    }
    _seeded = true;
  }

  void step(double dt) {
    if (_size.isEmpty) return;
    wind.update(dt);
    for (final l in layers) {
      if (l.count == 0) continue;
      l.step(dt, wind, _size.width, _size.height, _weather.fallSpeedScale);
    }
  }
}
