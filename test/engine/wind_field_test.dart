import 'package:flutter_test/flutter_test.dart';
import 'package:winter/engine/weather/wind_field.dart';

void main() {
  test('wind stays bounded and produces gusts', () {
    final w = WindField(seed: 3)
      ..baseSpeed = 20
      ..gustiness = 1;
    var maxEnv = 0.0, maxAbs = 0.0;
    for (var i = 0; i < 60 * 300; i++) {
      w.update(1 / 60);
      if (w.gustEnvelope > maxEnv) maxEnv = w.gustEnvelope;
      final v = w.sample(500, 0.5).abs();
      if (v > maxAbs) maxAbs = v;
    }
    expect(maxEnv, greaterThan(0.9), reason: 'at least one full gust in 5 minutes');
    expect(maxAbs, lessThan(400));
  });

  test('no gusts when gustiness is zero', () {
    final w = WindField(seed: 3)..gustiness = 0;
    for (var i = 0; i < 60 * 120; i++) {
      w.update(1 / 60);
      expect(w.gustEnvelope, 0);
    }
  });
}
