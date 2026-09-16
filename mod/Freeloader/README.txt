# Freeloader

Freeloader is an experimental RE_Kenshi plugin that attempts to reduce region loading pauses by starting some loading ahead of camera movement.

It tracks the direction the camera is moving and requests the next likely region through Kenshi's existing background loader.

It keeps up to six predicted sector reservations at once, stops making new requests below 2 GiB available RAM, and respects the configured active-zone limit. Camera jumps and world resets clear the current prediction.

This first version is mainly aimed at reducing pauses while moving around the map.

It won't remove every loading pause. Kenshi can still stop while waiting on terrain, and loading buildings, NPCs, physics, navmesh data, or cleaning up resources can still cause stuttering.

Initial save loading and normal pausing are unchanged.

Preloading may also cause towns and NPCs to become active earlier than normal and will use some additional memory.

Version 0.1.0 is tested against the Steam version of **Kenshi 1.0.65**, using **RE_Kenshi 0.3.5** and **KenshiLib 0.5.0**.

## Installation

Place the contents of:

```text
mod/Freeloader
```

into:

```text
Kenshi/mods/Freeloader
```

Then enable `Freeloader.mod` in the Kenshi launcher.

RE_Kenshi must already be installed.

Restart Kenshi after changing the DLL or INI.

Unsupported Kenshi executables will cause the plugin to disable itself.

The included `Freeloader.mod` is the existing empty FCS mod used for loading the plugin.

To disable Freeloader, either disable it in the Kenshi launcher or set:

```ini
Enabled=0
```

in `Freeloader.ini`.

## Settings

`Freeloader.ini` is located beside the DLL.

* `Enabled=1`
  Enables or disables Freeloader. Requires a restart.

* `Diagnostics=1`
  Logs preload requests and 30-second summaries to `RE_Kenshi_log.txt`.

* `LookAheadDistance=1800`
  Base camera lookahead distance. Limited between 500 and 3500 game units. Camera speed can increase this up to a maximum total of 4000.

* `MaxActiveZones=32`
  Stops new preload requests once Kenshi reaches this many active zones. Limited between 12 and 64. Existing player and base zones are never removed to make room.

* `RequestIntervalMs=500`
  Minimum time between preload requests. Limited between 250 and 5000 milliseconds.

The defaults should be fine for most people.

## Building

For anyone building it themselves:

```powershell
./tools/build-plugin.ps1
./tools/deploy.ps1
```

Uses the shared VC++ 2010 x64 toolchain and KenshiLib dependencies from the parent Kenshi workspace.

Python requires:

```text
pefile
capstone
```

The build checks the installed Kenshi executable and expected RVA layout, runs the scheduler tests, then builds the Release DLL and matching PDB.

Build records also include binary hashes.

Kenshi needs to be closed before deployment.

The automated tests verify the scheduler and the expected loading hooks for the tested Kenshi executable. They don't prove that Freeloader will improve performance on every system.

See [validation](docs/VALIDATION.md) for live testing and [loading evidence](docs/LOADING.md) for the loading mechanism.
