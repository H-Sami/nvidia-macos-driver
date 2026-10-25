# Map: a 10/10 macOS Tahoe experience on the RTX 2060

## Destination

An ordered roadmap of specs, one per bottleneck, each carrying a measured baseline from this RTX 2060 and an
acceptance target from the 10/10 list below, ready to hand to `/to-spec` → `/implement`. The map is done when every
item on the 10/10 list is covered by a spec (or ruled out of scope) and nothing is left to decide before building.

**The 10/10 list** (acceptance targets, measured with the harness):

- **Desktop**: window drag, Dock, Mission Control and Safari scrolling hold 180 Hz with no frame gap over two refresh
  periods (11 ms); no hitch right after login; app launches and Settings icons as quick as on a real Mac; zero
  surface refusals in normal use.
- **Video**: 4K60 H.264 and HEVC in Safari and QuickTime on hardware decode, no dropped frames; VP9 if feasible
  (Turing NVDEC has it).
- **Encode**: hardware H.264 and HEVC through VideoToolbox (OBS, HandBrake, FaceTime, screen sharing).
- **Stats**: GPU, encoder and decoder utilization in Activity Monitor's GPU History and iStat Menus.
- **Metal**: Metal apps (Safari/WebGL, Photos, Final Cut-class apps, Blender) render correctly.

## Notes

- **Machine**: RTX 2060 6 GB (TU106), Ryzen 7 5700X3D, one display 2560×1440 @ 180 Hz, macOS 26 Tahoe, OpenCore.
  The stock NullMoth driver is installed through 1401; the OpenCore picker starts macOS with or without it.
- **Hard constraint**: BAR1 is 256 MB and cannot grow. Turing's resizable-BAR capability offers 64/128/256 MB only.
  Every design works within it.
- **Only this card matters.** Hardcoding for TU106 / 6 GB / 256 MB BAR1 is fine; a property check is used where it
  costs nothing, but no effort goes into keeping other cards working.
- **Fork-only, never upstream.** Work lives on `H-Sami/nvidia-macos-driver`, branch `rtx2060`, pinned to upstream tag
  `v2.5.5`; rebase only at points we choose. Upstream (`nullmoth/nvidia-macos-driver`) closes AI-written PRs, issues
  and comments: never post anything there.
- **Everything is fair game**: plugin, translator, NVK patch, kexts, and the prebuilt video libraries if they block
  video. Kext changes stay to what measurements prove necessary; the picker's "start once without NVIDIA driver"
  entry is the way back from a bad kext.
- **Where work happens**: Claude Code on the Tahoe install builds, installs and measures. This Windows clone plans and
  reads code. HITL tasks are run by the owner on Tahoe.
- **Measure, don't feel**: every spec's acceptance target is a number from the harness, compared with the stock
  baseline.
- **Skills**: `research` for research tickets; `diagnosing-bugs` for anything profiling a hitch or slowdown;
  `grilling` + `domain-modeling` for decisions. Vocabulary lives in `GLOSSARY.md` at the repo root.
- Upstream issues already show the shape of the problem: #399, #169 and #92 (BAR1 surface budget on 256 MB cards),
  #370 (shader translation on WindowServer's thread), #356 (~20 ms of WindowServer CPU per frame while dragging),
  #324 (utilization through RM GPUMON), #231 (RTX 2060 on Tahoe: copy-engine queue fails, video decode fails).

## Decisions so far

<!-- one line per closed ticket: [title](issues/NN-slug.md): gist -->

## Not yet specified

- **Surface memory on a 256 MB BAR1**: which surfaces get BAR1 at all, how long they keep it, and how the rest reach
  the compositor without the per-frame copy path. Waits on how BAR1 is spent, the community survey and the baseline.
- **WindowServer frame cost at 180 Hz**: what to change in the plugin's compositor path so a frame fits in 5.5 ms;
  how frames are paced to the display.
- **Shader warm-up**: whether to share, persist or precompile translations so login, app launch and Settings icons
  stop paying for them; moving translation off the thread that waits for it.
- **Utilization design**: where the GPUMON sampling runs (kext client, daemon, plugin) and which
  `PerformanceStatistics` keys Activity Monitor and iStat read.
- **Video decode**: whether the prebuilt decoder libraries can be kept or must be replaced; VP9; decode in sandboxed
  apps; the Turing copy-engine failure.
- **Video encode**: whether Turing NVENC holds up through VideoToolbox clients (OBS, HandBrake, FaceTime, screen
  sharing).
- **Metal gaps**: which real apps fail or render wrong on this card, once the desktop is smooth enough to tell.
- **Display at 180 Hz**: whether the 2560×1440 @ 180 Hz mode (DisplayPort bandwidth, DSC, 10-bit) is driven right.
- **Keeping up with upstream**: when and how to rebase `rtx2060` onto later upstream tags without losing comparable
  measurements.

## Out of scope

- The Intel CPU name in About This Mac: it comes from the SMBIOS model (MacPro7,1), not the GPU driver. Fix
  separately in OpenCore (`RestrictEvents.kext` with `revcpuname=`).
- Gaming performance tuning beyond Metal correctness.
- AV1 decode and encode: Turing's NVDEC and NVENC have no AV1.
- Other NVIDIA cards, and contributing anything upstream.
