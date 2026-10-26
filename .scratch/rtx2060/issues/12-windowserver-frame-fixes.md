# Choose the WindowServer per-frame fixes

Type: grilling
Status: resolved
Blocked by:

## Question

Which of the levers in [WindowServer's frame cost while compositing](07-windowserver-frame-cost.md) go into the
spec, in what order, so a WindowServer frame fits in 5.5 ms at 180 Hz with no frame gap over 11 ms during drag, Dock
and Mission Control?

Candidates: the NvGfx changes `18996e2` (skip a repeated pipeline set), `c73ea10` (remember the sampler variant) and
`bd09e42` (cheaper writer key, off the global lock); mickys' descriptor-mask fix; caching VRAM IOSurface wrappers;
cutting descriptor churn per layer; letting submit-ahead take parts with host copies; batching per-surface kernel
escapes at commit; keeping the composited frame in VRAM. Settle with the baseline's profile: the split by thread
between encoding, commit, the scheduled wait and the kernel copy.

## Answer

The baseline's spindumps settle it (stock-warm drag-15-windows, 18.8 ms of WindowServer CPU per frame; full split in
`profiles/2026-10-26-stock-warm-windowserver-split.md`). Main thread: WindowServer and Core Animation's own work 5.8 ms,
descriptor set building 3.1, VRAM IOSurface imports 2.9 (never cached; each pays four kernel calls and an
`open("/dev/null")`), other encoding 1.9, commit and wait 0.4, `pending_write` 0.2. The worker spends ~2.6 ms
a frame freeing those same imports (`nvRmApiFree`), mostly NVRM zeroing GPU page tables. The sampler-variant lookup,
the pipeline rebind and the per-surface kernel calls at commit are near zero. Dock sweep is not CPU-bound (main
thread 85% idle).

The spec:

- **Targets** (warm runs, against step 0): every drag scenario, 15 windows included, holds 180 Hz: WindowServer's
  main thread under 5.5 ms per frame and no gap over 11 ms within the burst. Exit only when that holds. Since
  WindowServer's own work alone is 5.8 ms in drag-15-windows, the spec has to find out what of it the driver causes;
  if some of it proves to be WindowServer's alone, the spec reports that with evidence and the owner decides, rather than the target being relaxed in the spec.
- **Method**: one lever per commit, no runtime toggles; a `--warmup` pass then a measured `--only desktop` run after
  each, logged in the spec. Guard: no desktop scenario over 3% worse in fps or WindowServer CPU per frame. NvGfx and
  mickys changes are cherry-picked as they are.
- **Step 0**: add `--warmup` to the harness; recheck drag-small on a fresh boot (to `diagnosing-bugs` if still low);
  record the local build's warm baseline.
- **Step 1**: cache VRAM IOSurface imports (buffer and image alias) in a strong map keyed by surface ID, plane and
  format, holding a retain on the IOSurface; each commit sweeps entries only the cache still holds, cap ~512 with LRU.
  Wrappers become views on the cached import. Drop the per-import `open("/dev/null")` in the same commit. Refusal,
  `nvaccel_vm_*` and VRAM counters must not rise. Today's cache (`plugin/NVMTLDevice.m`) is weak and keeps only
  failed imports.
- **Step 2**: mickys' descriptor-mask fix. **Step 3**: NvGfx `bd09e42`.
- **Step 4**: re-profile and loop on the largest remaining cost (main or worker thread) until the exit holds. Breaking
  down WindowServer's own 5.8 ms is part of the loop, not a side check: IOSurface lock/seed traffic, waits blamed on
  Core Animation, slower CA paths chosen because of what the plugin reports. Kext levers become tickets blocked by
  [Make NVRM buildable](18-make-nvrm-buildable.md).
- **Out**: NvGfx `18996e2` and `c73ea10` (measured ~0), batching kernel calls at commit (~0.1 ms), NVRM page-table
  zeroing (kext; the cache removes most calls). Keeping the composited frame in VRAM and submit-ahead with host copies
  belong to [Choose the surface-memory strategy for a 256 MB BAR1](10-surface-memory-strategy.md) and
  [Choose the surface upload and readback design](11-surface-upload-design.md).
- Dock frame rate gets its own ticket: [Why the Dock misses 180 Hz while idle](20-dock-frame-rate.md).
