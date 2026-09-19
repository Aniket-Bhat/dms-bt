# AGENTS.md – dms-bt (DMS Bluetooth Launcher plugin)

## What this is
DankMaterialShell `launcher` plugin (QML/Quickshell). No build step, no tests, no linter.
Entrypoints: `plugin.json` → `BluetoothLauncher.qml` (logic) + `BluetoothSettings.qml`.

## Do not assume / gotchas
- All Bluetooth I/O is `bluetoothctl` via Quickshell `Process` + `SplitParser`. No libraries.
- `pluginId` must stay `bluetoothLauncher` — must match `plugin.json:id`, QML `pluginId`, settings keys.
- `connect-bt.sh` is legacy standalone, not invoked by plugin. Don't wire it in.
- `bkp/` is stale backup — ignore, don't edit.
- README install path `.../plugins/AnimeCalendar/` is copy-paste wrong; real dir is `.../plugins/bluetoothLauncher/` (or repo name).
- Required `plugin.json` permissions: `settings_read`, `settings_write`, `process` — plugin breaks without `process`.
- QML must stay single-file: NO `import "*.js"` in QML. DMS `reloadPlugin` appends `?t=<ms>` to the component URL (`PluginService.qml:475-478`) and Qt fails to resolve relative script imports against it → `Script ... unavailable`, reload fails. (Calculator survives only via engine script cache from startup load; any freshly-added `.js` file breaks on reload — proven 2026-09-19, even a 2-line file fails.)
- `BluetoothLogic.js` is a test-only mirror of the pure QML functions, NOT imported by QML. `tests/test_sync.js` enforces behavioral equivalence — if you change `makeDevice`/`getDeviceIcon`/`getStatusText`/`getCategoryFromIcon` in QML, update the JS mirror (or vice versa) until all suites pass.
- Repo path IS the installed plugin path (same inodes as `~/.config/DankMaterialShell/plugins/dms-bt/`) — edits apply live, but a plugin reload is still required to pick them up.

## Architecture (BluetoothLauncher.qml)
- `monitorProc` (`bluetoothctl --monitor`): source of truth for `[NEW]/[DEL]/[CHG]` device + `Controller Powered` events. Strip ANSI/prompt before parsing; restart via `monitorRestartTimer` on exit.
- Initial load: `bluetoothctl devices Paired` → serial `bluetoothctl info <MAC>` queue (`_infoQueue`/`_currentInfoDevice`, one `Process` reused).
- Actions: one `Process` per op — `connect/disconnect/remove/pair`, `scan on/off`, `power on/off`. Success toasts come from monitor events, not `onExited` (only errors there).
- Scan: `startPairingMode()` powers on, runs `devices` + holds discovery via `bluetoothctl --timeout <dur+5> scan on` for `countdownDuration` (default 5s, clamped 3–30s in Settings), placeholder MAC `__scanning__`. The holder must STAY RUNNING: plain one-shot `scan on` exits immediately, BlueZ drops the session (`Discovering` flips to `no`), scans silently find nothing but cache. Do NOT use `btmgmt find` — needs root for the mgmt socket, dies silently as user (proven 2026-09-19).
- Filter: only `paired || scanning || _discoveredMacs` shown; unpaired shown as `[ Name ]` with `pair:<MAC>` action.

## Verify
- Unit tests (zero deps): `node tests/test_parse.js && node tests/test_devices.js && node tests/test_sync.js` (60 tests total; must all exit 0)
- `BluetoothLogic.js` must stay shim-loadable: `.pragma library` + top-level functions only, no `module.exports`/`require` (breaks `tests/load-logic.js`).
- Reload after edits: `dms ipc call plugin-scan reload bluetoothLauncher`, then confirm clean: `journalctl --user --since "2 minutes ago" -g bluetoothLauncher` shows no `component error`, and `dms ipc call plugin-scan list | grep bluetooth` shows `loaded`.
- QML shell (Processes/toasts) is manual-only: enable in Settings → Plugins → Bluetooth, then `dms ipc call launcher openQuery bt`. Needs live adapter + `bluetoothctl` (5.87 here); headless CI can't test it.