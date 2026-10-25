# Exposing GPU utilization to macOS

Type: research
Status: resolved
Blocked by:

## Question

What do Activity Monitor's GPU History and iStat Menus read to show GPU utilization (which IOAccelerator
`PerformanceStatistics` keys, at what rate, from which service), and how can this driver fill them from the GPU's own
counters?

Upstream #324 reads the counters from user space with `NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2`
through NVAccel's escape interface (graphics, memory, NVENC, NVDEC; the firmware samples about every 14 s), and stopped
at opening a kernel-side RM client. NVAccel already publishes `Temperature(C)` on a timer. The answer should cover the
keys real AMD and Intel Mac drivers publish, whether a kernel-side client or a finer-grained counter is available on
Turing GSP, and the trade-offs of putting the sampler in the kext, a daemon or the plugin.

## Answer

Monitors read `Device Utilization %` (an integer, 0–100) from each IOAccelerator's `PerformanceStatistics`, and the
kext can fill it by itself: NVRM already has a working kernel-side RM client, so no daemon is needed.

- Readers: every open-source monitor checked (exelban/stats, osquery, fastfetch, XRG, HWMonitorSMC2, Unreal Engine)
  reads `Device Utilization %` first and falls back to `GPU Activity(%)`. Activity Monitor and iStat are closed source,
  so it is likely, not confirmed, that they read the same key. Activity Monitor's per-process % GPU comes from XNU's
  `gpu_accumulate_time()`, charged to the calling thread.
- #324's 14.4 s steps are probably a reading bug: it reads `samples[0]` of a 72-entry ring whose newest entry is at
  `(tracker+71)%72` (72 × 200 ms = 14.4 s). Read correctly, samples should be under a second old.
- `kexts/NVRM/nvrm_fbinfo.cpp` already opens an RM client through `rm_kernel_rmapi_op()` and runs `FB_GET_INFO_V2`
  without an `nv_file_private_t`. GPUMON (`0x20802096`) is non-privileged but takes the GPU lock and waits on GSP, so it
  must run on a `thread_call`. Temperature is a raw register read, a template only for publishing a key.
- Also available: `FB_GET_INFO_V2` HEAP_FREE/HEAP_SIZE for VRAM used/free; clock samples (`0x20801037`) and a
  video-engine sample (`0x20802087`), both untested on Turing; no fan control in the open RM; the plugin already
  records GPU start/end times per command buffer.
- Problems to handle: the family rewrites the whole dictionary every 0.25–2 s and drops added keys until the next
  write; NVAccel's vendor-only match string and its `IOClass` stop monitors pairing it with the card ("Unknown").
- Candidate approaches: (A) a 1 Hz kernel sampler averaging GPUMON samples since the last read, published by NVAccel
  with the VRAM figures; (B) A plus per-command-buffer busy times from the plugin feeding `gpu_accumulate_time()`;
  (C) #324's daemon only as a prototype to confirm the keys; (D) override `newStatistics()` so the family itself writes
  our keys; any of them with a device-specific match string. Upstream PR #380 (Survey community fixes) is a ready-made
  candidate to weigh against these.
- To verify on Tahoe: which keys the family writes and how often (`ioreg` twice); a fixed 50 in `Device Utilization %`,
  then in `GPU Activity(%)` alone, against Activity Monitor and iStat; GPUMON from the kernel on TU106 (OK, real
  period, values move under load); the clock and video-engine controls; cost of one call and no extra frame gaps at
  180 Hz; whether a third-party kext can link `gpu_accumulate_time()`.

Findings: branch `research/utilization`, file `research/utilization.md`.
