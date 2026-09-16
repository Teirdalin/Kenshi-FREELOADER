Freeloader 0.1.0 - Experimental

Requires the supported Steam Kenshi 1.0.65 executable, RE_Kenshi 0.3.5 and
KenshiLib 0.5.0. Enable Freeloader.mod in the launcher, then start Kenshi.

Starts nearby sector loading ahead of camera travel using Kenshi's native
background loader. Requests one new sector per loading cycle and retains at
most six speculative reservations. Stops adding sectors below 2 GiB available
RAM or at the configured active-zone limit.

This first build is not yet playtested. It aims to reduce travel pauses, but
required loading pauses and main-thread hitches remain. Preloading also brings
towns/NPCs into simulation earlier and uses extra memory.

Freeloader.ini (restart after changes):
  Enabled=1               Set to 0 to disable prefetching.
  Diagnostics=1           Requests and 30-second summaries in RE_Kenshi_log.txt.
  LookAheadDistance=1800   Base prediction distance, range 500-3500 game units.
  MaxActiveZones=32        Total active-zone admission limit, range 12-64.
  RequestIntervalMs=500    Minimum request interval, range 250-5000 milliseconds.

The log should show "Freeloader: hooks installed" after startup and
"Freeloader: prefetch sector" during travel. Unsupported executables disable
prefetching. Initial save loading, user pause and terrain readiness checks
retain native behavior.

For comparison, repeat the same route/save with Enabled=0 and Enabled=1 after
restarting. Check travel pauses, frame hitches, RAM, towns and terrain collision.
Do not treat a successful boot or offline test as proof of smoother travel.

To disable, untick Freeloader.mod in the launcher or set Enabled=0 and restart.
