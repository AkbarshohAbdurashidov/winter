import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Backend endpoint, set at build time:
///   `--dart-define=WINTER_API_URL=https://europe-west1-PROJECT.cloudfunctions.net/app`
/// Empty = account features off (the free app works without a backend).
const String kWinterApiUrl = String.fromEnvironment('WINTER_API_URL');
const String kWinterApiKey = String.fromEnvironment('WINTER_API_KEY'); // optional; not needed for Firebase
const String kAppVersion = String.fromEnvironment('WINTER_VERSION', defaultValue: '1.0.0');

/// What the backend says about this computer's account.
@immutable
class ProStatus {
  const ProStatus({
    this.signedIn = false,
    this.email,
    this.pro = false,
    this.access = 'none',
    this.expiresAt,
    this.upgradeUrl,
    this.accountUrl,
    this.checkedAt,
  });

  final bool signedIn;
  final String? email;
  final bool pro;

  /// pro | none
  final String access;
  final DateTime? expiresAt;
  final String? upgradeUrl;
  final String? accountUrl;
  final DateTime? checkedAt;

  /// A cached "Pro" answer stays valid offline for this long.
  static const offlineGrace = Duration(days: 14);

  /// Pro, also when the backend can't be reached for a while.
  bool proAt(DateTime now) {
    if (!pro) return false;
    // Pro given until a date ends then, online or not.
    if (expiresAt != null && expiresAt!.isBefore(now)) return false;
    return checkedAt == null || now.difference(checkedAt!) < offlineGrace;
  }

  /// Shown after "Winter Pro" in the menu: empty, or the end date.
  String get label {
    final e = expiresAt?.toLocal();
    if (!pro || e == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return 'until ${e.year}-${two(e.month)}-${two(e.day)}';
  }

  factory ProStatus.fromJson(Map<String, Object?> j) => ProStatus(
        signedIn: j['signedIn'] == true,
        email: j['email'] as String?,
        pro: j['pro'] == true,
        access: (j['access'] as String?) ?? 'none',
        expiresAt: DateTime.tryParse((j['expiresAt'] as String?) ?? ''),
        upgradeUrl: j['upgradeUrl'] as String?,
        accountUrl: j['accountUrl'] as String?,
        checkedAt: DateTime.tryParse((j['checkedAt'] as String?) ?? ''),
      );

  Map<String, Object?> toJson() => {
        'signedIn': signedIn,
        'email': email,
        'pro': pro,
        'access': access,
        'expiresAt': expiresAt?.toIso8601String(),
        'upgradeUrl': upgradeUrl,
        'accountUrl': accountUrl,
        'checkedAt': checkedAt?.toIso8601String(),
      };
}

/// Minimal transport so tests can fake the backend.
abstract interface class AccountApi {
  Future<Map<String, Object?>> post(String path, Map<String, Object?> body);
}

class HttpAccountApi implements AccountApi {
  HttpAccountApi(this.baseUrl, {this.apiKey = ''});
  final String baseUrl;
  final String apiKey;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 10);

  @override
  Future<Map<String, Object?>> post(String path, Map<String, Object?> body) async {
    final req = await _client.postUrl(Uri.parse('$baseUrl$path'));
    req.headers.contentType = ContentType.json;
    if (apiKey.isNotEmpty) {
      req.headers.set('apikey', apiKey);
      req.headers.set('Authorization', 'Bearer $apiKey');
    }
    req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 20));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) throw HttpException('HTTP ${res.statusCode}: $text');
    return (jsonDecode(text) as Map).cast<String, Object?>();
  }
}

/// Persisted account state shared by all screens' engines:
/// `<app support>/Winter/account.json`.
class AccountStore {
  AccountStore(this.file);

  factory AccountStore.standard() {
    final env = Platform.environment;
    final String dir;
    if (Platform.isWindows) {
      dir = '${env['APPDATA'] ?? env['USERPROFILE'] ?? '.'}\\Winter';
    } else if (Platform.isMacOS) {
      dir = '${env['HOME'] ?? '.'}/Library/Application Support/Winter';
    } else {
      dir = '${env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config'}/winter';
    }
    return AccountStore(File('$dir${Platform.pathSeparator}account.json'));
  }

  final File file;

  Map<String, Object?> read() {
    try {
      return (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  void write(Map<String, Object?> data) {
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(data));
      tmp.renameSync(file.path); // atomic: other engines never read half a file
    } catch (e) {
      debugPrint('Winter: could not save account: $e');
    }
  }
}

typedef UrlOpener = Future<void> Function(String url);

Future<void> openInBrowser(String url) async {
  if (Platform.isMacOS) {
    await Process.run('open', [url]);
  } else if (Platform.isWindows) {
    await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
  } else {
    await Process.run('xdg-open', [url]);
  }
}

/// Sign-in (device-code flow through the browser), Pro status and anonymous
/// usage heartbeats.
///
/// Only the owner (the first screen's engine) talks to the network and
/// writes the store; other screens follow the store.
class AccountService extends ChangeNotifier {
  AccountService({
    required this.owner,
    AccountApi? api,
    AccountStore? store,
    UrlOpener? openUrl,
    DateTime Function()? clock,
  })  : _api = api ?? (kWinterApiUrl.isEmpty ? null : HttpAccountApi(kWinterApiUrl, apiKey: kWinterApiKey)),
        _store = store ?? AccountStore.standard(),
        _openUrl = openUrl ?? openInBrowser,
        _clock = clock ?? DateTime.now;

  final bool owner;
  final AccountApi? _api;
  final AccountStore _store;
  final UrlOpener _openUrl;
  final DateTime Function() _clock;

  String _installId = '';
  String? _token;
  ProStatus _status = const ProStatus();
  bool _linking = false;
  String? _lastError;
  Timer? _statusTimer;
  Timer? _heartbeatTimer;
  Timer? _followTimer;
  String _storeSnapshot = '';

  static const statusInterval = Duration(minutes: 30);
  static const heartbeatInterval = Duration(hours: 6);
  static const linkTimeout = Duration(minutes: 15);
  Duration pollInterval = const Duration(seconds: 3);

  bool get enabled => _api != null;
  bool get signedIn => _token != null && _status.signedIn;
  bool get linking => _linking;
  ProStatus get status => _status;
  String? get lastError => _lastError;
  bool get isPro => _status.proAt(_clock());
  String get installId => _installId;

  Future<void> start() async {
    _load();
    if (!enabled) return;
    if (owner) {
      if (_installId.isEmpty) {
        _installId = _randomHex(24);
        _save();
      }
      unawaited(heartbeat(launch: true));
      unawaited(refresh());
      _statusTimer = Timer.periodic(statusInterval, (_) => refresh());
      _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => heartbeat());
    } else {
      _followTimer = Timer.periodic(const Duration(seconds: 10), (_) => _follow());
    }
  }

  void _load() {
    final data = _store.read();
    _storeSnapshot = jsonEncode(data);
    _installId = (data['installId'] as String?) ?? '';
    _token = data['token'] as String?;
    final s = data['status'];
    _status = s is Map ? ProStatus.fromJson(s.cast<String, Object?>()) : const ProStatus();
    if (_token == null) _status = ProStatus(upgradeUrl: _status.upgradeUrl, accountUrl: _status.accountUrl);
  }

  void _save() {
    final data = {'installId': _installId, 'token': _token, 'status': _status.toJson()};
    _storeSnapshot = jsonEncode(data);
    _store.write(data);
  }

  /// Non-owner screens pick up changes made by the owner.
  void _follow() {
    final data = _store.read();
    if (jsonEncode(data) == _storeSnapshot) return;
    _load();
    notifyListeners();
  }

  /// Re-reads the shared store now (e.g. after a menu action on any screen).
  void reloadFromStore() {
    if (!owner) _follow();
  }

  Future<void> heartbeat({bool launch = false}) async {
    final api = _api;
    if (api == null || !owner) return;
    try {
      await api.post('/heartbeat', {
        'installId': _installId,
        'platform': Platform.isMacOS ? 'macos' : Platform.isWindows ? 'windows' : Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'appVersion': kAppVersion,
        'launch': launch,
        if (_token != null) 'token': _token,
      });
    } catch (e) {
      debugPrint('Winter: heartbeat failed: $e');
    }
  }

  /// Asks the backend for the current Pro status. Keeps the cached status
  /// when offline.
  Future<void> refresh() async {
    final api = _api;
    if (api == null || !owner) return;
    try {
      final j = await api.post('/status', {if (_token != null) 'token': _token});
      final next = ProStatus.fromJson(j);
      if (_token != null && !next.signedIn) _token = null; // device signed out remotely
      _status = next;
      _lastError = null;
      _save();
      notifyListeners();
    } catch (e) {
      _lastError = '$e';
      debugPrint('Winter: status check failed: $e');
    }
  }

  /// Opens the browser to sign in; this app receives its token once the
  /// user approves. [next] = 'upgrade' continues to the Pro request page.
  Future<void> signIn({String? next}) async {
    final api = _api;
    if (api == null || !owner || _linking) return;
    _linking = true;
    _lastError = null;
    notifyListeners();
    try {
      final code = _randomCode();
      final start = await api.post('/link/start', {
        'installId': _installId,
        'code': code,
        'next': ?next,
      });
      await _openUrl(start['url'] as String);
      final deadline = _clock().add(linkTimeout);
      while (_clock().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        Map<String, Object?> r;
        try {
          r = await api.post('/link/poll', {
            'code': code,
            'installId': _installId,
            'platform': Platform.isMacOS ? 'macos' : Platform.isWindows ? 'windows' : Platform.operatingSystem,
          });
        } catch (e) {
          continue; // transient network error: keep waiting
        }
        if (r['status'] == 'approved') {
          _token = r['token'] as String;
          _status = ProStatus(signedIn: true, email: r['email'] as String?);
          _save();
          await refresh();
          unawaited(heartbeat());
          return;
        }
        if (r['status'] == 'expired') break;
      }
      _lastError = 'Sign-in expired';
    } catch (e) {
      _lastError = '$e';
      debugPrint('Winter: sign-in failed: $e');
    } finally {
      _linking = false;
      notifyListeners();
    }
  }

  void cancelSignIn() {
    // The poll loop ends at its deadline; the UI just stops showing it.
    _linking = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    final api = _api;
    if (api == null || !owner) return;
    final token = _token;
    _token = null;
    _status = ProStatus(upgradeUrl: _status.upgradeUrl, accountUrl: _status.accountUrl);
    _save();
    notifyListeners();
    if (token != null) {
      try {
        await api.post('/signout', {'token': token});
      } catch (_) {}
    }
  }

  /// "Get Winter Pro": straight to the Pro request page when signed in, otherwise
  /// sign in first and continue to it in the browser.
  Future<void> upgrade() async {
    if (!enabled || !owner) return;
    if (_token == null) return signIn(next: 'upgrade');
    final url = _status.upgradeUrl;
    if (url != null) await _openUrl(url);
  }

  Future<void> openAccount() async {
    if (!enabled || !owner) return;
    final url = _status.accountUrl;
    if (url == null) return;
    await _openUrl(url);
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _heartbeatTimer?.cancel();
    _followTimer?.cancel();
    super.dispose();
  }

  static final _rng = Random.secure();
  static String _randomHex(int bytes) =>
      List.generate(bytes, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  static String _randomCode() =>
      base64Url.encode(List.generate(32, (_) => _rng.nextInt(256))).replaceAll('=', '');
}
