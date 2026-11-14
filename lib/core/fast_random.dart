/// Small, allocation-free xorshift32 PRNG.
///
/// `dart:math` Random is fine too, but this one is deterministic across
/// platforms for a given seed (useful for tests) and cheap in hot loops.
class FastRandom {
  FastRandom([int seed = 0x9E3779B9]) : _state = _normalize(seed);

  int _state;

  static int _normalize(int seed) {
    final s = seed & 0xFFFFFFFF;
    return s == 0 ? 0x6D2B79F5 : s;
  }

  int nextUint32() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x;
    return x;
  }

  /// Uniform in [0, 1).
  double nextDouble() => nextUint32() / 4294967296.0;

  /// Uniform in [min, max).
  double range(double min, double max) => min + (max - min) * nextDouble();
}
