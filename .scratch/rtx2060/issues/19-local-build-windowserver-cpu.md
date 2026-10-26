# Local build costs WindowServer more CPU than stock

Type: task
Status: resolved
Assignee: H-Sami
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

## Progress

2026-10-26, claimed on Tahoe. The local build is installed (WindowServer up since 17:24, the boot the local-cold run
measured).

- **The extra CPU is shader translation, not frame work.** The run's own WindowServer spindumps
  (`raw/desktop/<scenario>/WindowServer.spindump.txt*`): the main thread costs the same on both (drag-small 5.67 s
  local, 5.81 s stock, over 8 s). The difference is the `com.apple.coreanimation.pipelines` queue: drag-small 7.99 s
  local against none on stock, drag-15 2.30 / 0.22, drag-large 1.54 / none, dock-minimize 2.67 / 0.22,
  Mission Control 5.57 / 0.44. Its stack is CA's async pipeline build → `-[NVMTLLibrary newFunctionWithName:
  constantValues:error:]` → `nvmtl_translate_with_fc_cached` → a full translation in `libnvmtl_translate`: cache misses.
- **Why they miss**: an SPIR-V cache entry's name carries the translator's tag, the SHA-256 of
  `libnvmtl_translate.dylib` (`nvmtl_translator_cache_tag`, `plugin/NVMTLLibraryLoad.m`), and the first lookup sweeps
  out every other tag's entries. The local translator is a different file, so the first session on it translates every
  CA variant as a scenario first needs it. Stock-cold ran on a cache stock had filled over earlier sessions (and
  WindowServer was 462 s old at its first scenario against 100 s for local).
- **NVK per-frame cost matches.** A user-space bench (layered IOSurface quads, blended, 2560x1440, one command buffer a
  frame; release vs local NVK through `DYLD_LIBRARY_PATH`, release vs local plugin bundle through `NM_TEST_PLUGIN`)
  gives the same CPU per frame in all four pairings, within 1% (16 layers 0.45 ms, 64 layers 0.99 ms).
  `NVMTL_ICD_LIB` does not swap NVK: the plugin has it loaded before that is read.
- The NVK builds do differ (release minos/SDK 15.5 with libc++ 19, local minos 26.0/SDK 26.5 with libc++ 21; local
  `__text` 0.6 MB larger; local keeps `__push_mthd`/`__push_immd` out of line), but nothing above points at them.

- **Warm reruns match stock.** Same install, same boot, cache now warm: three `desktop` runs
  (`~/rtx2060-runs/2026-10-26-174610-local-warm`, `-174900-local-warm2`, `-175157-local-warm-hidden`, run by Claude
  Code) give WindowServer CPU % drag-small 86.3 / 85.9 / 85.3 (stock 88.0 / 88.1), drag-15 114.7 / 114.7 / 114.9
  (116.9 / 114.4), drag-large 90.6 / 91.4 / 92.2 (88.5 / 90.7), Mission Control 13.8 / 13.8 / 14.0 (17.7 / 12.4),
  Dock minimize 27.4 / 27.2 / 26.7 (30.3 / 28.1). The pipelines queue is absent from every spindump.
- **Left over, probably not the build**: in these runs idle shows 8-12 fps (Terminal and Claude Code repainting; with
  Terminal hidden, the hide animation, Finder and HID), Safari-scroll WindowServer CPU 48-52% against 41-43, and
  drag-large 84 fps against 87-88. The owner's local-cold run, on the same build, had idle 0.2 fps, Safari 41.8% and
  drag-large 86.75 fps, so these follow who ran the harness and when, not the build.
- **Still open**: drag-small fps is 105-107.5 in all three warm runs against 114.6-117.3 on stock, at equal CPU. The
  local-cold run (102) can't separate it from the translation load. A run on a fresh boot with the cache warm settles it.

## Answer

There's nothing to fix in the build: the gap was a measurement artifact. On a translator it hasn't seen, the plugin's
SPIR-V cache starts empty. Entry names carry the SHA-256 of `libnvmtl_translate.dylib`, and the first lookup deletes
other builds' entries. So the first session after installing a different translator retranslates every Core Animation
shader variant on WindowServer's `com.apple.coreanimation.pipelines` queue, as each scenario first needs it: up to a
full core (drag-small 8.0 s of 8). Stock-cold ran on a cache stock had filled in earlier sessions. With the cache
warm, the local build's WindowServer CPU matches stock in every scenario listed above. Per-frame work (WindowServer's
main thread, and NVK and the plugin in a user-space bench) matches too. `build/rtx2060/build.sh` stays as it is.

For measuring: any translator change (rebuild, re-sign, upstream update) costs this once, on the first session.
Comparing builds means one warm-up pass of the same scenarios first, or reading the pipelines queue in the spindumps
(`coreanimation.pipelines` CPU above a few tenths of a second means a cold cache). drag-small fps (105-107 against
115-117, equal CPU) is still open. It goes to [Choose the WindowServer per-frame fixes](12-windowserver-frame-fixes.md)
as something to recheck on a fresh-boot warm run before it's counted as a regression.
