# WindowServer's frame cost while compositing

Type: research
Status: resolved
Blocked by:

## Question

Why does WindowServer spend about 20 ms of CPU per frame while a window moves, whatever the window size and refresh
rate (upstream #356)? Which parts of the plugin's path for WindowServer put that time on its thread: command buffer
encoding, submission, the completion wait before `commitAndWaitUntilSubmitted` returns, event waits versus polling,
dirty-only bindings, surface publication, the flip latch?

At 180 Hz a frame has 5.5 ms. The answer should name the candidates in code, say what the NvGfx fork changed to reach
about 145 flips/s, and say what can only be settled by profiling on Tahoe.

## Answer

The roughly 20 ms is a fixed CPU cost in the plugin while it encodes and commits each WindowServer frame, not GPU
time, flip latency or work per pixel. That matches #356: it doesn't change with window size or refresh rate, grows
with the number of open windows, no flips are missed, and the flip wait is 0.25–3.3 ms. (Code reading of v2.5.5;
nothing profiled on Tahoe.)

- Per draw: sampler-variant selection takes a lock and a lookup (`NVMTLObjects.m:2728-2787`); `setRenderPipelineState`
  always rebinds (`NVMTLObjects.m:2942`); a new descriptor set is built whenever bindings change
  (`nvmtl_vk.c:2916-3128`; #196 put about 1 ms per update there).
- Per texture bind: `nvmtl_surface_pending_write` takes the global command-buffer class lock and builds an NSString
  key (`NVMTLEventSync.m:46-63`); the worker and the submit-ahead pass contend for the same lock.
- Per IOSurface wrapper: VRAM-backed wrappers are never cached (`NVMTLDevice.m:958-1042`), so each pays a full import
  (kernel escape, RM duplicate, GPU address map, image alias; `nvmtl_vk.c:2020-2056`).
- Waiting: `commitAndWaitUntilSubmitted` waits until scheduled, which gets stuck behind the worker's fence wait whenever
  submit-ahead refuses a part (for example one with host copies).
- Ruled out as the main cause: the flip latch (it runs on NVAccel's swap worker) and polling (WindowServer already
  waits on events). The 2060-specific risk is the copy path when BAR1 runs short (How BAR1 is spent), the only
  candidate that grows with resolution.
- NvGfx: `18996e2` (skip repeated pipeline set), `c73ea10` (remember the sampler variant) and `bd09e42` (cheaper writer
  key, off the global lock) all apply and are not in v2.5.5. `37f2af4` does nothing for stock WindowServer;
  `4b3bdd5` changed little. Their 145–148 flips/s is confounded (power limit 50→115 W, upstream changes, no
  per-commit measurement).
- Candidate levers: port the three NvGfx changes, cache VRAM IOSurface wrappers, cut descriptor churn per layer, let
  submit-ahead take parts with host copies, batch the kernel escapes made per surface at commit, keep the composited
  frame in VRAM.
- Profiling plan for Tahoe (more than 5 min after login, 8 s title-bar drag): `sudo spindump WindowServer 6`,
  Instruments Time Profiler + System Trace, `debug.nvaccel_*`/`debug.nvrmfb_*` deltas, one-at-a-time A/B via
  `/Library/GPUBundles/nvmtl/nvrm610.conf` (release builds strip env vars); vary window count (1/5/15), refresh
  (60/180 Hz) and window size. Settles: the split by thread between encode, commit, wait and kernel copy, class-lock
  contention, how often wrappers are rebuilt, and the stock drag rate on this machine.

Findings: branch `research/windowserver-frame-cost`, file `research/windowserver-frame-cost.md`.
