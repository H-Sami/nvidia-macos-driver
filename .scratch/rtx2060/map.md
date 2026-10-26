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
- **Working constraint**: BAR1 is 256 MB and cannot grow. This card's Resizable BAR capability offers 64/128/256 MB
  only (mask `0x1c0`), so upstream PR #62's 8 GiB RTX 2060 does not apply here; designs assume 256 MB.
- **Only this card matters.** Hardcoding for TU106 / 6 GB / 256 MB BAR1 is fine; a property check is used where it
  costs nothing, but no effort goes into keeping other cards working.
- **Fork-only, never upstream.** Work lives on `H-Sami/nvidia-macos-driver`, branch `rtx2060`, pinned to upstream tag
  `v2.5.5`; rebase only at points we choose. Upstream (`nullmoth/nvidia-macos-driver`) closes AI-written PRs, issues
  and comments: never post anything there.
- **Everything is fair game**: plugin, translator, NVK patch, kexts, and the prebuilt video libraries if they block
  video. Kext changes stay to what measurements prove necessary; the picker's "start once without NVIDIA driver"
  entry is the way back from a bad kext.
- **Where work happens**: one machine, dual-booting Windows 11 and Tahoe, so only one OS runs at a time. Claude Code on
  Tahoe builds, installs and measures; on Windows it plans and reads code. HITL tasks are run by the owner on Tahoe.
  Nothing runs in parallel across the two: a Tahoe ticket and a Windows ticket never overlap, and a measurement run
  has the machine to itself. Group Tahoe work into one boot where possible, since every switch is a reboot.
- **Measure, don't feel**: every spec's acceptance target is a number from the harness, compared with the stock
  baseline.
- **Skills**: `research` for research tickets; `diagnosing-bugs` for anything profiling a hitch or slowdown;
  `grilling` + `domain-modeling` for decisions. Vocabulary lives in `GLOSSARY.md` at the repo root.
- Upstream issues already show the shape of the problem: #399, #169 and #92 (BAR1 surface budget on 256 MB cards),
  #370 (shader translation on WindowServer's thread), #356 (~20 ms of WindowServer CPU per frame while dragging),
  #324 (utilization through RM GPUMON), #231 (RTX 2060 on Tahoe: copy-engine queue fails, video decode fails).

## Decisions so far

<!-- one line per closed ticket: [title](issues/NN-slug.md): gist -->

- [How BAR1 is spent on a 256 MB card](issues/05-how-bar1-is-spent.md): BAR1 fills with idle kernel mappings of
  surface VRAM, so the space goes to how the code is arranged, not CPU need; levers listed, counters to measure on Tahoe.
- [Shader translation and pipeline cost](issues/06-shader-translation-cost.md): translation and NAK run on the
  calling thread with per-process, rebuild-invalidated caches and blocking cache I/O; Apple compiles once, out of process.
- [Survey community fixes](issues/04-community-fixes-survey.md): older small-BAR fixes are in 2.5.5; a ranked shortlist
  from Dora-z, mickys, NvGfx, #399 and PRs #380/#187 covers BAR1, WindowServer, uploads, shader cache, stats and video.
- [WindowServer's frame cost while compositing](issues/07-windowserver-frame-cost.md): ~20 ms is fixed plugin CPU per
  frame (per-draw rebinds, a global lock per texture bind, uncached VRAM wrappers), not GPU or flip; profiling plan set.
- [Exposing GPU utilization to macOS](issues/08-exposing-utilization.md): monitors read `Device Utilization %`; NVRM's
  existing kernel RM client can sample GPUMON on a thread_call, so no daemon is needed; key choice to verify on Tahoe.
- [The Turing video path on Tahoe](issues/09-turing-video-path.md): the right Turing codecs load and Safari is served via
  VTDecoderXPCService; -13 is harmless; gaps are VP9, CPU untiling at 4K, a first-lookup race and one encoder session.

- [Write the measurement harness](issues/01-measurement-harness.md): `tools/rtx2060/run.sh` records the 10/10 list
  into `~/rtx2060-runs/`; it needs Accessibility, Safari's Apple Events JavaScript and `--sudo` for a full run; first
  smoke numbers: 4K H.264 decode 44 fps, Dock and Mission Control ~66 fps.
- [Capture the stock baseline](issues/02-stock-baseline.md): every desktop scenario misses 180 Hz (bursts 63-120
  fps, 15-window drag 19.7 ms of WindowServer CPU per frame); 87,892 surface refusals in 30 minutes of normal use; first
  launches 2.6-3.8 s; 4K H.264 decodes at 45 fps; no utilization keys. Runs in `baseline/`.
- [Build the fork from source on Tahoe](issues/03-build-fork-on-tahoe.md): `build/rtx2060/build.sh` builds all but
  NVRM with Command Line Tools; NVRM and other unbuildable parts come from 2.5.5; boots with Metal 3, but WindowServer
  CPU runs up to 2× stock in desktop animations (ticket 19).

## Not yet specified

- **Metal gaps**: which real apps fail or render wrong on this card, once the desktop is smooth enough to tell.
- **Display at 180 Hz**: whether the 2560×1440 @ 180 Hz mode (DisplayPort bandwidth, DSC, 10-bit) is driven right, and
  how frames are paced to it once a WindowServer frame fits in 5.5 ms.
- **Keeping up with upstream**: when and how to rebase `rtx2060` onto later upstream tags without losing comparable
  measurements.

## Out of scope

- The Intel CPU name in About This Mac: it comes from the SMBIOS model (MacPro7,1), not the GPU driver. Fix
  separately in OpenCore (`RestrictEvents.kext` with `revcpuname=`).
- Gaming performance tuning beyond Metal correctness.
- AV1 decode and encode: Turing's NVDEC and NVENC have no AV1.
- Other NVIDIA cards, and contributing anything upstream.
