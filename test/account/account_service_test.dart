import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:winter/account/account_service.dart';
import 'package:winter/engine/quality/quality.dart';
import 'package:winter/engine/weather/weather.dart';
import 'package:winter/features/overlay/overlay_controller.dart';
import 'package:winter/platform/overlay_platform.dart';

/// In-memory backend with the same contract as the `app` edge function.
class FakeApi implements AccountApi {
  final calls = <String>[];
  bool online = true;
  bool approved = false;
  Map<String, Object?> status = {'signedIn': true, 'email': 'a@b.c', 'pro': false, 'access': 'none'};

  @override
  Future<Map<String, Object?>> post(String path, Map<String, Object?> body) async {
    calls.add(path);
    if (!online) throw const SocketException('offline');
    switch (path) {
      case '/heartbeat':
        return {'ok': true};
      case '/link/start':
        return {'url': 'https://portal/link?code=${body['code']}${body['next'] == null ? '' : '&next=${body['next']}'}'};
      case '/link/poll':
        return approved ? {'status': 'approved', 'token': 'tok-123456789012345678901234', 'email': 'a@b.c'} : {'status': 'pending'};
      case '/status':
        if (body['token'] == null) return {'signedIn': false, 'pro': false, 'access': 'none', 'upgradeUrl': 'https://portal/upgrade'};
        return {
          ...status,
          'checkedAt': DateTime.now().toIso8601String(),
          'upgradeUrl': 'https://pay/uid',
          'accountUrl': 'https://portal/account',
        };
      case '/signout':
        return {'ok': true};
    }
    throw StateError(path);
  }
}

class FakePlatform implements OverlayPlatform {
  final _events = StreamController<OverlayEvent>.broadcast();
  OverlayMenuState? menu;
  void emit(OverlayEvent e) => _events.add(e);
  @override
  Stream<OverlayEvent> get events => _events.stream;
  @override
  Future<void> setClickThrough(bool enabled) async {}
  @override
  Future<void> setLevel(OverlayLevel level) async {}
  @override
  Future<void> updateMenuState(OverlayMenuState state) async => menu = state;
  @override
  Future<void> setHitRegions(regions) async {}
  @override
  Future<void> requestGeometry() async {}
  @override
  Future<Map<String, Object?>> diagnostics() async => {};
  @override
  Future<void> dispose() async => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeApi api;
  late List<String> opened;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('winter_account');
    api = FakeApi();
    opened = [];
  });
  tearDown(() => dir.deleteSync(recursive: true));

  AccountService service({bool owner = true}) => AccountService(
        owner: owner,
        api: api,
        store: AccountStore(File('${dir.path}/account.json')),
        openUrl: (url) async => opened.add(url),
      )..pollInterval = const Duration(milliseconds: 5);

  test('first launch creates an install id and sends a heartbeat', () async {
    final s = service();
    await s.start();
    await Future<void>.delayed(Duration.zero);
    expect(s.installId, hasLength(48));
    expect(api.calls, containsAll(['/heartbeat', '/status']));
    expect(s.signedIn, isFalse);
    expect(s.isPro, isFalse);
    // The id survives restarts.
    final again = service();
    await again.start();
    expect(again.installId, s.installId);
    s.dispose();
    again.dispose();
  });

  test('sign-in opens the browser and stores the token once approved', () async {
    final s = service();
    await s.start();
    final done = s.signIn();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(opened.single, startsWith('https://portal/link?code='));
    expect(s.linking, isTrue);
    api.approved = true;
    await done;
    expect(s.linking, isFalse);
    expect(s.signedIn, isTrue);
    expect(s.status.email, 'a@b.c');
    // A second engine (other screen) sees it from the shared file.
    final follower = service(owner: false);
    await follower.start();
    expect(follower.signedIn, isTrue);
    s.dispose();
    follower.dispose();
  });

  test('Pro status is cached for offline use', () async {
    final s = service();
    await s.start();
    api.approved = true;
    await s.signIn();
    api.status = {'signedIn': true, 'email': 'a@b.c', 'pro': true, 'access': 'pro'};
    await s.refresh();
    expect(s.isPro, isTrue);
    expect(s.status.label, '', reason: 'Pro without an end date: just "Winter Pro"');
    api.online = false;
    final restarted = service();
    await restarted.start();
    await Future<void>.delayed(Duration.zero);
    expect(restarted.isPro, isTrue, reason: 'cached answer within the offline grace');
    s.dispose();
    restarted.dispose();
  });

  test('cached Pro expires after the offline grace period', () {
    final checked = DateTime(2026, 1, 1);
    final status = ProStatus(signedIn: true, pro: true, access: 'pro', checkedAt: checked);
    expect(status.proAt(checked.add(const Duration(days: 13))), isTrue);
    expect(status.proAt(checked.add(const Duration(days: 15))), isFalse);
    final until = ProStatus(signedIn: true, pro: true, access: 'pro', checkedAt: checked, expiresAt: DateTime(2026, 1, 31, 12));
    expect(until.proAt(checked.add(const Duration(days: 9))), isTrue);
    expect(until.proAt(checked.add(const Duration(days: 31))), isFalse, reason: 'Pro given until a date ends then');
    expect(until.label, 'until 2026-01-31');
  });

  test('a token revoked on the server signs the app out', () async {
    final s = service();
    await s.start();
    api.approved = true;
    await s.signIn();
    api.status = {'signedIn': false, 'pro': false, 'access': 'none'};
    await s.refresh();
    expect(s.signedIn, isFalse);
    s.dispose();
  });

  test('upgrade without an account signs in first, then goes to the paywall', () async {
    final s = service();
    await s.start();
    api.approved = true;
    await s.upgrade();
    expect(opened.first, contains('next=upgrade'));
    await s.upgrade();
    expect(opened.last, 'https://pay/uid');
    s.dispose();
  });

  group('Pro gating', () {
    test('Pro-only settings open the paywall instead of applying', () async {
      final platform = FakePlatform();
      final s = service();
      final c = OverlayController(platform: platform, account: s);
      await c.init();
      await s.start();
      platform.emit(const MenuActionEvent('intensity:blizzard'));
      platform.emit(const MenuActionEvent('quality:ultra'));
      platform.emit(const MenuActionEvent('intensity:light'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.intensity, SnowIntensity.light);
      expect(c.quality, isNot(QualityPreset.ultra));
      expect(opened, isNotEmpty, reason: 'paywall / sign-in opened');
      expect(platform.menu!.account.enabled, isTrue);
      expect(platform.menu!.account.pro, isFalse);
      c.dispose();
      s.dispose();
    });

    test('with Pro everything applies; losing Pro falls back to free settings', () async {
      final platform = FakePlatform();
      final s = service();
      api.approved = true;
      api.status = {'signedIn': true, 'email': 'a@b.c', 'pro': true, 'access': 'pro'};
      await s.start();
      await s.signIn();
      final c = OverlayController(platform: platform, account: s);
      await c.init();
      platform.emit(const MenuActionEvent('intensity:blizzard'));
      platform.emit(const MenuActionEvent('quality:ultra'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.intensity, SnowIntensity.blizzard);
      expect(c.quality, QualityPreset.ultra);
      expect(platform.menu!.account.planLabel, '');
      expect(platform.menu!.account.pro, isTrue);

      api.status = {'signedIn': true, 'email': 'a@b.c', 'pro': false, 'access': 'none'};
      await s.refresh();
      expect(c.intensity, SnowIntensity.normal);
      expect(c.quality, QualityPreset.medium);
      c.dispose();
      s.dispose();
    });

    test('a request approved since the last check applies instead of reopening the Pro page', () async {
      final platform = FakePlatform();
      final s = service();
      api.approved = true;
      await s.start();
      await s.signIn();
      final c = OverlayController(platform: platform, account: s);
      await c.init();
      expect(s.isPro, isFalse);
      final pagesBefore = opened.length;
      api.status = {'signedIn': true, 'email': 'a@b.c', 'pro': true, 'access': 'pro'}; // approved in the bot
      platform.emit(const MenuActionEvent('intensity:blizzard'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.intensity, SnowIntensity.blizzard);
      expect(platform.menu!.account.pro, isTrue);
      expect(opened.length, pagesBefore, reason: 'no Pro page when Pro is already on');
      c.dispose();
      s.dispose();
    });

    test('a signed-in account without Pro is re-checked every couple of minutes', () async {
      final s = service();
      api.approved = true;
      await s.start();
      await s.signIn();
      expect(s.nextCheckIn, AccountService.waitingInterval);
      api.status = {'signedIn': true, 'email': 'a@b.c', 'pro': true, 'access': 'pro'};
      await s.refresh();
      expect(s.nextCheckIn, AccountService.statusInterval);
      s.dispose();
    });

    test('without a backend nothing is gated', () async {
      final platform = FakePlatform();
      final c = OverlayController(platform: platform);
      await c.init();
      platform.emit(const MenuActionEvent('intensity:blizzard'));
      await Future<void>.delayed(Duration.zero);
      expect(c.intensity, SnowIntensity.blizzard);
      expect(platform.menu!.account.enabled, isFalse);
      c.dispose();
    });
  });
}
