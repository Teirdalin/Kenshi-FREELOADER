# Loading Evidence And Initial Design

Inspected the installed `RE_Kenshi/kenshi_x64.exe`, SHA-256
`504b362cde850d56afb1cea6f5b7b0ee014d9dd7b47e188599d91c804502cd3e`,
using KenshiLib exports and `RE_Kenshi/RVAs/Steam_1.0.65.br`. Addresses below are
mapped RVAs for inspection; runtime hooks resolve through `GetRealAddress`.

## Binary-Confirmed

- `ZoneManager::updateMainThread` (`0xa11b70`) calls `processLoading` (`0xa0e950`).
- During loading, `processLoading` checks four camera corners at X/Z +/-600. An
  absent zone or false loaded byte at `ZoneMap+0xb1` calls
  `GameWorld::togglePause(true)`. Native loading can proceed without a pause
  while the camera's required footprint is loaded.
- `activateZoneMap(ZoneMap*, iVector2, int, ZoneActivationType, float)`
  (`0xa0e1b0`) registers newly activated zones in the pending set. Range zero
  activates only that sector. The native phases handle completion.
- `loadPhase1` (`0xa0e6c0`) admits pending work even if its ordinary central-zone
  activation returns false. No plugin phase writes are needed.
- Phase 2 (`0xa0d890`) waits on pending content and synchronously populates
  buildings/residents. Phase 3 (`0xa0dbe0`) waits on physics queues before
  usage-node/navmesh and town work. Phase 4 waits on navmeshes; phase 5 can wait
  on remaining resources. Speculative and demanded loads share these barriers.
- `_activate` (`0xa0d6a0`) overwrites the chosen activation countdown at `+0xc0`.
  Freeloader renews only its tracked, desired, loaded sectors below 30 seconds,
  to 60 seconds. Longer existing reservations are preserved. Native activation
  can subsequently overwrite the same camera countdown.
- `UtilityT::getSubMapSector` (`0x9b1ec0`) uses a 64x64 grid with 4608-unit sectors
  and a 32-sector origin offset. Negative coordinates require floor semantics.
- `togglePause` (`0x787200`) preserves a user speed of zero when loading requests
  resume. It updates multiple native thread pause states, not just UI visibility.

## Plugin Behavior

Three hooks: prefetch before `ZoneManager::updateMainThread`, reset epoch before
both `GameWorld::resetGame` and `_clearAndDestroyGameWorldStuff`. The ordinary
save-load/import path uses `resetGame` and inlines cleanup, bypassing the latter
method. Each hook calls its original once; nested resets keep prefetch suspended.
Failed installation leaves the feature disabled. Session state contains numeric
coordinates and timing only; native objects are reacquired during each callback.

The predictor computes a nearby future camera sector from stable movement and
orders its 3x3 neighborhood by distance to the current camera. Admission requires
native phase zero, an already loaded local footprint with collision, available
RAM, capacity and a free reservation. Only one new sector is attempted per tick,
with at least 500 ms between attempts by default. No new prefetch is admitted
until the native loading cycle finishes. Old reservations expire naturally.

This is early native streaming, not a replacement loading engine. No pause,
loaded-state, collision, navmesh or save barrier is bypassed. The expected benefit
is a hypothesis until measured in live travel. Extra native population and
resource cleanup can offset it, especially around dense towns.

Reproduce inspection with `tools/inspect-loading.py`, for example:

```powershell
python tools/inspect-loading.py 'processLoading@ZoneManager' --size 0x5f1
python tools/verify-native.py
```

Shared references: `../Rekenshi/docs/STREAMING_AND_MOVING_OBJECTS.md`,
`HOOKING_AND_RUNTIME.md` and `BUILD_AND_PACKAGING.md`. Upstream:
[RE_Kenshi](https://github.com/BFrizzleFoShizzle/RE_Kenshi) and
[KenshiLib examples](https://github.com/BFrizzleFoShizzle/KenshiLib_Examples).
