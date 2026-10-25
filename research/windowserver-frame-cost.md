# WindowServer frame cost during a window drag (ticket 07)

Question: why does WindowServer burn about 20 ms of CPU per frame while a window
moves, independent of window size and refresh rate (upstream #356), and which
parts of the plugin path put that time on WindowServer's thread? Target: RTX
2060 6 GB, 256 MB BAR1, 2560x1440 @ 180 Hz (5.56 ms per frame).

Tree read: branch `rtx2060` at v2.5.5 (`v2.5.5-1-ga217742`). All file:line
references are to that tree. The sibling finding on BAR1 and the copy path is
`origin/research/bar1-spend:research/bar1-spend.md`; it is referenced here, not
repeated. The live framebuffer is `kexts/NVRMFB/fb/nvrm-fb.cpp`
(`kexts/NVRM/fb/` is a stale copy).

## Gist

The 20 ms is a fixed per-frame CPU cost in the plugin's encode and commit path,
not GPU time, not flip latency and not per-pixel work. Three things point there:
#356 shows 0 missed flips and a flip wait of only 0.25-3.3 ms, the cost does not
move with window area or panel rate, and it rises with the number of open
windows. Spindumps show the same thing: in #196 and in the NvGfx fork's notes,
the samples land in `drawIndexedPrimitives`, descriptor snapshots, objc
retain/release/locks and per-frame IOSurface imports. The NvGfx fork got from
75-77 to 145-148 flips/s by trimming per-draw work and running the commit-time
submit-ahead pass. Only Tahoe profiling can say which candidate dominates on a
2060 and a desktop CPU. Two of the three per-draw fixes that NvGfx credits are
not in v2.5.5. The third does nothing for stock WindowServer, because
framebuffer fetch is off there.

## 1. Evidence base

### Upstream issues (read-only `gh`)

- **#356** (RTX 3060 Laptop, 2560x1440 @ 165, v2.5.3).
  - 50-57 presents/s, about 18-20 ms per frame.
  - The rate does not change with window area, shadow or refresh rate.
  - WindowServer runs at 98-103 % CPU, which is one core.
  - CPU rises with the number of open windows.
  - 0 missed and 0 skipped flips.
  - Flip wait is 0.25-3.3 ms with `flip_latch=2`, so the flip is not the
    bottleneck.
- **#356, comment by watchthelight (NvGfx author).**
  - Shipped 2.3.7 does 75-77 flips/s; their 2.4.3 fork does 145-148.
  - In older builds about a third of spindump samples were in
    `drawIndexedPrimitives`: a descriptor snapshot per draw, a fetch
    descriptor set and barrier per draw, and an IOSurface import per frame.
  - They name commits 37f2af4, 18996e2 and c73ea10, but did not measure them
    one at a time.
  - Drags in the first 2-4 minutes after login are slow (3-26 flips/s).
  - Their advice is `sudo spindump WindowServer 6`.
- **#196** (fixed in 2.1.0), profiled on 1.15.0.
  - `CGXUpdateDisplay` took 6.2 ms per update, of which:
    - 1.3 ms was the `waitUntilCompleted` inside
      `commitAndWaitUntilSubmitted`;
    - about 1 ms was NVK descriptor alloc and update
      (`nvk_AllocateDescriptorSets`, `nvk_UpdateDescriptorSets`,
      `get_sampled_image_view_desc`).
  - `nvmtl_snapshot_set_md` had 147 samples.
  - objc retain/release/msgSend plus malloc took about 640 of 6252 samples.
  - The fix (e75be1e, v2.1.0) replaced the per-frame wait with kernel
    completion marks.
- **Related issues.**
  - #352: Dock stutter at 240 and 60 Hz; flip_latch 1 vs 2 makes no difference;
    flip about 2.6 ms.
  - #314: general lag.
  - #391: stutter while Claude Desktop runs.
  - #190: low frame rate while dragging.
  - #226: the first minutes are heavy (WindowServer at 157 % while shader caches
    rebuild).
  - #370: shader translation runs on WindowServer's
    `coreanimation.pipelines` thread.

### Upstream history (local git)

- e75be1e (v2.1.0): "no per-frame WindowServer wait", the kernel surface marks.
- 40daaa6 (v2.3.4): present waits bounded to 1.25 refresh periods.
- 071110c (v2.3.7): "run the submit-ahead pass at commit while the worker
  waits". The commit message explains that WindowServer waits for its swap's
  buffer to be *scheduled*, so "compositing and the GPU took turns".
- v2.3.7 through v2.5.5 keep the same WindowServer shape: FBFETCH_WS off,
  commit-ahead on the committing thread, kernel waits on.
- The plugin commits from v2.4.3 to v2.5.5 (15 of them) are not WindowServer
  performance work.

### NvGfx fork (watchthelight-labs/NvGfx, branch `nvgfx-2.5.3`; evidence in watchthelight-labs/research `logs/watchthelight/lenovo-legion-5-15iax10/`)

| Commit | Change | Applies to stock v2.5.5 WindowServer? |
|---|---|---|
| 37f2af4 | One framebuffer-fetch descriptor set per pass and mask instead of per draw ("~1 ms per frame of window drag") | **No.** In WindowServer, fetch is off unless `NVMTL_FBFETCH_WS=1` (`plugin/nvmtl_vk.c:3200-3211`). With fetch off, `fetch_mask` is 0 and a cached zero set is used (`nvmtl_vk.c:4232-4233`). |
| 18996e2 | Skip a repeated `setRenderPipelineState:` inside a begun pass (Apple's GL-style renderer sets it before every draw) | **Yes.** Not in v2.5.5: `plugin/NVMTLObjects.m:2942` reads `ps.label`, retains and rebinds every time. |
| c73ea10 | Keep the encoder's sampler-variant pick, so there is no `@synchronized` or dictionary lookup per draw | **Yes.** Not in v2.5.5: `nvmtlSamplerPipeline` (`NVMTLObjects.m:2728-2775`) takes `@synchronized(_ps)` and does a lookup on every draw that has samplers bound. |
| bd09e42 | Surface writer key becomes a tagged NSNumber, and the census moves behind its own os_unfair_lock | **Yes.** v2.5.5 builds an NSString key and takes the global class lock on every texture bind (`plugin/NVMTLEventSync.m:46-63`). |
| 4b3bdd5 | Commit-time ahead pass moves to its own `nvmtl.ahead` queue (their I-069) | Applies, but by their own data the gain is small. |
| 9eae44d | Async upload at bind for CPU-written IOSurfaces | Apps only. WindowServer stays synchronous. |
| 2b41c23, 7e6dc68 | Per-module `newFunctionWithName` memo; WindowServer shader-cache fallback folder | Only the first minutes after login (shader cost). |

NvGfx run notes (RTX 5070 Laptop, Arrow Lake CPU):

- N-166, ahead pass off: 50-54 flips/s. This matches #356.
- N-168, stock 2.3.7: 75-77 steady, 11-26 in the early phase.
- N-167, ahead pass on its own queue: 74-78.
  - Its spindump has the worker in `vkWaitForFences` for 264 of 269 samples,
    and no wait in the commit path.
  - Their verdict is that the move "changes neither phase".
- So the commit-time ahead pass itself (on vs off) was worth about 45 %. Which
  thread runs it hardly matters.
- N-186, 2.4.3-nvgfx.1 on mains:
  - window drag 148 flips/s (145-148);
  - caanim 177;
  - `draw.encode` 1.6 µs per draw;
  - early drags 3-9 flips/s, then 99.
- NVGFX.md: "window drags about 148 fps; shipped 2.1.0 ... about 54".

The 145-148 figure has confounders:

- upstream's own 2.3.7 to 2.4.3 changes;
- every fork plugin commit together, never measured one at a time;
- the fork ran the laptop at 115 W TGP (`nvrmtgp=1`) instead of the VBIOS 50 W;
- different hardware from the 2060 setup.

Stock 2.4.x and 2.5.x drags were not measured, so nobody knows how much of the
step from 75 to 148 comes from upstream itself.

## 2. The per-frame path WindowServer takes

CoreAnimation's MetalContext encodes one or more render passes per composited
frame, calls `commitAndWaitUntilSubmitted`, and then the swap goes through the
IOAccelDisplayPipe transaction.

1. **Command buffer creation.** `commandBuffer` (`NVMTLObjects.m:~5165`) takes
   the capacity semaphore and calls `nvmtl_vk_cmd_begin`. A resource set is
   created per command buffer.
2. **Texture wrapping.**
   - `newTextureWithDescriptor:iosurface:plane:` (`plugin/NVMTLDevice.m:996-1042`)
     and `nvmtl_surface_image_create` (`NVMTLDevice.m:958-993`) wrap each
     IOSurface.
   - The cache is a strong-to-weak `NSMapTable` keyed by surface, and only
     *private* images are cached (`if (key && !t->_vramOn) [cache setObject:t
     forKey:key]`).
   - So every wrapper for a VRAM-backed surface runs a full
     `nvmtl_vk_surface_vram` (`plugin/nvmtl_vk.c:2020-2056`). Each call:
     - opens `/dev/null`;
     - imports the memory with `vkAllocateMemory`, which means the
       `NVRM_ESC_SURF_VRAM` escape, a kernel wire, NV04_SHARE, an RM DUP and a
       GPU VA map;
     - then runs `vkCreateBuffer`, binds it, and creates the image alias.
3. **Render pass begin.** `nvmtl_vk_cmd_begin_pass` (`nvmtl_vk.c:4886`) creates
   a `VkFramebuffer` per pass (around line 5019).
4. **Per draw** (`drawPrimitives` at `NVMTLObjects.m:3123`,
   `drawIndexedPrimitives` at 3376):
   - `setRenderPipelineState:` (2942): reads the label, retains, binds the
     pipeline. It does not return early when the pipeline is unchanged.
   - `setFragmentTexture:` (3101) does two things:
     - `nvmtl_surface_cpu_dump`, an `access()` check every 250 ms;
     - `nvmtl_surface_in_for_cb` (`NVMTLObjects.m:1033-1041`), which calls
       `nvmtl_surface_pending_write` (`NVMTLEventSync.m:49-63`). That takes
       `@synchronized([NVMTLCommandBuffer class])`, builds a
       `stringWithFormat:@"%u:%lu"` key and walks all queues.
   - `nvmtlSurfaceIn` (1227-1256): a seed check. A CPU-written surface is
     uploaded synchronously in WindowServer.
   - `nvmtlSamplerPipeline` (2728-2775): `@synchronized(_ps)` plus a dictionary
     lookup.
   - `nvmtlBindSamplerPipeline` (2776-2787): `nvmtl_vk_cmd_bind_pipeline`
     (`nvmtl_vk.c:5532`), `nvmtl_bind_embedded` twice, and
     `nvmtl_vk_cmd_bind_set`.
   - Descriptor snapshot: `nvmtl_snapshot_set_c` (`nvmtl_vk.c:3060-3128`) reuses
     the last set when bindings are clean and the mask is covered, and has a
     dynamic-offset fast path. Otherwise `nvmtl_snapshot_set_md` (2916-3058)
     gets a set from the batched cache (or takes `g_desc_lock` and calls
     `vkAllocateDescriptorSets`), then runs `vkUpdateDescriptorSets` with
     writes and copies. Dirty-only mode is on unless `NVMTL_NO_DIRTYONLY`
     (2177).
   - `nvmtl_bind_graphics_sets` skips identical binds.
   - The draw itself: `nvmtl_vk_cmd_draw` (5517) or
     `nvmtl_vk_cmd_draw_indexed` (5588).
5. **Render-target output.** `nvmtlSurfaceOutDirtied:` (1287-1318): a VRAM
   surface only gets a dirty mark (a kernel escape). A non-VRAM surface gets
   `IOSurfaceLock` plus `nvmtl_vk_image_read` readback.
6. **Commit.** `nvmtlSubmitWithEvents` (`NVMTLEventSync.m:~692-712`) runs four
   steps:
   1. it seals the part under the class lock;
   2. it calls `nvmtl_ws_mark_pending` (~205-240). For each surface, this runs
      `nvmtl_vk_surface_dirty` (an escape that takes the accelerator lock), then
      `nvmtl_ws_mark(sid, YES)` (another escape) under `nvmtl_ws_lock`;
   3. under the class lock, it calls `nvmtl_surface_register_writes` (64-77,
      NSString keys again) and adds the part to the pending list;
   4. it calls `nvmtl_pump_buffers` (743-800). If the worker is busy, it runs
      `nvmtl_gsub_ahead_pass()` synchronously on the committing thread with
      the class lock held (line 753; `nvmtl_commit_ahead_on` at 737,
      `NVMTL_COMMIT_AHEAD=0` turns it off).
7. **Submit-ahead / worker.**
   - `nvmtlSubmitAhead` (~545-590) submits a part early. It refuses (returns
     NO) when:
     - the part is already claimed;
     - inflight is at or above the cap (`nvmtl_gsub_cap` ~466,
       `NVMTL_GSUB_INFLIGHT`, default 16);
     - an event wait is not yet promised;
     - the part has host-pointer copies (`if (hold && part->hasHostCopies)
       return NO;`), unless `NVMTL_GSUB_HOSTPTR_LIFT` is set.
   - Otherwise the `nvmtl.execution` worker handles the part in
     `nvmtlAdvancePart` (~610-690). It claims it and calls
     `nvmtl_vk_submit_wait`, which submits and then waits on the fence
     synchronously, or `nvmtl_gsub_finish`. Then it publishes surfaces.
   - Submit itself (`nvmtl_vk_submit_begin_at`, `nvmtl_vk.c:5819-5884`) does
     `EndCommandBuffer`, `CreateFence`, takes `nvmtl_submit_mutex`, runs a
     pre-submit hook and calls `vkQueueSubmit`. In NVK this is a user-mode
     doorbell (`nvk/nvk-macos.patch` `nvrm_gsub_submit` 9028-9051, flush
     9188-9223), so it is cheap.
8. **The wait that returns control to WindowServer.**
   - `commitAndWaitUntilSubmitted` (`NVMTLObjects.m:5048-5055`) calls
     `waitUntilCompleted` only if `!nvmtl_ws_kernel_waits()`
     (`NVMTLEventSync.m:79-98`, re-probed every 1 s). By default it calls
     `waitUntilScheduled` (~5136): a condition wait on `_wasScheduled`, then
     `dispatch_group_wait(_scheduledGroup)`.
   - `_wasScheduled` is set in `nvmtlMarkScheduled` (~390), and only when the
     part is submitted (by the ahead pass or the worker) or skipped as empty.
9. **Completion on the GPU side.**
   - NVK waits: `nvkmd_nvrm_wait_block` (`nvk-macos.patch` 8341-8371) uses event
     waits for WindowServer by default (`NVRM_EVENT_WAIT` overrides), after a
     20 µs spin, bounded to 2000 ms.
   - Other processes poll with backoff (`nvkmd_nvrm_wait_backoff` 8304-8315):
     pause under 50 µs, `sched_yield` under 1 ms, `usleep(50)` under 20 ms,
     then `usleep(200)`.
   - The worker marks the surface ready (`nvmtl_ws_part_landed`,
     `nvmtl_ws_mark_ready`, `nvmtl_ws_release`).
10. **Swap (kernel).**
    - `NVDisplayPipe::performTransaction` (`kexts/NVRM/accel/nvrm-accel.cpp:1142-1200`)
      tries `nvAccelIopFlip` (2046-2110: flip cache, family lock on a miss,
      vramNewest check).
    - When the flip path is not used, it falls back to the copy path, which
      calls `nvSurfWaitReady` (1384-1407; `IOLockSleepDeadline`, 100 ms bound)
      and does a CPU copy.
    - `gIopFlip = 0` by default (1311); NVRM's autoGo turns it on after about
      60 s (docs/CARD-SUPPORT.md:36-54). `gIopAsync = 1` (1339);
      `gSurfGpuOn = 1` (1350).
    - Async path: `nvAccelIopAsyncStart` (~2010-2045) makes WindowServer's
      present wait while the previous flip is busy. It re-reads every 250 µs,
      up to `NVRMFlipWaitUs`. Past that, the frame is queued or dropped.
    - `nvAccelIopAsyncRun` (1960-2003) runs on a thread call: it waits in
      `nvSurfWaitReady`, then calls `nvFlipToSurfacePure`.
11. **Flip latch.**
    - `kexts/NVRMFB/fb/nvrm-fb.cpp`: `gFlipLatch = 1` (1565).
    - `flipWaitUs` (1626-1633) is 1.25 periods (6.9 ms at 180 Hz).
    - The latch wait in `submitConfig` (~1715-1750) runs on NVAccel's swap
      worker, not on WindowServer's thread.
    - Mode 2 is deferred: it costs 2.08 ms of a 4.17 ms 240 Hz frame (#300).
    - Sysctls `debug.nvrmfb_flip_latch*` (3220-3235). `presentStatsNote`
      (1580-1619) logs "present stats head" lines.

## 3. Candidate cost sources

Scaling key: **D** = per draw (grows with layer count, which is why CPU rises
with the number of open windows), **S** = per surface or wrapper, **F** = fixed
per frame, **A** = grows with pixel area or resolution.

| # | Candidate | Code | Scales | On WindowServer's thread? | Evidence | Status in v2.5.5 |
|---|---|---|---|---|---|---|
| 1 | Per-draw encode overhead: sampler-variant `@synchronized` plus lookup, repeated `setRenderPipelineState:` (label, retain, rebind), `nvmtl_bind_embedded` twice, objc retain and NSSet adds | `NVMTLObjects.m:2728-2787, 2942, 3123, 3376` | D | Yes (encoding thread) | #196 (objc about 10 % of samples), NvGfx "a third of samples in drawIndexedPrimitives", N-186 1.6 µs per draw after fixes | 18996e2 and c73ea10 not applied |
| 2 | Descriptor snapshot per draw: allocate plus `vkUpdateDescriptorSets` whenever bindings are dirty (a texture change per layer always dirties) | `nvmtl_vk.c:2916-3128` | D | Yes | #196: about 1 ms per update in NVK descriptor code, `nvmtl_snapshot_set_md` 147 samples | Dirty-only reuse exists, but a new texture per layer still makes a new set |
| 3 | Per-bind pending-write check: global class lock plus an NSString key per `setFragmentTexture:`. It contends with the worker and with the commit-time ahead pass, which holds the same lock across host copies and `vkQueueSubmit` | `NVMTLEventSync.m:46-77`, `NVMTLObjects.m:1033-1041`, `NVMTLEventSync.m:753` | D (plus contention) | Yes | NvGfx bd09e42 targeted it; no isolated number | Not applied |
| 4 | VRAM IOSurface wrapper import not cached: escape, RM DUP, VA map, buffer and image alias each time a VRAM-backed surface is wrapped | `NVMTLDevice.m:958-1042`, `nvmtl_vk.c:2020-2056` | S (per wrap) | Yes | NvGfx: "an IOSurface import per frame" | Only private images are cached |
| 5 | Wait until scheduled: WindowServer blocks until its part is submitted. Submission waits on a worker stuck in `vkWaitForFences` on the previous part, unless the ahead pass can submit; it cannot when the part is claimed, has host copies, or is at the cap. This costs latency rather than CPU, but it serialises compositing with GPU time | `NVMTLObjects.m:5048-5055, ~5136`; `NVMTLEventSync.m:~390, ~545-690, 743-800` | F (plus GPU time when serialised) | Yes (blocked) | 071110c message; N-166 vs N-168 (+45 % from the ahead pass) | Ahead pass on; host-copy hold on |
| 6 | Commit-time ahead pass on the committing thread under the class lock | `NVMTLEventSync.m:743-800` | F | Yes (CPU) | N-167: moving it off-thread "changes neither phase" | On (upstream 071110c) |
| 7 | Per-commit kernel escapes per surface: dirty mark (takes the accelerator lock, can wait behind page-offs) and pending mark | `NVMTLEventSync.m:~205-240`; `nvmtl_vk.c:2001-2003` | S | Yes | No direct measurement; small per call, but can block on the accelerator lock | Present |
| 8 | Surface in/out: seed checks, synchronous CPU uploads, readback for non-VRAM render targets | `NVMTLObjects.m:1227-1318` | S, A when it copies | Yes | Small during a drag (seeds don't change); large if a target lands outside VRAM | Present |
| 9 | Copy path when the composited frame is refused VRAM on a 256 MB BAR1: CPU copy in `performTransaction` | `nvrm-accel.cpp:1142-1218` | **A** | Kernel time in WindowServer's swap path | bar1-spend: 2.5-5 ms of kernel CPU per refused frame | 2060-specific risk; see bar1-spend |
| 10 | Async flip busy wait: WindowServer's present re-reads every 250 µs, up to 1.25 periods, while the previous flip is busy | `nvrm-accel.cpp:~2010-2045` | F, only when presents outrun flips | Yes (kernel) | #356 flip wait 0.25-3.3 ms, not the bottleneck at 50 fps; it matters once the CPU cost falls below 5.5 ms | Present |
| 11 | Flip latch (modes 0/1/2) | `nvrm-fb.cpp:1565, 1626-1750` | F | No (NVAccel swap worker) | #352: latch mode makes no difference | Off WindowServer's thread |
| 12 | Event wait vs polling | `nvk-macos.patch:8304-8371` | F | WindowServer sleeps on events after 20 µs; polling only affects other processes | docs/EVENT-WAIT.md | Already event-based for WindowServer |
| 13 | Shader translation in the first minutes after login | #370, NvGfx #11, 2b41c23, 7e6dc68 | Transient | `coreanimation.pipelines` thread | #226, #356 comment (3-26 flips/s early) | Measurement hygiene: profile after 5 min |

Why "whatever the window size": candidates 1-7 cost per draw, per surface or
per frame, not per pixel. The composited frame is always the full screen, but
lowering resolution did not help in #356 (NvGfx saw 35 flips/s HiDPI vs 39
native), so the pixel-bound candidate (9) is not what happened there. On the
2060, though, 9 may come into play because BAR1 is smaller. Why "whatever the
refresh rate": the loop is CPU-bound at about 50 fps, below every panel rate,
so the panel never sets the pace.

Caution on the "100 % CPU" figure: Activity Monitor sums WindowServer's
threads (main or compositor, `nvmtl.execution`, completion and dispatch
threads). The profile must be split by thread before blaming encode.

## 4. Candidate levers (not designs)

- Port 18996e2 (skip a same-pipeline rebind inside a pass) and c73ea10 (memo
  the sampler variant per encoder).
- Port the idea of bd09e42: a cheap writer key, and the per-bind
  `nvmtl_surface_pending_write` taken off the global class lock.
- Cache wrappers (or at least the VRAM import) for VRAM-backed IOSurfaces,
  keyed by surface and seed or generation.
- Cut descriptor churn per layer: bindless or push descriptors, or reuse sets
  keyed by texture (the idea from #196).
- Let the ahead pass submit parts with host copies (`NVMTL_GSUB_HOSTPTR_LIFT`
  semantics), so `waitUntilScheduled` does not wait for the worker's fence.
- Optionally move the commit-time ahead pass off WindowServer's thread
  (4b3bdd5). Low expected gain per N-167.
- Batch or drop the per-commit, per-surface escapes (dirty mark plus pending
  mark).
- Keep the composited frame and the window backing stores in VRAM on 256 MB
  BAR1, so the copy path never runs (bar1-spend levers).
- Once CPU cost is under 5.5 ms, check the async-flip busy wait and the latch
  mode at 180 Hz.

## 5. What only profiling on Tahoe can settle

1. How the 20 ms (or whatever the 2060 and 5700X3D show) splits between encode
   (1-4), commit (6-7), the scheduled wait (5) and the kernel copy (9).
2. Whether the class lock is actually contended (worker or ahead pass vs
   encoder).
3. How often CoreAnimation re-wraps a VRAM IOSurface per frame (candidate 4).
4. Whether the composited frame on 256 MB BAR1 ever takes the copy path during
   a drag.
5. The stock v2.5.5 drag rate on this machine. No one has measured stock 2.4.x
   or 2.5.x, so the gap to NvGfx's 148 is unknown.

### Plan

Setup:

- Log in, then wait at least 5 minutes, or until a test drag is steady, so
  shader translation (13) is out of the picture.
- Single display at 2560x1440 @ 180 Hz.
- Record the build (`v2.5.5` plus rtx2060 commits) and whether autoGo has
  enabled iop flips (`sysctl debug.nvaccel_iop_flip`).

Action:

- Drag a Finder window by its title bar in a steady circle for 8 s.
- Repeat with 1, 5 and 15 open windows. CPU should scale with layers if D
  candidates dominate.
- Repeat at 60 Hz vs 180 Hz.
- Repeat with a small window vs a large one.

Captures, one action per capture:

1. `sudo spindump WindowServer 6 -reveal` (or `sudo sample WindowServer 6 -f
   ws.txt`) during the drag.
   - Split by thread: main/compositor, `nvmtl.execution`, completion threads.
   - Inside each, find the share of: `drawIndexedPrimitives`,
     `nvmtlSamplerPipeline`, `nvmtl_snapshot_set_*`, `nvk_UpdateDescriptorSets`,
     `nvmtl_surface_pending_write` / `objc_sync_enter`,
     `nvmtl_vk_surface_vram` / `newTextureWithDescriptor:iosurface:`,
     `nvmtl_gsub_ahead_pass`, `waitUntilScheduled`, `nvmtl_ws_mark_pending`,
     and kernel `performTransaction` / `nvSurfWaitReady` / memcpy.
2. Instruments **Time Profiler** attached to WindowServer, with high-frequency
   sampling and kernel frames on. Group by thread, then invert the call tree.
3. Instruments **System Trace** on WindowServer for thread states (running vs
   blocked), with the blocking call for each wait. This separates CPU (1-4, 6,
   7) from serialisation (5) and shows contention on `objc_sync_enter` / the
   class lock and on the accelerator lock behind escapes.
4. Kernel counters, read before and after each 8 s drag (`sysctl -a | grep -E
   'nvaccel|nvrmfb'`), then take the deltas:
   - `debug.nvaccel_iop_flips`, `iop_async_flips`, `iop_async_refused`,
     `iop_async_drop`, `iop_late`, `iop_flip_novram`, `iop_flip_hit`,
     `iop_flip_miss`, `iop_flip_lock` (flip-cache misses take the family
     lock), `iop_ok` (copy-path transactions);
   - `debug.nvaccel_surface_gpu_marks`, `_waits`, `_timeouts`, `_wait_max_us`;
   - `debug.nvrmfb_flip_latch_waits`, `_timeouts`, `_max_us`, `_late`;
   - `debug.nvaccel_vm_refused`, `debug.nvrmfb_vram_mapped_bytes`;
   - the `present stats head` log line (`log show --last 1m --predicate
     'sender == "NVRMFB"'`).
   - Flips per second is `iop_flips` delta / 8. Any `iop_flip_novram` or
     `vm_refused` growth means the copy path (9) is in play.
5. Wrapper rate: count `newTextureWithDescriptor:iosurface:` /
   `nvmtl_vk_surface_vram` calls per second with dtrace (`pid$target::*surface_vram*:entry`)
   if SIP allows, or from the spindump sample counts, or from the plugin's
   VRAM-family nvlog lines if enabled.
6. A/B knobs. Release plugin builds unset `NVMTL_*`/`NVK_*`/`NAK_*`/`NVRM_*`
   environment variables (`NVMTLObjects.m:82-128`), so put the knobs in
   `/Library/GPUBundles/nvmtl/nvrm610.conf`, one at a time, then restart
   WindowServer (log out and in):
   - `NVMTL_PERF_LOG=1`: PERFSUB lines on stderr (`nvmtl_vk.c:2786-2820`);
     per-submit timing;
   - `NVMTL_COMMIT_AHEAD=0`: expect about 50 fps if the ahead pass matters as
     on NvGfx;
   - `NVMTL_GSUB_HOSTPTR_LIFT=1`: tests whether the host-copy hold makes
     `waitUntilScheduled` wait for the worker;
   - `NVMTL_GSUB_INFLIGHT=32`: tests the cap;
   - `NVMTL_NO_DIRTYONLY=1`: if the frame rate barely drops, descriptor reuse
     is not helping WindowServer;
   - `NVMTL_WS_WAIT_COMPLETION=1`: the old full wait, as an upper bound for 5;
   - `NVRM_EVENT_WAIT=0/1`: confirms 12 is negligible.
   - Kernel sysctls, no restart: `debug.nvrmfb_flip_latch=0/1/2`,
     `debug.nvaccel_iop_async=0/1`.
7. Record CPU model (5700X3D) and power state. NvGfx numbers came from a
   115 W-TGP laptop with an Arrow Lake CPU and do not transfer directly.

Decision rule: if per-draw symbols (1-3) plus the wrapper import (4) take most
samples on the compositor thread, port the NvGfx per-draw fixes and add
wrapper caching first. If System Trace shows the compositor mostly blocked in
`waitUntilScheduled`, work on 5. If the counters show novram or refusals, the
bar1-spend levers come first.

## Sources

- Code: this tree at `v2.5.5-1-ga217742`, paths and lines above.
- Upstream issues (read-only): nullmoth/nvidia-macos-driver #356, #196, #352,
  #314, #391, #190, #226, #370, #300.
- Upstream commits: e75be1e, 40daaa6, 071110c.
- NvGfx: https://github.com/watchthelight-labs/NvGfx branch `nvgfx-2.5.3`,
  commits 37f2af4, 18996e2, c73ea10, bd09e42, 4b3bdd5, 9eae44d, 2b41c23,
  7e6dc68; NVGFX.md.
- NvGfx logs: https://github.com/watchthelight-labs/research
  `logs/watchthelight/lenovo-legion-5-15iax10/` N-160, N-166, N-167, N-168,
  N-186.
- Sibling: `origin/research/bar1-spend:research/bar1-spend.md`.
- Repo docs: `docs/EVENT-WAIT.md`, `docs/CARD-SUPPORT.md:36-54`.
