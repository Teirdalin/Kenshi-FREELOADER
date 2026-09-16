# Freeloader 0.1.0 Validation

## Build And Deployment Record

- Release build `20260912-231814-256-5d4e1606`: successful VC10 x64 compile/link,
  182,344 scheduler checks passed, native contract passed. Verified mangled
  `?startPlugin@@YAXXZ`, PE32+ x64, KenshiLib and Release VC10 runtime imports.
- Installed in `E:/SteamLibrary/steamapps/common/Kenshi/mods/Freeloader` while
  Kenshi was closed. The existing `.mod` was preserved; it was not enabled in
  `data/mods.cfg`. No game launch or save modification was performed.
- DLL/PDB and build evidence: `build/releases/20260912-231814-256-5d4e1606`.
  Hash-checked deployment and prior-file backup:
  `build/deployments/20260912-231827-516-5b56218e`.
- Independent source/binary review identified that normal load/import bypasses
  `_clearAndDestroyGameWorldStuff`. The final build hooks `resetGame` as well;
  the native checker verifies both save entry points call that boundary.

## Offline

`tools/build-plugin.ps1` runs the C++ scheduler fixtures and the installed-binary
contract checker before staging the native DLL. Fixtures cover world edges,
negative coordinates, invalid inputs, direction changes, stationary cameras,
squad jumps, sampling gaps, resets, duplicate candidates and tick-counter wrap.
`build/native-contract.json` records the exact executable, KenshiLib and RVA hashes.

The plugin only installs hooks when the loaded executable's SHA-256 and key
KenshiLib mapped addresses match that checked binary. Partial hook installation
leaves prefetch disabled. The original main-thread callback always runs once.
No background plugin thread dereferences engine objects.

## Live Acceptance: Pending

1. Start Kenshi with Freeloader enabled; verify the current build stamp and
   `hooks installed` in `RE_Kenshi_log.txt`. A loader-only boot is not a travel test.
2. Load a disposable copy of a save. Walk the same long route across multiple
   sectors at normal and accelerated speed. Capture `prefetch sector` messages,
   visible pause duration, missing terrain/collision, and `worst_update_ms`.
3. Repeat with `Enabled=0` after restarting from the same save, camera position,
   mod list and route. Account for warm filesystem/navmesh caches; alternate
   enabled and disabled runs. Compare total travel time and pause/hitch duration.
4. Stop, turn back, jump between distant squads, pause manually, open menus, load
   another save, and return to the main menu. Check for unwanted unpause,
   persistent extra residency, stale requests, and stalls on resume.
5. Repeat through dense towns and with separated squads; watch RAM and whether
   extra population or resource cleanup costs outweigh fewer loading pauses.
6. With Project Cars enabled, cross regions while driving and check vehicle,
   rider, camera, terrain collision and save/reload continuity separately.

The 30-second counters count loading **updates**, not paused milliseconds, and
the maximum timing includes Freeloader plus `ZoneManager::updateMainThread`.
They do not measure whole-frame time or prove a speedup. No live game launch,
route comparison, save/reload or compatibility acceptance has been performed.
