import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../account/account_service.dart';
import '../engine/render/flake_atlas.dart';
import '../engine/render/world_renderer.dart';
import '../features/overlay/overlay_controller.dart';
import '../features/overlay/overlay_view.dart';
import '../platform/overlay_platform.dart';
import 'diagnostics.dart';

/// Composition root: creates dependencies and hosts the overlay.
class WinterApp extends StatefulWidget {
  const WinterApp({super.key, this.platform, this.diagnosticsPath, this.screenId = 0, this.account});

  /// Which display this engine draws (0 = first). Only screen 0 talks to the
  /// account backend; the others follow its saved state.
  final int screenId;

  /// Injected for tests; defaults to the real account service.
  final AccountService? account;

  /// When set, a JSON status snapshot is written here every few seconds.
  final String? diagnosticsPath;

  /// Injected for tests; defaults to the MethodChannel implementation.
  final OverlayPlatform? platform;

  @override
  State<WinterApp> createState() => _WinterAppState();
}

class _WinterAppState extends State<WinterApp> {
  late final OverlayPlatform _platform = widget.platform ?? MethodChannelOverlayPlatform();
  late final AccountService _account = widget.account ?? AccountService(owner: widget.screenId == 0);
  late final OverlayController _controller = OverlayController(platform: _platform, account: _account);
  ui.Image? _atlas;
  WorldRenderer? _renderer;
  DiagnosticsWriter? _diagnostics;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final atlas = await FlakeAtlas.build();
    if (!mounted) {
      atlas.dispose();
      return;
    }
    setState(() => _atlas = atlas);
    final path = widget.diagnosticsPath;
    if (path != null) {
      _diagnostics = DiagnosticsWriter(path, _controller, _platform)..start();
    }
    await _controller.init();
    await _account.start();
  }

  @override
  void dispose() {
    _diagnostics?.dispose();
    _controller.dispose();
    if (widget.account == null) _account.dispose();
    _platform.dispose();
    _renderer?.dispose();
    _atlas?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final atlas = _atlas;
    final dpr = View.of(context).devicePixelRatio;
    if (atlas != null && (_renderer == null || _renderer!.devicePixelRatio != dpr)) {
      _renderer?.dispose();
      _renderer = WorldRenderer(atlas, dpr);
    }
    // No MaterialApp: the overlay needs no theme/navigator, and nothing may
    // paint an opaque background.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: const TextStyle(fontFamily: '.SF UI Text', fontSize: 12),
        child: atlas == null
            ? const SizedBox.expand()
            : OverlayView(controller: _controller, atlas: atlas, renderer: _renderer!),
      ),
    );
  }
}
