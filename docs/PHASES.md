# Phase status

## Phase 1 — Transparent overlay + basic snow ✅ (macOS verified, Windows unverified)

### Done and verified on macOS (Apple Silicon, 2560×1600 Retina, 60 Hz, release build)
- Borderless, transparent, always-on-top window covering the main screen; refits on display changes.
- Click-through (`ignoresMouseEvents`); never takes focus; visible on all Spaces; no Dock icon.
- Menu-bar menu: pause/resume, snowfall (light/normal/heavy/blizzard), quality preset,
  position (above windows / on desktop behind windows), performance HUD, quit.
- Snow engine: 3 depth layers (far/mid/near), size-weighted terminal velocity, per-flake sway,
  wind with meander, random gusts and spatial turbulence; horizontal wrap; graceful
  retirement when density drops; bokeh sprite for near flakes.
- Rendering: one `drawRawAtlas` per layer, procedurally generated sprite atlas, zero per-frame
  allocation in steady state, widget tree never rebuilt per frame.
- Rendering stops while paused, while the window is fully occluded, and while the screens sleep.
- Unit tests: density scaling, quality caps, 2-minute blizzard stability, graceful retirement,
  render-buffer consistency, wind bounds and gusts (`flutter test`: 8 passing).

### Measurements (CPU = % of one core from consumed CPU time over 20 s)
| Config | CPU | RSS | Frame cost (HUD) |
|---|---|---|---|
| Paused | 0.6 % | 65 MB | — |
| Ultra Low (300 flakes cap, 30 FPS) | 15–20 % | 67 MB | — |
| Medium / normal (~600 flakes, 60 FPS) | 14–23 % | 69 MB | — |
| Ultra / blizzard (1,792 flakes, 60 FPS) | 15–23 % | 68 MB | UI 0.6 ms, raster 0.9 ms |

Run-to-run noise is about ±5 points (other apps were active during measurement).

Findings:
- Simulation and drawing are cheap (<1.5 ms per frame even in a blizzard). The CPU cost is mostly a
  **fixed per-frame engine/compositor cost** of animating a full-screen transparent window, so
  particle count barely changes it.
- Sleeping between frames with a `Timer` to cap FPS **doubled** CPU (29.6 % vs 15.4 % at Ultra Low),
  apparently because the macOS display link is torn down and restarted each frame. The scheduler
  now stays on vsync and skips work instead.
- Result: the 30 FPS cap currently saves very little CPU. **Phase 2 must lower the fixed cost**
  (candidates: native frame throttling of the display link, lower-resolution rendering surface
  on weak GPUs, measuring WindowServer cost as well as our process).

### Written, not yet verified
- **Windows runner** (`windows/runner/flutter_window.cpp`, `win32_window.cpp`): layered topmost
  click-through popup window, DWM frame extension for transparency, tray icon menu, display/DPI
  refit, sleep and display-off pause. Written on macOS and **never compiled**. Flutter's
  per-pixel transparency on Windows in particular must be verified on real hardware.

### Known limitations (planned for later phases)
- Main screen only (multi-monitor: Phase 6).
- Settings are not persisted yet; defaults can be set at build time for profiling:
  `--dart-define=WINTER_QUALITY=ultraLow|low|medium|high|ultra`,
  `WINTER_INTENSITY=light|normal|heavy|blizzard`, `WINTER_STATS=true`, `WINTER_START_PAUSED=true`.
- "On desktop" mode on Windows uses the bottom of the z-order (above desktop icons); the proper
  WorkerW placement is Phase 6.
- No accumulation, scene, or interaction yet (Phases 3–5).

## Desktop snow world (user request, 2026-11-14) — macOS verified, Windows not started

Built ahead of the original phase order, at the user's request:
- **Snow piles on app windows, the Dock and the screen floor.** Snow lands only where an edge is
  visible (windows in front and the Dock block it), settles into mounds within an angle of
  repose, slides off the ends as clumps, follows windows as they move (positions polled at 20 Hz
  on a background queue and extrapolated between polls), and resamples on resize.
- **Shake a window hard** → its snow (and any snowballs on it) is thrown off; clumps re-land on
  surfaces below.
- **Snowballs**: press on a pile and drag; the ball collects snow from every pile it touches
  and grows. Release → it falls and rests on the surface below, or on another ball.
  **Three stacked balls become a snowman**: arms, coal buttons, eyes and mouth, carrot nose,
  scarf and top hat appear one after another. Drag a snowman to move it.
- **Icicles** hang from the menu bar's bottom edge (from the top edge while an auto-hidden menu
  bar is out of view; they follow it as it slides in). They grow slowly (5–25 min), the longest
  stop a little above mid-screen, water drips from the tips and splashes. **Click an icicle** →
  it snaps, falls, and shatters into bouncing shards and ice dust on the Dock (or the floor).
- Click-through everywhere except snow piles, snowballs/snowmen and icicles (native 30 Hz cursor
  check against hit regions sent from Dart). The overlay is a non-activating panel, so clicking
  snow never takes focus from the user's app.
- Overlay level raised to the status-bar level so it draws above the Dock and the menu bar.
- App sandbox disabled: required to read the Dock's preferences (Dock width estimate).

Measured (Blizzard, Medium quality, 60 FPS, 1,218 flakes, icicles + piles active):
26.8 % CPU (one core), 49 MB RSS; UI 0.6 ms, raster 1.1–1.8 ms per frame. Drawing icicles and piles
as vector paths every frame first cost 52 % CPU; they are now baked into GPU images and re-baked
only when their shape changes.

Tests: 16 passing (pile physics, occlusion, snowball growth, snowman formation, shake, icicle break).

Limitations:
- The Dock's width is an estimate (macOS doesn't expose it); left/right Docks get no Dock snow.
- Primary screen only.
- Windows: none of this desktop integration exists on Windows yet (needs EnumWindows tracking,
  taskbar instead of Dock, hit-region click-through). The Dart side is platform-neutral.
- Snowmen and piles aren't saved between launches.
