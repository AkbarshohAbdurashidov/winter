import 'dart:math' as math;

import '../../core/fast_random.dart';

/// Global wind model: slow meander + random gust events + spatial turbulence.
///
/// The meander uses incommensurate sine periods and gusts are randomly
/// scheduled, so the pattern never visibly repeats.
class WindField {
  WindField({int seed = 1337}) : _rng = FastRandom(seed) {
    _gustCooldown = _rng.range(4, 10);
  }

  final FastRandom _rng;

  /// Mean wind speed in px/s (signed).
  double baseSpeed = 18;

  /// Gust strength/frequency multiplier (0 disables gusts).
  double gustiness = 1;

  /// Spatial turbulence multiplier.
  double turbulence = 1;

  /// Hard limit so even blizzard gusts keep snow readable.
  static const double maxSpeed = 420;

  double _time = 0;
  double _gustCooldown = 0;
  double _gustAge = 0;
  double _gustDuration = 0;
  double _gustPeak = 0;

  /// Spatially uniform component for the current frame (px/s).
  double current = 0;

  /// Current gust envelope in [0, 1], exposed for other animation layers.
  double gustEnvelope = 0;

  double get time => _time;

  void update(double dt) {
    _time += dt;
    final t = _time;
    final meander = 0.55 * math.sin(t * 0.071) +
        0.30 * math.sin(t * 0.1913 + 1.3) +
        0.15 * math.sin(t * 0.4371 + 4.1);

    if (_gustDuration > 0) {
      _gustAge += dt;
      if (_gustAge >= _gustDuration) {
        _gustDuration = 0;
        gustEnvelope = 0;
      } else {
        final s = math.sin(math.pi * _gustAge / _gustDuration);
        gustEnvelope = s * s;
      }
    } else if (gustiness > 0) {
      _gustCooldown -= dt;
      if (_gustCooldown <= 0) _startGust();
    }

    current = (baseSpeed * (1 + 0.35 * meander) + _gustPeak * gustEnvelope)
        .clamp(-maxSpeed, maxSpeed);
  }

  void _startGust() {
    _gustAge = 0;
    _gustDuration = _rng.range(2.5, 6.0);
    final direction = baseSpeed.abs() < 4
        ? (_rng.nextDouble() < 0.5 ? -1.0 : 1.0)
        : baseSpeed.sign;
    _gustPeak = direction *
        (baseSpeed.abs() * _rng.range(0.6, 1.5) * math.sqrt(gustiness) +
            _rng.range(25, 70) * gustiness);
    _gustCooldown = _rng.range(7, 24) / math.max(0.3, gustiness);
  }

  /// Wind at vertical position [y] for a particle at [depth] (0 far … 1 near).
  double sample(double y, double depth) =>
      current +
      turbulence *
          (11 * math.sin(y * 0.0061 + _time * 0.83 + depth * 5.0) +
              6 * math.sin(y * 0.0173 - _time * 1.31));
}
