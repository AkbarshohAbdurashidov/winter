# Winter — Architecture & Roadmap

## Starting point (inspected 2026-11-14)
- Fresh `flutter create` template, Flutter 3.47.8 (stable), Dart 3.13.7, no third-party deps.
- macOS runner (deployment target 12.0, sandboxed), Windows runner (PerMonitorV2 manifest, links dwmapi).
- Dev machine is macOS: macOS builds are compiled and run locally; **Windows native code cannot be
  compiled here** and is marked *unverified* until built on a Windows machine.

## Key decisions
| Concern | Decision | Why |
|---|---|---|
| Package layout | One Flutter app, strict folder boundaries (`engine/` is pure Dart, no widgets) | Spec warns against fragmentation; folders can be promoted to packages later without code changes. |
| Particle storage | Struct-of-arrays `Float32List` per depth layer, fixed capacity allocated once, swap-remove compaction | Zero per-frame allocation, cache-friendly, no widget per particle. |
| Rendering | One `drawRawAtlas` call per depth layer with a procedurally generated sprite atlas | Thousands of flakes in 1–3 GPU draw calls; works on Impeller and Skia. |
| Frame pacing | Own frame scheduler (`scheduleFrameCallback` + `Timer`) instead of `Ticker` | A `Ticker` composites every vsync even if we skip work; we request frames only at the target FPS, and request **none** while paused/hidden. |
| Widget tree | Built once; repaint driven by a `Listenable` | No rebuilds per frame. |
| Native integration | Runner-level code behind a Dart `OverlayPlatform` interface, one `MethodChannel` | Low-frequency messages only (menu actions, visibility); never per-frame. |
| Windows vs macOS | Separate adapters; capabilities differ (macOS has occlusion state; Windows needs layered windows for click-through) | Spec requirement. |

## Source layout
```
lib/
  main.dart                      bootstrap only
  app/                           composition root (wires dependencies)
  core/                          tiny utilities (fast RNG)
  engine/                        pure simulation + rendering primitives (no widgets)
    weather/                     weather presets, wind field (gusts, turbulence)
    snow/                        SoA snow layers, snow system
    quality/                     quality presets/profiles
    render/                      sprite atlas, painters
    loop/                        frame scheduler (FPS cap, pause)
  performance/                   frame statistics (FrameTiming + measured FPS)
  platform/                      OverlayPlatform interface + MethodChannel impl
  features/overlay/              overlay controller (app state) + overlay view + HUD
macos/Runner/MainFlutterWindow.swift   transparent overlay window, status-bar menu, occlusion/sleep events
windows/runner/                        layered topmost click-through window, tray menu (unverified)
```

## Performance-sensitive components
1. Per-flake update loop (`SnowLayer.step`) — branch-light, typed arrays, no allocation.
2. GPU fill-rate of a full-screen transparent window — keep sprites small, avoid blur filters.
3. Compositor cost when idle — no frames scheduled while paused / occluded / screens asleep.
4. Later: snow accumulation height-map and scene layers (cache static layers into `Picture`s).

## Roadmap
1. **Overlay + basic snow** — transparent, always-on-top, click-through, layered snow, wind/gusts,
   intensity presets, FPS cap, pause, occlusion/sleep pause, stats HUD, status-bar/tray menu.
2. Adaptive quality engine (frame-time monitor, hysteresis + cooldown, Auto/Manual/Custom).
3. Cabin winter scene (layered, cached static art + animated lights/smoke/clouds/stars).
4. Physics: surface colliders, accumulation height-maps, sliding, deformation.
5. Interactions: mouse push, shovel, snowballs, snowmen + accessories.
6. Native completion: multi-monitor windows, settings window, launch at startup, persistence.
7. Profiling, tests on hardware matrix, release packaging.

## Phase status
See `docs/PHASES.md`.
