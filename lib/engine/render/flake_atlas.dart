import 'dart:ui' as ui;

/// Procedurally generated sprite atlas for snowflakes (no image assets).
///
/// Cell 0: a crisp flake with a soft edge.
/// Cell 1: an out-of-focus "bokeh" flake for the near layer.
/// Cell 2: an ice shard.
/// Cell 3: a water drop.
class FlakeAtlas {
  FlakeAtlas._();

  static const double cellSize = 64;
  static const int cellCount = 4;

  static Future<ui.Image> build() {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const r = cellSize / 2;

    void disc(double cx, List<ui.Color> colors, List<double> stops) {
      final paint = ui.Paint()
        ..shader = ui.Gradient.radial(ui.Offset(cx, r), r, colors, stops);
      canvas.drawCircle(ui.Offset(cx, r), r, paint);
    }

    disc(r, const [
      ui.Color(0xFFFFFFFF),
      ui.Color(0xF2FFFFFF),
      ui.Color(0x66FFFFFF),
      ui.Color(0x00FFFFFF),
    ], const [0.0, 0.32, 0.62, 1.0]);

    disc(cellSize + r, const [
      ui.Color(0x8CFFFFFF),
      ui.Color(0x70FFFFFF),
      ui.Color(0x26FFFFFF),
      ui.Color(0x00FFFFFF),
    ], const [0.0, 0.45, 0.78, 1.0]);

    // Ice shard: irregular translucent sliver with a bright edge.
    const sx = cellSize * 2;
    final shard = ui.Path()
      ..moveTo(sx + 30, 4)
      ..lineTo(sx + 44, 26)
      ..lineTo(sx + 38, 58)
      ..lineTo(sx + 22, 50)
      ..lineTo(sx + 18, 22)
      ..close();
    canvas.drawPath(
      shard,
      ui.Paint()
        ..shader = ui.Gradient.linear(
          const ui.Offset(sx + 18, 4),
          const ui.Offset(sx + 44, 58),
          const [ui.Color(0xE6F4FBFF), ui.Color(0x99BFE3FF), ui.Color(0xCCE8F6FF)],
          const [0.0, 0.55, 1.0],
        ),
    );
    canvas.drawPath(
      shard,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = const ui.Color(0xF2FFFFFF),
    );

    // Water drop: round with a highlight.
    const dx = cellSize * 3 + r;
    canvas.drawCircle(
      const ui.Offset(dx, r),
      r * 0.62,
      ui.Paint()
        ..shader = ui.Gradient.radial(
          const ui.Offset(dx - 6, r - 7),
          r * 0.7,
          const [ui.Color(0xF2FFFFFF), ui.Color(0xB3A9D4F5), ui.Color(0x8C6FA8D8)],
          const [0.0, 0.45, 1.0],
        ),
    );

    final picture = recorder.endRecording();
    final image = picture.toImage((cellSize * cellCount).toInt(), cellSize.toInt());
    picture.dispose();
    return image;
  }
}
