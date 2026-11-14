# Winter

A free desktop snow overlay for macOS and Windows. Snow falls over your desktop, piles up on
app windows and the Dock/taskbar, icicles grow from the menu bar, and you can roll snowballs
into snowmen.

## Install
- **macOS (12+, Intel and Apple Silicon):** open `Winter-<version>-macOS.dmg` and drag Winter to
  Applications. The app is not notarized: the first time, right-click Winter → **Open** → **Open**.
  Winter lives in the menu bar (❄).
- **Windows 10/11 (x64):** run `Winter-<version>-Windows-Setup.exe`. SmartScreen may warn because
  the installer is unsigned: **More info → Run anyway**. Winter lives in the system tray.

## Use
- Press on piled-up snow and drag to roll a snowball; it grows as it collects snow.
- Drop three balls on top of each other to build a snowman.
- Shake a window to knock its snow off. Click an icicle to break it.
- Menu bar / tray icon: pause, snowfall, quality, position, clear snow, quit.

## Build
```sh
flutter test
scripts/build_macos_dmg.sh                  # → dist/Winter-<version>-macOS.dmg
# Windows (on Windows): flutter build windows --release
#   iscc /DAppVersion=<version> installer\windows\winter.iss
```
CI (`.github/workflows/release.yml`) builds both installers; pushing a `v*` tag publishes a release.

See `docs/ARCHITECTURE.md` and `docs/PHASES.md`.
