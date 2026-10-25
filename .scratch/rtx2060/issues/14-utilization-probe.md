# Probe utilization keys and GPUMON on Tahoe

Type: task
Status: open
Blocked by: 03

## Question

Which `PerformanceStatistics` keys do Activity Monitor's GPU History and iStat Menus actually read on Tahoe, and does
GPUMON work from the kernel on TU106?

With a locally built NVAccel/NVRM (from [Build the fork from source on Tahoe](03-build-fork-on-tahoe.md)), run the
checks listed in [Exposing GPU utilization to macOS](08-exposing-utilization.md): `ioreg` NVAccel twice to see what
the family writes and how often; publish a fixed 50 in `Device Utilization %`, then in `GPU Activity(%)` alone, and
watch both monitors; call GPUMON from the kernel and record its return code, real sample period and whether
gr/nvdec/nvenc move under load; try the clock and video-engine controls; time one call; check whether a third-party
kext can link `gpu_accumulate_time()`. A throwaway build; nothing here is kept. Driven by Claude Code on Tahoe; the
owner reboots and reads the monitors.
