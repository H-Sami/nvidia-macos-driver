# Probe utilization keys and GPUMON on Tahoe

Type: task
Status: open
Blocked by: 03

## Question

Which `PerformanceStatistics` keys do Activity Monitor's GPU History and iStat Menus actually read on Tahoe, and does
GPUMON work from the kernel on TU106?

With a locally built NVAccel (byte-identical to 2.5.5, from [Build the fork from source on
Tahoe](03-build-fork-on-tahoe.md)) and the release NVRM, run the checks listed in [Exposing GPU utilization to
macOS](08-exposing-utilization.md): `ioreg` NVAccel twice to see what the family writes and how often; publish a fixed
50 in `Device Utilization %`, then in `GPU Activity(%)` alone, and watch both monitors; call GPUMON from NVAccel through
NVRM's exported RM entry points and record its return code, real sample period and whether gr/nvdec/nvenc move under
load; try the clock and video-engine controls; time one call; check whether a third-party kext can link
`gpu_accumulate_time()`. If GPUMON can't be reached without changing NVRM, record that and stop: it's what [Make NVRM
buildable](18-make-nvrm-buildable.md) waits for. A throwaway build; nothing here is kept. Driven by Claude Code on
Tahoe; the owner reboots and reads the monitors.
