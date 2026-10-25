# Exposing GPU utilization to macOS

Type: research
Status: open
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
