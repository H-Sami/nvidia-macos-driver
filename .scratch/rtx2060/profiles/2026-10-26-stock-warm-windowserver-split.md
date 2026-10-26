# WindowServer CPU split, stock baseline (2026-10-26)

Source: `.scratch/rtx2060/baseline/2026-10-26-162100-stock-warm` (drag-15-windows, drag-small, dock-sweep) and `2026-10-26-154330-stock-cold` (drag-15-windows). Each is a spindump of 8.0 s at a 10 ms interval (801 samples). "Frames" means `flips` in framegap.json.

## Method, and how far to trust it

- I parsed the heavy-format stacks into leaf paths. A sample counts as on-CPU only when its leaf carries `(running)` or `(runnable)`. On the main thread, 679 running samples × 10 ms comes to 6.79 s against a thread CPU time of 6.736 s, so for that thread sample count works as a CPU-time measure. **The worker (`nvmtl.execution`) does not match:** 181 running samples against 1.255 s of CPU, so samples overstate it by about 1.45×. For the worker I give both sample-based and CPU-scaled ms/frame.
- NVRM kext frames were unsymbolicated (`??? (NVRM + off)`). I symbolicated them with `atos -l 0` against `/Library/Extensions/NVRM.kext`, whose UUID 4D64224B matches the spindump. NVAccel was symbolicated the same way. xnu frames remain `???`.
- Every on-CPU sample ends in 3-4 `kernel + 15002…` frames. That is the stackshot interrupt, not real kernel work. I count a sample as "in a syscall" only when its user leaf is a `libsystem_kernel` trap such as `mach_msg2_trap` (the IOConnectCall path into NVRMUserClient), `__open` or `kevent_id`.
- **Inlining:** `nvmtl_surface_pending_write` is a static function and never appears as a frame. Its cost shows up under `nvmtl_surface_in_for_cb` (`+[NSString stringWithFormat:]`, `objc_sync_enter`). `nvmtlSamplerPipeline` appears only once in all four dumps.
- **Bucket priority**, first match wins: d import, then c pending_write, then g shader/pipeline, then d2 deferred free, then e commit, then b descriptor (driver frames only), then a other driver, then h WindowServer/CA. The (f) kernel column cuts across buckets.
- At 10 ms sampling, any bucket under about 10 samples (0.2 ms/frame at 485 frames) is noise-level. Treat it as "under about 0.3 ms/frame", not as an exact number.

## Process and per-thread CPU

| scenario | flips | process CPU (spindump) | ps delta / wall | ms/frame | main thread | nvmtl.execution worker | CA render-server | other |
|---|---|---|---|---|---|---|---|---|
| drag-15 warm | 485 | 9.097 s | 9.48 s / 8.29 s | 18.8 (ps 19.5) | 6.736 s = 13.9 ms/f | 1.255 s = 2.6 ms/f | 0.259 s = 0.53 | root_queue ~0.2 s |
| drag-15 cold | 491 | 9.310 s | 9.68 s / 8.28 s | 19.0 | 6.710 s = 13.7 | 1.318 s = 2.7 | 0.259 s = 0.53 | coreanimation.pipelines 0.216 s, one-time in samples 16-37; root ~0.1 s |
| drag-small | 917 | 7.050 s | 7.29 s / 8.28 s | 7.7 | 5.829 s = 6.4 | 0.350 s = 0.38 | 0.258 s = 0.28 | ~0.1 s |
| dock-sweep | 111 | 1.501 s | 1.55 s / 8.08 s | 13.5 (frame-starved) | 1.089 s = 9.8 | 0.009 s | 0.227 s = 2.0 | ~0.05 s |

There is no separate `coreanimation.pipelines` CPU in the warm runs. It shows up only in the cold run: 0.216 s of `newRenderPipelineStateWithDescriptor` and translator work in the first 0.2 s.

Main-thread utilisation: drag-15 runs at 85% busy (679 of 801 samples), drag-small at 77%, dock-sweep at 15%. drag-15 is CPU-bound on ws_main_thread.

## Buckets: compositor (ws_main_thread)

Samples are running samples (10 ms each). "%" is the share of the thread's running samples. "kern" is how many of those samples sit in a syscall. "wait" is off-CPU samples in that bucket.

### drag-15-windows warm (485 frames, 679 running)
| bucket | run | % | ms/frame | kern | wait (ms/f) |
|---|---|---|---|---|---|
| (a) other Metal encoding in plugin/NVK | 92 | 13.5% | 1.90 | 7 | 0 |
| (b) descriptor sets (`nvmtl_vk_cmd_bind_set` → `nvmtl_snapshot_set_c/md` → `nvk_UpdateDescriptorSets` / `nvk_AllocateDescriptorSets`) | 152 | 22.4% | 3.13 | 0 | 0 |
| (c) surface_in_for_cb / pending_write | 10 | 1.5% | 0.21 | 0 | 1 (0.02) |
| (d) IOSurface wrapper import (`newTextureWithDescriptor:iosurface:plane:`) | 130 | 19.1% | 2.68 | 118 | 11 (0.23), all turnstile-blocked behind the worker's RM ioctl |
| (e) commit / commitAndWaitUntilSubmitted / submit | 13 | 1.9% | 0.27 | 4 | 7 (0.14) |
| (g) shader / pipeline | 1 | 0.1% | 0.02 | 0 | 0 |
| (h) WindowServer + CoreAnimation itself | 281 | 41.4% | 5.79 | 39 | 103 idle (server-loop mach_msg receive) |
| (f) all syscalls on this thread | 168 | 24.7% | 3.46 | | |

The worker (`nvmtl.execution`, 181 running samples, 1.255 s CPU):
- d2 deferred memory free (`nvkmd_nvrm_reap_deferred` → `nvRmApiFree`): 151 samples, 83%. That is 3.11 ms/frame by samples, about 2.15 ms/frame CPU-scaled, and 99% of it is in the kernel.
- e submit/fence: 11 running samples. The other 137 samples are off-CPU in `nvrm_xnu_wait_event` (the fence wait), which costs no CPU.
- a other: 19 samples, including `nvmtlSurfaceOutDirtied:` at 7.

### drag-15-windows cold (491 frames, 677 running): the same picture
| bucket | run | % | ms/f |
|---|---|---|---|
| a | 108 | 16.0% | 2.20 |
| b | 136 | 20.1% | 2.77 |
| c | 21 | 3.1% | 0.43 |
| d | 119 | 17.6% | 2.42 (plus 0.24 blocked) |
| e | 14 | 2.1% | 0.29 (plus 0.24 wait) |
| g | 1 | 0.1% | 0.02 |
| h | 278 | 41.1% | 5.66 |

Worker: d2 free 160 samples (83%, 3.26 ms/frame by samples, about 2.2 CPU-scaled).

### drag-small warm (917 frames, 616 running)
| bucket | run | % | ms/f |
|---|---|---|---|
| a | 91 | 14.8% | 0.99 (21 samples are `newTextureWithDescriptor:` private-texture alloc/map) |
| b | 136 | 22.1% | 1.48 |
| c | 6 | 1.0% | 0.07 |
| d | 5 | 0.8% | 0.05 |
| e | 26 | 4.2% | 0.28 |
| g | 3 | 0.5% | 0.03 |
| h | 349 | 56.7% | 3.81 |

Syscalls total 109 samples (1.19 ms/frame), 74 of them in WindowServer/CA's own mach IPC. Worker: 67 running samples, only 9 of them deferred free. Imports barely happen here.

### dock-sweep warm (111 frames, 123 running; main thread is 85% idle)
| bucket | run | % |
|---|---|---|
| a | 12 | 9.8% |
| b | 4 | 3.3% |
| c | 1 | 0.8% |
| d | 0 | 0% |
| e | 0 (1 wait) | 0% |
| h | 106 | 86.2% |

Of the h samples, 53 are client IPC (`rendezvousHandler`, which receives Dock's CA commits) and only about 35 are on the display-update path. WindowServer is not the bottleneck in dock-sweep; the 13.9 fps comes from elsewhere, probably Dock itself.

## What the kernel time is (f)

The RM ioctls on the drag-15 warm main thread total 113 running samples:
- `nvkmd_dev_import_dma_buf` → `nvRmApiMapMemoryDma`: 48
- `nvRmApiAlloc` (VA/handle): 37
- `nvRmApiDupObject`: 11
- `nvRmApiSurfShare`: 8
- non-import calls: about 9, including commit-time `nvkmd_nvrm_surface_dirty` → `SurfShare` at 2

On the worker, `nvRmApiFree` from `reap_deferred` accounts for 150 samples.

The deepest NVRM function in these calls is `os_mem_set`: 49 of 113 samples on the main thread and 104 of 153 on the worker. It is reached through `_gmmuWalkCBFillEntries` < `_mmuWalkResolveSubLevelConflicts` / `_mmuWalkPdeAcquire` < `mmuWalkMap`/`mmuWalkUnmap` < `gvaspaceMap`/`gvaspaceUnmap`/`_gvaspaceReleaseUnreservedPTEs`. In other words, **CPU memset of GPU page-table levels on every import map and every unmap**. Most of the rest of the time is `_rmGpuLocksAcquire`/`Release`, `kbusFlushSingle_GV100` and `kgmmuInvalidateTlb`.

`nvmtl_vk_surface_vram` also calls `open("/dev/null")` for every import. That is 13 samples (0.27 ms/frame), spent in the Sandbox, AMFI and EndpointSecurity MAC hooks.

## Top driver functions on the compositor thread

These are innermost driver frames, including time in libc and kernel callees below them.

drag-15 warm (679 running samples):
1. `nvrm_xnu_ioctl`: 113 (import Map 48, Alloc 37, Dup 11, SurfShare 8)
2. `nvk_UpdateDescriptorSets`: 61 (56 self)
3. `nvmtl_snapshot_set_md`: 35 (33 self)
4. `nvk_AllocateDescriptorSets`: 23
5. `nvmtl_vk_surface_vram`: 15 (13 in `open`)
6. `-[NVMTLRenderCommandEncoder setFragmentSamplerState:atIndex:]`: 10
7. `nvmtl_bind_embedded`: 9
8. `nvmtl_surface_in_for_cb`: 8 (`stringWithFormat` 5, `objc_sync_enter` 1)
9. `-[NVMTLCommandBuffer renderCommandEncoderWithDescriptor:]`: 6
10. `-[NVMTLResSet addObject:]`: 6
11. `nvk_cmd_flush_gfx_cbufs`: 5
12. `-[NVMTLRenderCommandEncoder nvmtlBindSamplerPipeline]` (self): 5
13. `nvmtl_address_snapshot`: 4
14. `nvk_cmd_flush_gfx_shaders`: 4
15. `setFragmentTexture:atIndex:`: 4, `nvkmd_mem_sync_to_gpu`: 4

The inclusive draw path goes `drawIndexedPrimitives` (127) / `drawPrimitives` (44) → `nvmtlBindSamplerPipeline` (158) → `nvmtl_vk_cmd_bind_set` (139).

drag-small: `nvk_UpdateDescriptorSets` 60, `nvrm_xnu_ioctl` 25 (mostly private alloc/map), `nvk_AllocateDescriptorSets` 21, `nvmtl_snapshot_set_md` 20, `NVMTLResSet addObject:` 12, `nvmtl_bind_embedded` 9, `renderCommandEncoderWithDescriptor:` 8, `nvmtlSubmitWithEvents` 7, `nvmtl_surface_in_for_cb` 6.

## WindowServer and CoreAnimation itself (h), drag-15 warm, 281 samples
- SkyLight services and client IPC outside the display update (`rendezvousHandler`, `connectionHandler`, voucher handling, mach_msg): 107
- CA `Updater` / `prepare_layer`: 67
- SkyLight `UpdateDisplays`, outside the compositor: 41
- the non-driver part of CA OGL render: 37
- SkyLight compositor glue: 19

Leaf libraries: QuartzCore 81, libsystem_kernel 41, SkyLight 36, malloc 24, objc 21, CoreGraphics 21.

## Levers, ranked by drag-15 cost (ms/frame of about 19)

1. **IOSurface wrapper import plus its deferred free: about 5 ms/frame.** That is 2.7 on the main thread, plus about 2.2 (CPU-scaled) to 3.1 (by samples) on the worker, plus 0.2 ms/frame blocked on the RM GPU lock between the two. This is the single largest driver cost. Over half of it is NVRM page-table fill (`os_mem_set` in the GMMU walk) on map and unmap. In drag-small it is effectively zero, so it scales with window count or wrapper churn. Note that `nvmtlNewSurfaceTexture` caches only `!_vramOn` wrappers (NVMTLDevice.m:1036), so every successful VRAM import is redone and later freed.
2. **Per-draw descriptor set build: 3.1 ms/frame in drag-15, 1.5 in drag-small** (about 22% of the compositor in both). It is all user-space. The worst parts are `nvk_UpdateDescriptorSets` and `nvk_AllocateDescriptorSets` called for every draw.
3. **Other encoding: 1.9 / 1.0 ms/frame.** It is spread thin, with no single hot function. In drag-small it includes private `newTextureWithDescriptor:` alloc/map (0.23).
4. pending_write / `surface_in_for_cb`: 0.21 warm, 0.43 cold, 0.07 drag-small. It is real but small, and mostly `NSString` key formatting rather than lock contention: one turnstile wait sample in total.
5. commit plus `commitAndWaitUntilSubmitted`: 0.27 running plus 0.14 waiting. **The wait-until-scheduled cost is near zero**, with only 2-7 wait samples per run.
6. **Sampler-variant lock and lookup: about 0.** `nvmtlSamplerPipeline` has one sample in the whole drag-15 run. **`setRenderPipelineState` rebinding: about 0.** It has 15 samples, but 11 of them are the deferred `nvmtl_vk_cmd_begin_pass` running inside it, not rebinding.
7. Per-surface kernel escapes at commit (`nvkmd_nvrm_surface_dirty` → `SurfShare`, `nvmtlSurfaceOutDirtied`): about 0.05-0.15 ms/frame across the main thread and the worker.
8. **Kernel copy when BAR1 is short: not visible.** No copy frames appear in any WindowServer thread, and `nvaccel_iop_copy_skip` did not change. If that path exists it runs outside WindowServer and this data cannot see it.
9. Not a driver lever: WindowServer and CA's own work is 5.8 ms/frame (41%) in drag-15 and 3.8 (57%) in drag-small.

## Surprises
- The biggest cost was not on the list as such: VRAM imports are never cached, and both their map and their unmap pay the GMMU PTE memset (`_mmuWalkResolveSubLevelConflicts` → `_gmmuWalkCBFillEntries` → `os_mem_set`) under the RM GPU lock. The worker's "submit-ahead" CPU is about 83% this teardown.
- `open("/dev/null")` for every import costs 0.27 ms/frame in MAC/Sandbox/EndpointSecurity hooks.
- The four suspected locking and rebinding levers (sampler variant, setRenderPipelineState, pending_write lock, commitAndWait) add up to under 0.6 ms/frame.
