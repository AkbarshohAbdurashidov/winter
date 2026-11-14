import 'dart:math' as math;
import 'dart:ui';

/// What a resting body is supported by.
sealed class Support {
  const Support();
}

/// Resting on a surface (window top, Dock, floor) at a local x offset.
class SurfaceSupport extends Support {
  const SurfaceSupport(this.key, this.localX, this.sink);
  final Object key;
  final double localX;

  /// How far the ball's bottom sits above the bare surface (pile depth).
  final double sink;
}

/// Resting on top of another ball.
class BallSupport extends Support {
  const BallSupport(this.ball);
  final SnowBall ball;
}

enum BallState { held, falling, resting }

/// A rolled snowball. Grows by collecting snow from piles while dragged.
class SnowBall {
  SnowBall(this.x, this.y, this.radius, this.seed);

  double x, y, radius;
  double vx = 0, vy = 0;

  /// Accumulated roll angle (for the surface texture).
  double angle = 0;
  final int seed;
  BallState state = BallState.held;
  Support? support;
  Snowman? snowman;

  /// Hidden while its supporting window is not on screen.
  bool hidden = false;

  static const double minRadius = 5;
  static const double maxRadius = 70;

  double get area => math.pi * radius * radius;

  void addArea(double a) {
    radius = math.min(maxRadius, math.sqrt((area + a) / math.pi));
  }

  Rect get bounds => Rect.fromCircle(center: Offset(x, y), radius: radius);

  bool contains(Offset p) => (p - Offset(x, y)).distanceSquared <= radius * radius;

  /// Height at which a ball of [r] rests on top of this one.
  double stackY(double r) => y - radius - r * 0.78;
}

/// Three stacked balls, decorated automatically.
class Snowman {
  Snowman(this.balls) : facing = balls.first.seed.isEven ? 1 : -1;

  /// Bottom → top.
  final List<SnowBall> balls;

  /// Seconds since the snowman was completed (drives the decoration animation).
  double age = 0;

  /// 1 = looks right, -1 = looks left.
  final double facing;

  SnowBall get base => balls[0];
  SnowBall get body => balls[1];
  SnowBall get head => balls[2];

  Rect get bounds {
    var r = base.bounds.expandToInclude(body.bounds).expandToInclude(head.bounds);
    // Arms, hat and nose stick out.
    r = Rect.fromLTRB(r.left - body.radius * 1.2, r.top - head.radius * 1.3,
        r.right + body.radius * 1.2, r.bottom);
    return r;
  }
}
