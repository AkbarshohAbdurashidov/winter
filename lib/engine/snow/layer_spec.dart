/// Static description of one snow depth layer.
class LayerSpec {
  const LayerSpec({
    required this.name,
    required this.depth,
    required this.share,
    required this.radiusMin,
    required this.radiusMax,
    required this.fallMin,
    required this.fallMax,
    required this.alphaMin,
    required this.alphaMax,
    required this.windFactor,
    required this.swayMin,
    required this.swayMax,
    required this.responsiveness,
    required this.softSprite,
    this.collides = false,
  });

  final String name;

  /// 0 = far … 1 = near. Used for turbulence phase and parallax.
  final double depth;

  /// Fraction of the total flake budget assigned to this layer.
  final double share;

  /// Sprite half-extent in logical px.
  final double radiusMin, radiusMax;

  /// Terminal fall velocity range in px/s.
  final double fallMin, fallMax;

  final double alphaMin, alphaMax;

  /// How strongly wind moves this layer (parallax: near layers move more).
  final double windFactor;

  /// Side-to-side flutter amplitude in px/s.
  final double swayMin, swayMax;

  /// How quickly velocity adapts to the wind (1/s). Light flakes react faster.
  final double responsiveness;

  /// Whether this layer may use the soft (out-of-focus) sprite.
  final bool softSprite;

  /// Whether flakes of this layer land on windows, the Dock and the floor.
  final bool collides;

  static const far = LayerSpec(
    name: 'far',
    depth: 0.1,
    share: 0.5,
    radiusMin: 1.1,
    radiusMax: 2.2,
    fallMin: 22,
    fallMax: 42,
    alphaMin: 0.35,
    alphaMax: 0.65,
    windFactor: 0.6,
    swayMin: 3,
    swayMax: 8,
    responsiveness: 2.5,
    softSprite: false,
  );

  static const mid = LayerSpec(
    name: 'mid',
    depth: 0.5,
    share: 0.38,
    radiusMin: 2.2,
    radiusMax: 3.8,
    fallMin: 45,
    fallMax: 80,
    alphaMin: 0.6,
    alphaMax: 0.9,
    windFactor: 0.85,
    swayMin: 6,
    swayMax: 16,
    responsiveness: 1.8,
    softSprite: false,
    collides: true,
  );

  static const near = LayerSpec(
    name: 'near',
    depth: 0.95,
    share: 0.12,
    radiusMin: 5,
    radiusMax: 10,
    fallMin: 90,
    fallMax: 150,
    alphaMin: 0.3,
    alphaMax: 0.6,
    windFactor: 1.15,
    swayMin: 12,
    swayMax: 28,
    responsiveness: 1.2,
    softSprite: true,
  );

  /// Back-to-front order.
  static const all = [far, mid, near];
}
