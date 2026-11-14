import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:winter/engine/world/snow_pile.dart';
import 'package:winter/engine/world/winter_world.dart';
import 'package:winter/platform/overlay_platform.dart';

GeometryEvent _geometry(List<DesktopWindow> windows, {Rect? dock}) => GeometryEvent(
      screenWidth: 1280,
      screenHeight: 800,
      menuBarHeight: 0,
      menuBarThickness: 24,
      dock: dock ?? const Rect.fromLTWH(340, 739, 600, 61),
      windows: windows,
    );

void main() {
  group('SnowPile', () {
    test('deposits settle into a mound within the angle of repose', () {
      final p = SnowPile(300, maxHeight: 30);
      for (var i = 0; i < 400; i++) {
        p.deposit(150, 10);
        p.settle();
      }
      for (var k = 0; k < 50; k++) {
        p.settle();
      }
      for (var i = 0; i < p.cellCount - 1; i++) {
        expect((p.heightAtCell(i) - p.heightAtCell(i + 1)).abs(), lessThanOrEqualTo(SnowPile.maxStep + 0.05));
      }
      expect(p.heightAt(150), greaterThan(p.heightAt(20)));
    });

    test('snow spills off the ends', () {
      final p = SnowPile(30, maxHeight: 30);
      for (var i = 0; i < 300; i++) {
        p.deposit(15, 10);
        p.settle();
      }
      expect(p.spillLeft + p.spillRight, greaterThan(0));
      expect(p.heightAtCell(0), lessThanOrEqualTo(1.5));
    });

    test('take removes snow and reports the area', () {
      final p = SnowPile(100, maxHeight: 30);
      for (var i = 0; i < 100; i++) {
        p.deposit(50, 10);
      }
      final before = p.totalVolume;
      final taken = p.take(40, 60, 2);
      expect(taken, greaterThan(0));
      expect(p.totalVolume, closeTo(before - taken, 0.5));
    });
  });

  group('WinterWorld', () {
    test('flakes land on visible window tops but not where a front window covers', () {
      final w = WinterWorld()
        ..applyGeometry(_geometry(const [
          DesktopWindow(2, Rect.fromLTWH(500, 100, 300, 300)), // front
          DesktopWindow(1, Rect.fromLTWH(100, 200, 800, 400)), // behind
        ]));
      var landedCovered = 0, landedVisible = 0;
      for (var i = 0; i < 400; i++) {
        if (w.tryLand(600, 150, 205)) landedCovered++; // x=600,y=200 is under window 2
        if (w.tryLand(200, 150, 205)) landedVisible++;
      }
      expect(landedCovered, 0);
      expect(landedVisible, greaterThan(100));
    });

    test('three stacked snowballs become a decorated snowman', () {
      final w = WinterWorld()..applyGeometry(_geometry(const []));
      for (var i = 0; i < 3; i++) {
        // Drop each ball above the same spot on the floor (left of the Dock).
        final floor = w.active.firstWhere((s) => s.kind == SurfaceKind.floor);
        for (var k = 0; k < 200; k++) {
          floor.pile.deposit(150, 10);
        }
        floor.pile.settle();
        expect(w.pointerDown(Offset(150, 800 - floor.pile.heightAt(150) + 1)), isTrue);
        for (var k = 0; k < 40; k++) {
          w.pointerMove(Offset(100 + k * 2.0, 790));
        }
        w.pointerMove(const Offset(150, 300));
        w.pointerUp();
        for (var k = 0; k < 120; k++) {
          w.step(1 / 60);
        }
      }
      expect(w.snowmen, hasLength(1));
      final m = w.snowmen.single;
      expect(m.head.y, lessThan(m.body.y));
      expect(m.body.y, lessThan(m.base.y));
    });

    test('rolling a snowball through snow makes it grow', () {
      final w = WinterWorld()..applyGeometry(_geometry(const []));
      final floor = w.active.firstWhere((s) => s.kind == SurfaceKind.floor);
      for (var x = 10.0; x < 330; x += 2) {
        for (var k = 0; k < 6; k++) {
          floor.pile.deposit(x, 10);
        }
      }
      for (var k = 0; k < 50; k++) {
        floor.pile.settle();
      }
      expect(w.pointerDown(Offset(20, 800 - floor.pile.heightAt(20) + 1)), isTrue);
      final start = w.balls.single.radius;
      for (var x = 20.0; x < 320; x += 3) {
        w.pointerMove(Offset(x, 795));
      }
      expect(w.balls.single.radius, greaterThan(start * 2));
    });

    test('shaking a window throws its snow off', () {
      final w = WinterWorld();
      var rect = const Rect.fromLTWH(200, 200, 500, 300);
      w.applyGeometry(_geometry([DesktopWindow(7, rect)]));
      for (var i = 0; i < 300; i++) {
        w.tryLand(200 + (i % 50) * 10.0, 190, 201);
      }
      final pile = w.active.firstWhere((s) => s.key == 7).pile;
      expect(pile.totalVolume, greaterThan(0));
      for (var i = 0; i < 12; i++) {
        w.step(0.05);
        rect = rect.shift(Offset(i.isEven ? 90 : -90, 0));
        w.applyGeometry(_geometry([DesktopWindow(7, rect)]));
      }
      w.step(0.01);
      expect(pile.totalVolume, 0);
      expect(w.debris.count, greaterThan(0));
    });

    test('clicking an icicle breaks it and the piece shatters on the Dock', () {
      final w = WinterWorld()..applyGeometry(_geometry(const []));
      for (var i = 0; i < 60 * 600; i++) {
        w.icicles.step(1 / 60, w.debris, w.groundAt); // ten minutes of growth
      }
      final ic = w.icicles.icicles.reduce((a, b) => a.length > b.length ? a : b);
      final before = ic.length;
      expect(w.pointerDown(Offset(ic.x, ic.length / 2)), isTrue);
      expect(ic.length, lessThan(before));
      expect(w.icicles.falling, hasLength(1));
      for (var i = 0; i < 120; i++) {
        w.step(1 / 60);
      }
      expect(w.icicles.falling, isEmpty);
      expect(w.debris.count, greaterThan(0));
    });
  });
}
