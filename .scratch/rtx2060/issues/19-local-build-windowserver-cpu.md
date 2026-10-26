# Local build costs WindowServer more CPU than stock

Type: task
Status: open
Blocked by:

## Question

Why does the local build from [Build the fork from source on Tahoe](03-build-fork-on-tahoe.md) cost WindowServer up to
twice stock 2.5.5's CPU in desktop animations, and what change to `build/rtx2060/build.sh` brings it back to stock?

`~/rtx2060-runs/2026-10-26-172613-local-cold` against `baseline/2026-10-26-154330-stock-cold`: drag-small 88 → 186%
(and 117 → 102 fps), drag-15-windows 117 → 143%, drag-large 89 → 110%, Mission Control 18 → 82%, Dock minimize
30 → 55%. Video, launches and kernel counters match; stock repeats within a few percent. The kexts are byte-identical
or nearly so, so the cost is in what runs inside WindowServer: translator, plugin or NVK. NVK is the first suspect: no
published recipe, the 610 headers, the `nv_push.h` patch, and a dylib 0.6 MB larger than the release.

Bisect by swapping one release dylib at a time over the local install (NVK first), logging out and in, and running
`tools/rtx2060/run.sh --label <name> --only desktop --sudo`. Profile with WindowServer spindumps if the swap doesn't
settle it.

Done when the answer names the component and cause, `build.sh` is fixed and committed, and a desktop run of the fixed
build matches stock-cold's WindowServer CPU within run-to-run noise. Driven by Claude Code on Tahoe; the owner swaps
files that need root, logs out and in, and runs the harness. Use `diagnosing-bugs`.
