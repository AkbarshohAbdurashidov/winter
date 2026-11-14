import 'dart:async';
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart';

import '../../account/account_service.dart';
import '../../engine/loop/frame_scheduler.dart';
import '../../engine/quality/quality.dart';
import '../../engine/snow/snow_system.dart';
import '../../engine/weather/weather.dart';
import '../../engine/world/winter_world.dart';
import '../../performance/frame_stats.dart';
import '../../platform/overlay_platform.dart';

/// Application state for the overlay. Owns the simulation lifecycle and
/// translates native menu actions into engine changes.
///
/// Notifies listeners only on user-visible state changes, never per frame.
class OverlayController extends ChangeNotifier {
  OverlayController({
    required this._platform,
    this.account,
    SnowSystem? system,
    WinterWorld? world,
    FrameStats? stats,
  })  : system = system ?? SnowSystem(),
        world = world ?? WinterWorld(),
        stats = stats ?? FrameStats() {
    this.system.collider = this.world;
    scheduler = FrameScheduler(
      onStep: _step,
      onFrameRendered: this.stats.recordInterval,
    );
  }

  final OverlayPlatform _platform;

  /// Pro status and sign-in. Null = no account features (tests, builds
  /// without a backend): every option is available.
  final AccountService? account;
  final SnowSystem system;
  final WinterWorld world;
  final FrameStats stats;

  double _sinceHitRegions = 0;
  List<Rect> _sentRegions = const [];
  late final FrameScheduler scheduler;
  StreamSubscription<OverlayEvent>? _sub;

  bool _userPaused = const bool.fromEnvironment('WINTER_START_PAUSED');
  bool _visible = true;
  // Build-time defaults (e.g. --dart-define=WINTER_QUALITY=ultraLow) make
  // profiling individual presets reproducible. Persisted settings: Phase 6.
  bool _showStats = const bool.fromEnvironment('WINTER_STATS');
  OverlayLevel _level = OverlayLevel.aboveWindows;
  SnowIntensity _intensity = SnowIntensity.values.byName(
      const String.fromEnvironment('WINTER_INTENSITY', defaultValue: 'normal'));
  QualityPreset _quality = QualityPreset.values.byName(
      const String.fromEnvironment('WINTER_QUALITY', defaultValue: 'medium'));

  bool get userPaused => _userPaused;
  bool get visible => _visible;
  bool get showStats => _showStats;
  OverlayLevel get level => _level;
  SnowIntensity get intensity => _intensity;
  QualityPreset get quality => _quality;
  bool get isAnimating => scheduler.isRunning;

  /// Options that need Winter Pro (when a backend is configured).
  static const proIntensities = {SnowIntensity.heavy, SnowIntensity.blizzard};
  static const proQualities = {QualityPreset.high, QualityPreset.ultra};

  bool get _proRequired => account?.enabled ?? false;
  bool get hasPro => !_proRequired || account!.isPro;

  Future<void> init() async {
    _sub = _platform.events.listen(_onEvent);
    account?.addListener(_onAccountChanged);
    _enforcePro();
    system
      ..setWeather(WeatherParams.forIntensity(_intensity))
      ..setQuality(QualityProfile.forPreset(_quality));
    scheduler.targetFps = system.quality.targetFps;
    stats.attach();
    await _platform.setClickThrough(true);
    await _platform.setLevel(_level);
    await _syncMenu();
    await _platform.requestGeometry();
    _updateRunning();
  }

  void setViewport(Size size) => system.setSize(size);

  void _step(double dt) {
    system.step(dt);
    world.step(dt);
    _sinceHitRegions += dt;
    if (_sinceHitRegions >= 0.15) {
      _sinceHitRegions = 0;
      _syncHitRegions();
    }
  }

  /// Sends interactive regions to the native side only when they changed.
  void _syncHitRegions() {
    final regions = world.hitRegions();
    if (_sameRegions(regions, _sentRegions)) return;
    _sentRegions = regions;
    unawaited(_platform.setHitRegions(regions));
  }

  static bool _sameRegions(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i], y = b[i];
      if ((x.left - y.left).abs() > 2 || (x.top - y.top).abs() > 2 ||
          (x.right - y.right).abs() > 2 || (x.bottom - y.bottom).abs() > 2) {
        return false;
      }
    }
    return true;
  }

  // Pointer input arrives only where the native side made the overlay
  // interactive (snow piles, snowballs, icicles).
  void pointerDown(Offset p) => world.pointerDown(p);
  void pointerMove(Offset p) => world.pointerMove(p);
  void pointerUp() => world.pointerUp();

  void setPaused(bool paused) {
    if (_userPaused == paused) return;
    _userPaused = paused;
    _updateRunning();
    _changed();
  }

  void setIntensity(SnowIntensity value) {
    _intensity = value;
    system.setWeather(WeatherParams.forIntensity(value));
    _changed();
  }

  void setQuality(QualityPreset value) {
    _quality = value;
    final profile = QualityProfile.forPreset(value);
    system.setQuality(profile);
    scheduler.targetFps = profile.targetFps;
    _changed();
  }

  void setLevel(OverlayLevel value) {
    _level = value;
    unawaited(_platform.setLevel(value));
    _changed();
  }

  void setShowStats(bool value) {
    _showStats = value;
    _changed();
  }

  void _onEvent(OverlayEvent event) {
    switch (event) {
      case MenuActionEvent(:final action):
        _onMenuAction(action);
      case VisibilityEvent(:final visible):
        _visible = visible;
        _updateRunning();
      case GeometryEvent():
        world.applyGeometry(event);
      case DisplaysChangedEvent():
        // The window is refitted natively; the new size arrives via layout.
        break;
    }
  }

  void _onAccountChanged() {
    _enforcePro();
    _changed();
  }

  /// Without Pro, Pro-only settings fall back to the best free ones.
  void _enforcePro() {
    if (hasPro) return;
    if (proIntensities.contains(_intensity)) {
      _intensity = SnowIntensity.normal;
      system.setWeather(WeatherParams.forIntensity(_intensity));
    }
    if (proQualities.contains(_quality)) {
      _quality = QualityPreset.medium;
      final profile = QualityProfile.forPreset(_quality);
      system.setQuality(profile);
      scheduler.targetFps = profile.targetFps;
    }
  }

  void _onMenuAction(String action) {
    final parts = action.split(':');
    // Menu actions reach every screen's engine; only the account owner
    // (first screen) talks to the backend, the others re-read its state.
    if (parts.first == 'account') {
      final a = account;
      if (a == null) return;
      if (!a.owner) {
        Future<void>.delayed(const Duration(seconds: 2), a.reloadFromStore);
        return;
      }
      switch (parts.elementAtOrNull(1)) {
        case 'signIn':
          unawaited(a.signIn());
        case 'signOut':
          unawaited(a.signOut());
        case 'upgrade':
          unawaited(a.upgrade());
        case 'manage':
          unawaited(a.openAccount());
        case 'refresh':
          unawaited(a.refresh());
      }
      return;
    }
    switch (parts) {
      case ['togglePause']:
        setPaused(!_userPaused);
      case ['clearSnow']:
        world.clearAll();
      case ['toggleStats']:
        setShowStats(!_showStats);
      case ['level', final name]:
        setLevel(OverlayLevel.values.byName(name));
      case ['intensity', final name]:
        final value = SnowIntensity.values.byName(name);
        if (!hasPro && proIntensities.contains(value)) return _offerPro();
        setIntensity(value);
      case ['quality', final name]:
        final value = QualityPreset.values.byName(name);
        if (!hasPro && proQualities.contains(value)) return _offerPro();
        setQuality(value);
    }
  }

  /// A Pro-only option was chosen without Pro: open the Pro request page (once,
  /// from the first screen) and keep the current setting.
  void _offerPro() {
    final a = account;
    if (a != null && a.owner) unawaited(a.upgrade());
    _changed(); // re-sync check marks
  }

  void _updateRunning() {
    final shouldRun = !_userPaused && _visible;
    if (shouldRun && !scheduler.isRunning) {
      stats.resetClock();
      scheduler.start();
    } else if (!shouldRun && scheduler.isRunning) {
      scheduler.stop();
    }
  }

  void _changed() {
    unawaited(_syncMenu());
    notifyListeners();
  }

  Future<void> _syncMenu() => _platform.updateMenuState(OverlayMenuState(
        paused: _userPaused,
        level: _level,
        intensity: _intensity.name,
        quality: _quality.name,
        showStats: _showStats,
        account: AccountMenuState(
          enabled: account?.enabled ?? false,
          signedIn: account?.signedIn ?? false,
          linking: account?.linking ?? false,
          pro: hasPro,
          email: account?.status.email ?? '',
          planLabel: account?.status.label ?? '',
        ),
      ));

  @override
  void dispose() {
    account?.removeListener(_onAccountChanged);
    _sub?.cancel();
    scheduler.dispose();
    stats.dispose();
    super.dispose();
  }
}
