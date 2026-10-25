# Exposing GPU utilization to macOS (RTX 2060, Turing GSP)

Research for ticket `.scratch/rtx2060/issues/08-exposing-utilization.md`. Date: 2026-10-25. Pinned base: `rtx2060`
(upstream v2.5.5). NVIDIA source: `NVIDIA/open-gpu-kernel-modules` tag `615.78.08` (commit `1a82fbf`).

## Answer in one paragraph

Every open-source macOS monitor reads one dictionary: the `PerformanceStatistics` property of each `IOAccelerator`
service. The utilization key they all accept is `"Device Utilization %"` (an integer, 0-100), and most also accept
`"GPU Activity(%)"` as a fallback. Activity Monitor and iStat Menus are closed source. That they read the same key is
likely but not proven, so it has to be checked on Tahoe (see the last section). This driver can fill the key **from
inside the kext with no daemon**. `kexts/NVRM/nvrm_fbinfo.cpp` already opens a kernel-privileged RM client through
`rm_kernel_rmapi_op()` and runs `NV2080_CTRL_CMD_FB_GET_INFO_V2`. The GPUMON control from #324 is non-privileged and
is sent through to GSP, so the same path should work. The "~14.4 s" step that #324 reported is very likely a reading
bug, not a firmware limit: #324 reads `samples[0]` of a 72-entry ring instead of the newest entry
(`(tracker + 71) % 72`), and 72 × 200 ms = 14.4 s. With the newest entry, the counters should update several times a
second.

## 1. What the consumers read

Every reader below does the same thing: it matches `IOAccelerator` services (`kIOAcceleratorClassName`) and reads
their `PerformanceStatistics` dictionary (`CFDictionary` of `CFNumber`).

### Key table

"Who reads it" lists only readers whose source code I checked. In the Source column, "PR #323" is evidence from
running the driver, not from source code.

| Key | Type / unit | Meaning | Who reads it (source) | Published by (evidence) | Confidence |
|---|---|---|---|---|---|
| `Device Utilization %` | int, 0-100 | Overall GPU busy | stats [1] (first choice), osquery [2] (first choice; comment: "used by NVIDIA and AMD on macOS"), fastfetch [3], XRG [4], HWMonitorSMC2 [5], Unreal Engine [6] | AMD, Apple AGX, Intel (per [2],[6]; Apple: zenn snippet [10]) | High that monitors read it; high that it is the main utilization key |
| `GPU Activity(%)` | int, 0-100 | Overall GPU busy (older/other drivers) | stats [1] (fallback), osquery [2] (fallback; "some Intel/integrated"), HWMonitorSMC2 [5] | Intel / older drivers per [2] | Medium |
| `Renderer Utilization %` | int, 0-100 | 3D/render pipe busy | stats [1] | Apple AGX (per [10]) | High (Apple); unknown for others |
| `Tiler Utilization %` | int, 0-100 | Tiler busy (TBDR only) | stats [1] | Apple AGX (per [10]) | High; not applicable to NVIDIA |
| `Device Unit N Utilization %`, `Device Utilization % at cur p-state` | int | Per-unit busy / busy scaled to current p-state | Unreal Engine [6], HWMonitorSMC2 [5] (disabled) | AMD/Intel per UE groupings | Medium |
| `GPU Core Utilization`, `GPU Memory Utilization` | int; HWMonitorSMC2 divides values ≥ 1e7 by 1e7 | Old Apple NVIDIA driver's busy counters | UE "Nvidia specific" group [6], HWMonitorSMC2 (NVIDIA only) [5], fastfetch [3] | Apple's old NVDA driver (Kepler era) | Medium |
| `GPU Video Engine Utilization` | int | Video engine busy | HWMonitorSMC2 [5] | Old NVIDIA driver | Low-medium |
| `Temperature(C)` | int, °C | Core temperature | stats [1], HWMonitorSMC2 [5]; iStat Menus (PR #323, from running the driver) | This driver (NVAccel, PR #323) | High |
| `Fan Speed(%)`, `Fan Speed(RPM)` | int | Fan | stats [1], HWMonitorSMC2 [5] | Old NVIDIA/AMD drivers | Medium |
| `Core Clock(MHz)`, `Memory Clock(MHz)` | int, MHz | Clocks | stats [1], HWMonitorSMC2 [5] | Old NVIDIA/AMD drivers | Medium |
| `Total Power(W)` | int, W | Board power | HWMonitorSMC2 [5] | — | Low |
| `vramUsedBytes`, `vramFreeBytes`, `vramLargestFreeBytes` | int64, bytes | Discrete VRAM use | XRG [4], fastfetch [3], WhateverGreen gpuinfo [7], UE [6] | AMD, old NVIDIA | High |
| `inUseVidMemoryBytes`, `inUseSysMemoryBytes` | int64 | Allocated video/system memory | XRG [4] (fallback), UE [6] | Family/Intel | Medium |
| `In use system memory`, `Alloc system memory` | int64 | Unified memory use (Apple Silicon, Intel) | osquery [2], fastfetch [3], XRG [4] | Apple AGX, Intel | High |
| `gartSizeBytes`, `gartFreeBytes`, `gartUsedBytes` | int64 | GART (sysmem aperture) | XRG [4] (last fallback), UE [6] | AMD/old | Medium |
| `hardwareWaitTime`, `hardwareSubmitWaitTime`, `CPU Wait …`, `HWChannel <eng> \| Commands Submitted/Completed` | int64 | Family/vendor wait and queue counters | XRG [4] (`hardwareWaitTime`), UE [6] | AMD (`HWChannel GFX/UVD/VCE/SDMA` names are AMD engines) | Medium |
| `model` (in stats dict) | string | GPU name | stats [1] (AGX only) | Apple AGX | High |

Non-statistics properties that readers also use:

- **`IOPCIMatch` / `IOPCIPrimaryMatch` on the accelerator**: stats [1] and XRG [4] use it to pair the accelerator
  with its `IOPCIDevice` (model name, vendor). stats looks for the full `0x<device><vendor>` string inside it. NVAccel
  publishes `IOPCIPrimaryMatch = 0x000010de&0x0000ffff` (`kexts/NVRM/accel/Info.plist:33`), which contains no device
  id, so **stats will not pair it**. stats then classifies by `IOClass`: only `nvaccelerator` or names containing
  `nvidia` count as NVIDIA (`reader.swift:147`). `NVAccel` matches neither, so the panel shows "Unknown". XRG's
  vendor-only rule needs `10DE ` (with a trailing space) or a string ending in `10DE`, so it also fails. Confidence:
  high, from reading the code. A fix is either a per-device match string (allowed, because only TU106 matters) or a
  runtime property, if the readers read the live registry rather than the personality. They do read the live
  registry, so a `setProperty("IOPCIMatch", "0x1f0810de")` (with the real device id) should be enough. Verify.
- `VRAM,totalMB`: read from the accelerator by WhateverGreen gpuinfo [7] and XRG [4], with the PCI device as a
  fallback in XRG. NVRM sets it on the `IOPCIDevice` only (`NVRM.cpp:1431`).
- `AGCInfo.poweredOffByAGC`: stats uses it for its "GPU powered off" state (AGC, the Apple Graphics Control
  dual-GPU switcher). Not needed here.

### Activity Monitor

- **GPU History window** (Window ▸ GPU History, one graph per GPU) [8]: the binary is closed. No primary source names
  the key it reads. It is consistent with every public monitor (and with the window going blank for unsupported or
  legacy GPUs [9]) that it reads `Device Utilization %` from each `IOAccelerator`'s `PerformanceStatistics`. It may
  also need the accelerator to be a Metal device (have `MetalPluginName`), which NVAccel already has. **Confidence:
  medium.** Verify on Tahoe (last section).
- **Per-process "% GPU" / "GPU Time" columns**: these come from a different mechanism. XNU keeps GPU time per thread.
  A GPU driver bills it by calling the KPI `gpu_accumulate_time(scope, gpu_id, domain, accumulated_ns, tstamp_ns)`,
  which adds to `current_thread()->machine.thread_gpu_ns` through `ml_gpu_stat_update()`
  (`osfmk/kern/energy_perf.c:46-50`, `osfmk/i386/machine_routines.c:1317`). The totals come back out through
  `task_power_info_v2.gpu_energy.task_gpu_utilisation` (`osfmk/kern/task.c:6816-6847`) [11]. The time is billed to
  the **calling thread**, so the call must happen in the client process's thread context, for example during a
  submit or wait user-client call. Confidence that Activity Monitor's column uses this: medium. The XNU plumbing
  itself: high.

### iStat Menus

Closed source. The only first-hand evidence is PR #323: with NVAccel publishing `Temperature(C)` in its own
`PerformanceStatistics`, iStat's GPU panel showed the temperature. It surely reads the same dictionary for
utilization. Whether it reads `Device Utilization %`, `GPU Activity(%)` or both is unknown. **Confidence: medium.**

### Update rate

- Readers poll. stats re-reads on its module interval, 1 s by default and set by the user. Activity Monitor's update
  frequency is set in its menu (1/2/5 s). No consumer asks the driver for a sample.
- The family itself rewrites NVAccel's `PerformanceStatistics` **wholesale every 0.25-2 s**, which drops any key the
  family did not put there (`nvrm-accel.cpp:68-70, 825-833`; upstream author's observation). That is why the
  temperature timer runs every 250 ms and does a copy-modify-write. A utilization key added the same way would
  flicker out for up to 250 ms after each family rewrite, so a reader could sometimes see the key missing.
  - The family builds that dictionary from an `IOAccelStatistics2` object it gets from the factory
    `IOGraphicsAccelerator2::newStatistics()` (vtable slot 338, `kexts/NVRM/accel/re/IOGraphicsAccelerator2.h:175`).
    Vendor drivers can override this factory. That is the natural hook for adding keys without the race. The
    interface of `IOAccelStatistics2` has not been reverse-engineered here. Confidence that this is how AMD and Intel
    add their keys: low-medium.
- Rate that is useful: a value fresh within about 1 s, so a 1 s poll never shows a stale number twice. Numbers that
  step every 14 s look broken in Activity Monitor's graph.

## 2. RM controls available on Turing GSP (615.78.08)

Flags decoded with `src/nvidia/inc/kernel/rmapi/control.h` (`NON_PRIVILEGED=0x8`, `ROUTE_TO_PHYSICAL=0x40`,
`API_LOCK_READONLY=0x100`, `GSP_PLUGIN_FOR_VGPU_GSP=0x10000`, `PHYSICAL_IMPLEMENTED_ON_VGPU_GUEST=0x40000`); the
values come from the export table in `src/nvidia/generated/g_subdevice_nvoc.c`.

| Control | Id | Flags | Returns | Granularity | Notes |
|---|---|---|---|---|---|
| `NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2` | `0x20802096` | `0x50008` non-privileged, takes GPU lock | Ring of 72 `PERFMON_UTIL_SAMPLE`s: `base.timeStamp` (ns) plus `fb`, `gr`, `nvenc`, `nvdec`, `nvjpg`, `nvofa`, each with `util` (pct×100) and `procId` | The header says the ring "wraps around after 10 seconds" (≈139 ms per sample). #324's 14.4 s = 72 × 200 ms suggests 200 ms in practice | Kernel handler `subdeviceCtrlCmdPerfGetGpumonPerfmonUtilSamplesV2_KERNEL` (`kern_perf_ctrl.c:96`) sends it to GSP through `GPU_GET_PHYSICAL_RMAPI`, then rewrites `procId` unless `osIsInitNs()` is true. `bufSize` must equal `72*sizeof(sample)` or the call fails with `NV_ERR_INVALID_ARGUMENT`. Not supported with MIG (not relevant). |
| ↳ ring semantics | | | `tracker` = oldest entry. Newest entry = `(tracker + count − 1) % 72` once full; `0..tracker-1` while filling. A caller can keep `tracker` to read only new samples | | `ctrl2080gpumon.h:52-77`, `ctrl2080perf.h:562-596`. **#324 reads `samples[0]`, a fixed slot that is rewritten once per lap, which explains the 14.4 s steps.** Confidence: high from reading the header and the arithmetic; confirm with timestamps on Tahoe |
| `NV2080_CTRL_CMD_PERF_GET_VID_ENG_PERFMON_SAMPLE` | `0x20802087` | `0x40048` routed to GSP | `clkPercentBusy` and `samplingPeriodUs` for NVENC/NVDEC/NVJPG/NVOFA | Reports its own period | Simpler single-value alternative for the video engines. Not tested on Turing GSP |
| `NV2080_CTRL_CMD_PERF_GET_CURRENT_PSTATE` | `0x20802068` | `0x50048` routed to GSP | `currPstate` | Instant | Could feed something like "Device Utilization % at cur p-state". Optional |
| `NV2080_CTRL_CMD_CLK_PMUMON_CLK_DOMAINS_GET_SAMPLES` | `0x20801037` | `0x40048` routed to GSP | 250-entry queue: `gpcClkFreqKHz`, `dramClkFreqKHz`, `activeGpcClkFreqKHz` | "as fast every 20ms" | → `Core Clock(MHz)` / `Memory Clock(MHz)`. Whether Turing GSP fills it is unknown (PMUMON is a PMU feature). Confidence low |
| `NV2080_CTRL_CMD_FB_GET_INFO_V2` | `0x20801303` | `0x10118` API-lock read-only | Index list: `HEAP_SIZE` (0x09), `HEAP_FREE` (0x16), `USABLE_RAM_SIZE` (0x20), `BAR1_AVAIL_SIZE` (0x1D), all in KB | Instant | **Already called in-kernel** by `nvrm_query_vram_kb()`. Gives `vramFreeBytes` / `vramUsedBytes`. `BAR1_AVAIL_SIZE` is also useful for the BAR1 tickets |
| `NV2080_CTRL_CMD_THERMAL_SYSTEM_EXECUTE_V2` | `0x20800513` | `0x8` | Thermal instruction list (the path nvidia-smi uses for temperature) | Instant | Alternative to the BAR0 TSENS read; not needed |
| `NV0000_CTRL_CMD_GPUACCT_*` | `0xb01-0xb05` | root client | Per-process `gpuUtil`, start/end time | Process lifetime | Needs OS pid plumbing; `os_find_ns_pid` is stubbed on XNU (`os-xnu.cpp:206`). Not useful as is |
| Fan / cooler | — | — | No cooler control is exported in the open RM | — | `Fan Speed(%)` has no RM source here. Out of reach without a reverse-engineered register |

### Finer-grained alternatives to GPUMON

1. **Read the GPUMON ring correctly.** Take the newest sample, or average all samples newer than the last saved
   `tracker`, weighted by their timestamps. That gives about 200 ms freshness and a smooth 1 s average. This is the
   cheapest fix and probably enough.
2. **Busy time measured by the driver from the command buffers.** The plugin already records start and end ticks on
   the GPU for each command buffer (`nvmtlCollectDeviceTiming`, `plugin/NVMTLEventSync.m:412-443`, from
   `nvk_cmdbuf.timing`). This feeds `GPUStartTime`/`GPUEndTime`. The union of those intervals over a window is
   exact busy time for Metal work, with per-process attribution, at any resolution. Limits: it misses work outside
   the plugin, such as NVKMS flips, copy-engine work in the kext, and the video engines (unless the video libraries
   report it too). It is also per process, so a system-wide figure needs the intervals combined somewhere central
   (the kext). The same data is what `gpu_accumulate_time()` needs for Activity Monitor's per-process % GPU.
3. **Engine timestamps with semaphore reports.** The 3D and copy classes can write the 64-bit GPU global timer at
   the start and end of each push (as Vulkan timestamp queries do). That is the same idea as (2) but done in the
   kernel's own submissions. More work; only worth it if (2) misses too much.
4. **Polling an engine-status register in BAR0** (as radeontop does on AMD). nouveau uses `0x400700` (PGRAPH status)
   and `0x40060c` bit 0 (GR busy) on Fermi+ (`drivers/gpu/drm/nouveau/nvkm/engine/gr/gf100.c:1062-1066`) [12].
   Turing layouts are not in NVIDIA's published `swref` headers. Under GSP, GR may be power-gated (ELPG), and reads
   of a gated unit return garbage or keep it awake. Confidence low. Last resort.
5. **PMU/perfmon counter hardware directly** (`PERF_RESERVE_PERFMON_HW`, `0x20802093`): this is for profilers and
   conflicts with GSP's own sampling. Not recommended.

## 3. How the driver calls RM inside the kernel today, and whether GPUMON can use the same path

- **Temperature (PR #323) does not call RM at all.** `NVAccel::sampleTemperature()` maps BAR0 of its `IOPCIDevice`
  and reads TSENS `0x20460` directly, on an `IOTimerEventSource` that runs every 250 ms after a 5 s delay
  (`nvrm-accel.cpp:58-72, 768-833`). So it does not show how to call RM. It shows how to publish.
- **The template for calling RM is `kexts/NVRM/nvrm_fbinfo.cpp`.** `nvrm_query_vram_kb()` / `nvrm_query_gpu_profile()`
  fill a `nvidia_kernel_rmapi_ops_t` and call `rm_kernel_rmapi_op(NULL, &ops)` (`osapi.c:5218`, which dispatches to
  `Nv04AllocWithAccessKernel` / `Nv04ControlKernel` with kernel privilege). The sequence is `NV01_ROOT_CLIENT` →
  `NV0000_CTRL_CMD_GPU_ATTACH_IDS` → `NV01_DEVICE_0` → `NV20_SUBDEVICE_0` → `NV04_CONTROL` → free the root.
  **No `nv_file_private_t` is needed.** #324 and PR #323 stopped there only because they looked at `rm_ioctl()`, the
  user escape path (`NVRM.cpp:2042`).
- `nvrm_gpuva.cpp` and `nvrm_surfshare.cpp` use the same `rm_kernel_rmapi_op` path with NVKMS-kapi's own long-lived
  handles from `nvrm_kapi_dev_handles(kapiDevice, &hClient, &hDevice, &hSubdevice)` (`nvrm_kapi_fields.c:15`). So a
  sampler can either reuse kapi's subdevice or allocate its own client once and keep it.
- NVAccel reaches NVRM through `callPlatformFunction` with a named symbol (`NVRM.cpp:1660-1718`). Calls in the RM
  group are wrapped in `NvXnuPmUse`, which takes a power reference. A utilization query would naturally be one more
  name there, for example `nvGpuUtil`, returning `{gr, fb, enc, dec, tsNs}`.
- **GPUMON specifics, in-kernel:**
  - Its flags are `NON_PRIVILEGED` with no `NO_GPUS_LOCK`. A kernel client is more than privileged enough. The
    control takes the RM API lock and the GPU lock and makes a synchronous GSP RPC. **Do not run it on NVAccel's
    work-loop gate or from an interrupt.** Use a `thread_call` (already declared in `nvrm-accel.cpp:74-80`) or a
    dedicated thread, at 1 Hz or slower. The sample buffer is about 55 KB
    (72 × 776 B: an 8 B timestamp plus 6 engine samples of 128 B each, plus the header). That is far too big for
    the kernel stack, so allocate it once.
  - `os_is_init_ns()` is a stub that returns `NV_FALSE` (`nv_xnu_stubs.cpp:1324`). The handler therefore loops over
    the 72 samples calling `osFindNsPid` for each non-null `pOsPidInfo`, which returns `NOT_SUPPORTED` on XNU and is
    harmless. The header says `pOsPidInfo` is NULL for kernel-privileged clients anyway (`kern_perf_ctrl.c:128`).
  - Do not call it during system sleep or while the GPU is powered down. Check `NVRMGpuReady` /
    `fGpuPm == kGpuPmRunning` first, as the display paths do.
  - Lock contention: one RPC per second takes the GPU lock briefly, the same as nvidia-smi on Linux. It is not
    expected to hurt the 180 Hz desktop. Measure it.

## 4. Where to put the sampler: kext, daemon or plugin

| Place | Pros | Cons |
|---|---|---|
| **Kext (NVRM does the RM call, NVAccel publishes)** | One component and nothing to install. Starts at boot, survives logouts, sees all engines. Same pattern as temperature and VRAM. Can call `gpu_accumulate_time` from user-client calls on each process's thread. The RM path already exists (§3) | Kext changes are riskier (the picker's no-driver entry is the way back). Lock and RPC context must be right (thread_call, PM check). Must still co-exist with the family's wholesale rewrite |
| **Root daemon (#324 style: NVAccel escape → RM; plus a sysctl or user-client method to publish)** | Iterating needs no kext rebuild. A crash only stops the stats | Still needs kext support to publish, because user space cannot set an IOKit property on NVAccel. A LaunchDaemon, root, a second RM client and a heartbeat for when it dies. #324's author needed ~300 lines of kext code anyway. Starts late |
| **Plugin (inside each Metal process)** | Already holds exact GPU start/end ticks for each command buffer, so per-process busy time is free | Runs once per process: no single owner for the system-wide number, and a process going idle or exiting stops its data. Sandboxed apps cannot reach anything beyond their user client. Cannot see the video engines or kernel copies. Its job here is to report busy time **to** the kext, not to sample |

## 5. Candidate approaches (not a design)

- **A. Kernel GPUMON sampler.** A `thread_call` at 1 Hz in NVAccel calls NVRM (new `callPlatformFunction` name).
  NVRM runs `0x20802096` through `rm_kernel_rmapi_op` on a long-lived client and returns the average of the samples
  since the last `tracker`. NVAccel publishes `Device Utilization %` and `GPU Activity(%)` (gr/100), plus video and
  memory keys under names the readers know. Optionally `vramUsedBytes`/`vramFreeBytes` from `FB_GET_INFO_V2`, which
  can go on the same tick.
- **B. A plus driver-side accounting.** The plugin sends per-command-buffer GPU busy intervals to the kext on a call
  it already makes. The kext bills `gpu_accumulate_time()` in that thread's context, which gives Activity Monitor's
  per-process % GPU. Optionally, a cross-check or a finer system-wide figure.
- **C. #324 as written (daemon + sysctl).** It works, but it adds parts and still needs kext code. Only worth it as a
  quick prototype to confirm the keys Activity Monitor and iStat read before any kext work.
- **D. Publish without the race.** Override `newStatistics()` with an `IOAccelStatistics2` subclass that adds our keys
  whenever the family builds the dictionary. Needs reverse engineering. The fallback is to keep the 250 ms
  copy-modify-write, merged into one timer for temperature, utilization and memory.
- **Identity fixes that any approach needs:** an accelerator `IOPCIMatch` that contains `0x<device>10de`, so stats
  and XRG pair it with the PCI device and its model name. Maybe `VRAM,totalMB` on the accelerator as well.

## 6. What needs verifying on Tahoe

1. `ioreg -rc NVAccel -d1 -a` (twice, about 1 s apart): which keys the family already writes into
   `PerformanceStatistics` for NVAccel, and how often it replaces the dictionary.
2. **Which key Activity Monitor's GPU History reads.** Publish a fixed `Device Utilization %` = 50 through a debug
   sysctl and see whether GPU History plots it. Repeat with only `GPU Activity(%)`. Static check:
   `strings` on `/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor`, and on the
   SystemMonitor / `libsysmon` images extracted from the dyld shared cache, searching for `Utilization`.
3. Same test for iStat Menus, and see whether it also needs `IOPCIMatch` pairing to show a GPU name.
4. GPUMON on TU106 GSP 615.78.08: does `0x20802096` return `NV_OK` from a kernel client? Print `count`, `tracker`
   and the deltas between successive `base.timeStamp` values to get the real sample period (200 ms expected). Check
   that `gr.util` follows a Metal load, and that `nvdec.util` / `nvenc.util` move during video. #324 was measured on
   a 3080 (GA102), not on Turing.
5. Does `0x20801037` (clock samples) or `0x20802087` (video engine) return data on Turing GSP?
6. The cost of one GPUMON RPC (time with the GPU lock held), and the absence of extra 180 Hz frame gaps with the
   harness while sampling at 1 Hz.
7. Whether `gpu_accumulate_time` can be linked from a third-party kext on Tahoe (which KPI set exports it), and
   whether Activity Monitor's % GPU column then shows a value.

## Sources

1. exelban/stats `Modules/GPU/reader.swift` @ `5cf09a8` — <https://github.com/exelban/stats/blob/master/Modules/GPU/reader.swift> (lines 103-240)
2. osquery `osquery/tables/system/darwin/gpu_metrics.mm` — <https://github.com/osquery/osquery/blob/master/osquery/tables/system/darwin/gpu_metrics.mm> (lines 385-430)
3. fastfetch `src/detection/gpu/gpu_apple.c` — <https://github.com/fastfetch-cli/fastfetch/blob/dev/src/detection/gpu/gpu_apple.c> (lines 140-160)
4. XRG `Data Miners/XRGGPUMiner.m` — <https://github.com/mikepj/XRG/blob/master/Data%20Miners/XRGGPUMiner.m> (lines 288-410)
5. CloverHackyColor HWMonitorSMC2 `HWMonitorSMC/HWMonitorSensors/SystemKit/Graphics.swift` — <https://github.com/CloverHackyColor/HWMonitorSMC2> (lines 65-300)
6. Unreal Engine `Engine/Source/Runtime/Core/Private/Mac/MacPlatformMisc.cpp` (public mirror JimmieKJ/unrealTournament), driver-monitor stats, lines 2490-2800
7. acidanthera WhateverGreen `Tools/GPUInfo/gpuinfo.c` — <https://github.com/acidanthera/WhateverGreen/blob/master/Tools/GPUInfo/gpuinfo.c>
8. Apple, Activity Monitor User Guide, "View GPU activity" — <https://support.apple.com/guide/activity-monitor/actm9329b315/mac>
9. MacRumors, "GPU history in Activity Monitor blank" — <https://forums.macrumors.com/threads/gpu-history-in-activity-monitor-blank-mac-pro-high-sierra-ati-radeon-hd-5770.2192572/> (anecdotal)
10. zenn.dev snippet reading `Device/Renderer/Tiler Utilization %` on AGX — <https://zenn.dev/kyome/articles/de9288e40cd32e> (secondary)
11. apple-oss-distributions/xnu (main): `osfmk/kern/energy_perf.c`, `osfmk/i386/machine_routines.c`, `osfmk/kern/task.c`
12. Linux `drivers/gpu/drm/nouveau/nvkm/engine/gr/gf100.c`
13. NVIDIA open-gpu-kernel-modules 615.78.08: `src/common/sdk/nvidia/inc/ctrl/ctrl2080/{ctrl2080perf.h,ctrl2080gpumon.h,ctrl2080clk.h,ctrl2080fb.h,ctrl2080gpu.h}`, `ctrl0000/ctrl0000gpuacct.h`, `src/nvidia/src/kernel/gpu/perf/kern_perf_ctrl.c`, `src/nvidia/generated/g_subdevice_nvoc.c`, `src/nvidia/inc/kernel/rmapi/control.h`, `src/nvidia/arch/nvalloc/unix/src/osapi.c`
14. Upstream nullmoth/nvidia-macos-driver issue #324 (GeekAudio's `nvstatd.c`) and PR #323 (read only)
15. This repo: `kexts/NVRM/accel/nvrm-accel.cpp`, `kexts/NVRM/nvrm_fbinfo.cpp`, `kexts/NVRM/nvrm_gpuva.cpp`, `kexts/NVRM/NVRM.cpp`, `kexts/NVRM/nv_xnu_stubs.cpp`, `kexts/NVRM/os-xnu.cpp`, `kexts/NVRM/accel/Info.plist`, `plugin/NVMTLEventSync.m`

Note: `plugin/NVMTLGL.m:133` `performanceStatistics` is `MTLRenderPipelineReflection`'s per-pipeline compiler
statistics. It has nothing to do with GPU utilization, and returning `@{}` there is fine.
