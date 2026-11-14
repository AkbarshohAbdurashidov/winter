import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:winter/engine/quality/quality.dart';
import 'package:winter/engine/snow/snow_system.dart';
import 'package:winter/engine/weather/weather.dart';

SnowSystem _system(QualityPreset q, SnowIntensity i, Size size) => SnowSystem(seed: 7)
  ..setWeather(WeatherParams.forIntensity(i))
  ..setQuality(QualityProfile.forPreset(q))
  ..setSize(size);

void main() {
  const fhd = Size(1920, 1080);

  test('flake count scales with intensity and respects quality cap', () {
    final light = _system(QualityPreset.high, SnowIntensity.light, fhd).liveFlakes;
    final heavy = _system(QualityPreset.high, SnowIntensity.heavy, fhd).liveFlakes;
    expect(heavy, greaterThan(light * 3));

    final capped = _system(QualityPreset.ultraLow, SnowIntensity.blizzard, const Size(3840, 2160));
    expect(capped.liveFlakes, lessThanOrEqualTo(QualityProfile.forPreset(QualityPreset.ultraLow).maxFlakes));
    expect(capped.activeLayers.length, 1);
  });

  test('flake count scales with screen area', () {
    final small = _system(QualityPreset.medium, SnowIntensity.normal, const Size(1280, 720)).liveFlakes;
    final big = _system(QualityPreset.medium, SnowIntensity.normal, fhd).liveFlakes;
    expect(big / small, closeTo(2.25, 0.1));
  });

  test('long simulation keeps flakes bounded, recycled and finite', () {
    final s = _system(QualityPreset.high, SnowIntensity.blizzard, fhd);
    final initial = s.liveFlakes;
    for (var i = 0; i < 60 * 120; i++) {
      s.step(1 / 60); // two simulated minutes
    }
    expect(s.liveFlakes, initial);
    for (final layer in s.layers) {
      for (var i = 0; i < layer.count; i++) {
        final x = layer.xAt(i), y = layer.yAt(i);
        expect(x.isFinite && y.isFinite, isTrue);
        expect(x, inInclusiveRange(-41, fhd.width + 41));
        expect(y, inInclusiveRange(-500, fhd.height + 60));
      }
    }
  });

  test('lowering intensity retires flakes gracefully as they leave the screen', () {
    final s = _system(QualityPreset.high, SnowIntensity.heavy, fhd);
    final before = s.liveFlakes;
    s.setWeather(WeatherParams.forIntensity(SnowIntensity.light));
    expect(s.liveFlakes, before, reason: 'no instant pop-out');
    for (var i = 0; i < 60 * 60; i++) {
      s.step(1 / 60);
    }
    expect(s.liveFlakes, s.targetFlakes);
    expect(s.liveFlakes, lessThan(before / 2));
  });

  test('render views always match live count', () {
    final s = _system(QualityPreset.medium, SnowIntensity.heavy, fhd);
    s.setWeather(WeatherParams.forIntensity(SnowIntensity.light));
    for (var i = 0; i < 600; i++) {
      s.step(1 / 30);
      for (final l in s.activeLayers) {
        expect(l.transformsView.length, l.count * 4);
        expect(l.rectsView.length, l.count * 4);
        expect(l.colorsView.length, l.count);
      }
    }
  });

  test('switching to fewer layers clears disabled layers', () {
    final s = _system(QualityPreset.high, SnowIntensity.normal, fhd);
    s.setQuality(QualityProfile.forPreset(QualityPreset.ultraLow));
    expect(s.layers.first.count, 0);
    expect(s.layers.last.count, 0);
  });
}
