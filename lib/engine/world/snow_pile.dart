import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Height-map of snow lying on a horizontal edge (window top, Dock, floor).
///
/// Coordinates are local: x in [0, width], heights grow upwards from y = 0.
/// Deposits are spread over neighbouring cells, and a relaxation pass lets
/// snow slide when the slope exceeds the angle of repose, so piles form
/// natural mounds and snow spills off the ends.
class SnowPile {
  SnowPile(double width, {required this.maxHeight}) : _width = width {
    _heights = Float32List(_cellsFor(width));
  }

  static const double cellWidth = 3;

  /// Max height difference between neighbouring cells (angle of repose).
  static const double maxStep = 1.6;

  final double maxHeight;
  double _width;
  late Float32List _heights;
  bool _unsettled = false;

  /// Incremented whenever the shape changes; renderers cache by it.
  int version = 0;

  /// Snow that slid off an end since the last call to [takeSpill];
  /// negative x = left end, positive = right end. Used to spawn clumps.
  double spillLeft = 0, spillRight = 0;

  double get width => _width;
  int get cellCount => _heights.length;
  double heightAtCell(int i) => _heights[i];

  static int _cellsFor(double width) => math.max(2, (width / cellWidth).ceil() + 1);

  double get maxCurrentHeight {
    var m = 0.0;
    for (final h in _heights) {
      if (h > m) m = h;
    }
    return m;
  }

  double get totalVolume {
    var v = 0.0;
    for (final h in _heights) {
      v += h;
    }
    return v * cellWidth;
  }

  /// Resamples when the surface width changes (window resize).
  void resize(double width) {
    if ((width - _width).abs() < 0.5) return;
    final old = _heights;
    final n = _cellsFor(width);
    final next = Float32List(n);
    for (var i = 0; i < n; i++) {
      final src = (i / (n - 1)) * (old.length - 1);
      final a = src.floor(), b = math.min(a + 1, old.length - 1);
      final t = src - a;
      next[i] = old[a] * (1 - t) + old[b] * t;
    }
    _heights = next;
    _width = width;
    _unsettled = true;
    version++;
  }

  double heightAt(double x) {
    final f = x / cellWidth;
    if (f <= 0) return _heights[0];
    final last = _heights.length - 1;
    if (f >= last) return _heights[last];
    final i = f.floor();
    final t = f - i;
    return _heights[i] * (1 - t) + _heights[i + 1] * t;
  }

  static const _kernel = [0.07, 0.18, 0.5, 0.18, 0.07];

  /// Adds [area] (px²) of snow centred at local [x].
  void deposit(double x, double area) {
    final c = (x / cellWidth).round();
    final dh = area / cellWidth;
    for (var k = -2; k <= 2; k++) {
      final i = c + k;
      if (i < 0 || i >= _heights.length) continue;
      _heights[i] = math.min(maxHeight, _heights[i] + dh * _kernel[k + 2]);
    }
    _unsettled = true;
    version++;
  }

  /// Removes up to [depth] px of snow over [x0, x1]; returns removed area.
  double take(double x0, double x1, double depth) {
    final a = math.max(0, (x0 / cellWidth).floor());
    final b = math.min(_heights.length - 1, (x1 / cellWidth).ceil());
    var removed = 0.0;
    for (var i = a; i <= b; i++) {
      final h = _heights[i];
      final d = math.min(h, depth);
      _heights[i] = h - d;
      removed += d;
    }
    if (removed > 0) {
      _unsettled = true;
      version++;
    }
    return removed * cellWidth;
  }

  void clear() {
    _heights.fillRange(0, _heights.length, 0);
    version++;
  }

  /// One or two relaxation sweeps; cheap and only runs when disturbed.
  void settle() {
    if (!_unsettled) return;
    final h = _heights;
    final n = h.length;
    var moved = false;
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i < n - 1; i++) {
        final d = h[i] - h[i + 1];
        if (d > maxStep) {
          final m = (d - maxStep) * 0.5;
          h[i] -= m;
          h[i + 1] += m;
          moved = true;
        } else if (d < -maxStep) {
          final m = (-d - maxStep) * 0.5;
          h[i + 1] -= m;
          h[i] += m;
          moved = true;
        }
      }
    }
    // Snow slides off the edges: the end cells cannot hold more than a lip.
    const lip = 1.5;
    if (h[0] > lip) {
      spillLeft += (h[0] - lip) * cellWidth;
      h[0] = lip;
      moved = true;
    }
    if (h[n - 1] > lip) {
      spillRight += (h[n - 1] - lip) * cellWidth;
      h[n - 1] = lip;
      moved = true;
    }
    if (moved) {
      version++;
    } else {
      _unsettled = false;
    }
  }

  /// Builds the outline in local coordinates (baseline y = 0, up = negative).
  void buildPath(Path path) {
    path.reset();
    final h = _heights;
    final n = h.length;
    path.moveTo(0, 0);
    path.lineTo(0, -h[0]);
    var px = 0.0, py = -h[0];
    for (var i = 1; i < n; i++) {
      final x = math.min(i * cellWidth, _width);
      final y = -h[i];
      path.quadraticBezierTo(px, py, (px + x) / 2, (py + y) / 2);
      px = x;
      py = y;
    }
    path.lineTo(px, py);
    path.lineTo(_width, 0);
    path.close();
  }
}
