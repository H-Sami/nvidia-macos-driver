# Write the measurement harness

Type: task
Status: resolved
Blocked by:

## Question

What does one repeatable command on Tahoe have to record so every later spec can state its acceptance target as a
number and compare against the stock baseline?

Done when `tools/rtx2060/` on `rtx2060` holds a harness that runs unattended on Tahoe (one command, results to a dated
folder, nothing uploaded) and covers the 10/10 list on the map:

- driver state: versions, the `nvrm-gpu-profile` property (BAR1, VRAM, engine classes), boot-args, and the BAR sizes
  the card's resizable-BAR capability offers (from NVRM's log or PCI config space; PR #62 claims an RTX 2060 offered
  8 GiB);
- surface memory: `debug.nvaccel_vm_*` and `debug.nvrmfb_vram_*` counters before and after the run;
- desktop: flips per second and a frame-gap histogram (`debug.nvaccel_iop_flips`, present stats) during a scripted
  window drag, plus Dock and Mission Control, with WindowServer CPU and a `spindump` across it;
- launch: cold and warm launch time of a few apps and of System Settings, and shader-cache size before and after;
- video: which decoders and encoders VideoToolbox reports as hardware (`tools/vtdump.py`), 4K60 H.264 and HEVC
  playback with a dropped-frame count, and a hardware encode of a test clip;
- stats: what `PerformanceStatistics` holds.

The profiling plan in [WindowServer's frame cost while compositing](07-windowserver-frame-cost.md) (spindump and
Instruments during an 8 s drag, varying window count, refresh and size; A/B through `nvrm610.conf`) and the
measurements listed in the answers of [How BAR1 is spent](05-how-bar1-is-spent.md) and
[Shader translation and pipeline cost](06-shader-translation-cost.md) belong in the harness too, as do the Tahoe
checks in [The Turing video path on Tahoe](09-turing-video-path.md) (decoder registration per process,
`VTDecoderXPCService` samples and drops at 4K60 H.264/HEVC/Main10, the codec YouTube serves Safari, which encoders
OBS, HandBrake, FaceTime and Screen Sharing pick, BAR1 counters during playback and encode).

Run on the Tahoe install with Claude Code there; the existing `tools/bench_*.m` and `tools/glbench` are the starting
point. The harness must work against the stock driver, since the baseline is taken with it.

## Answer

The harness is `tools/rtx2060/run.sh` on `rtx2060`: one command, about 6 minutes, results to
`~/rtx2060-runs/<date>-<label>/` (`summary.md`, a flat `summary.json`, `raw/`), nothing uploaded.
`compare.py BASE RUN` diffs two runs metric by metric. It runs against stock 2.5.5 and was smoke-tested on this machine
on 2026-10-26. `tools/rtx2060/README.md` lists every metric.

What one run records, per row of the 10/10 list:

- **State**: versions, binary hashes, `nvrm-gpu-profile`, boot-args, `nvrm610.conf`, uptime, and NVRM's `bar1:` log
  lines.
- **Desktop**: flips and the gaps between them. `framegap` polls `debug.nvaccel_iop_flips` every 250 us; the summary
  also reports gaps within animation bursts. Also WindowServer CPU % and ms per frame, `debug.nv*` deltas, and a
  WindowServer spindump with `--sudo`. Scenarios: idle, three 8 s title-bar drags (small, large, over 14 windows),
  Dock sweep, Dock minimize, Mission Control, Safari scroll.
- **Launch**: time to first on-screen window, first and second launch, for six apps including System Settings; shader
  cache folder sizes before and after; whether a Mesa disk cache exists.
- **Video**: encoders listed before and after a Metal device. Hardware-only 4K60 encode of H.264, HEVC and HEVC
  Main10, then hardware-only decode of each clip. 10 s of AVPlayer playback, with frames shown, dropped and short of
  real time. The same clips in Safari, started with `play()` over Apple Events and counted with
  `requestVideoFrameCallback` (Safari blocks the autoplay and leaves `getVideoPlaybackQuality()` at 0 outside MSE),
  and `sample VTDecoderXPCService` with `--sudo`.
- **Stats**: every `PerformanceStatistics` key.
- **Login**: `login-agent.sh install` measures the next login once: 240 s of WindowServer CPU, flips and refusals per
  second.

Facts found while building it:

- **BAR1 cannot grow on this card.** The Resizable BAR capability offers 64, 128 and 256 MB only (mask `0x1c0`; the
  firmware leaves 64 MB and NVRM resizes to 256 MB). The 256 MB working constraint is confirmed, and PR #62's 8 GiB
  does not apply here.
- **Encoders register only after a Metal device.** Before one, VideoToolbox lists no hardware H.264/HEVC encoder;
  after it, `com.nvmtl.videoencoder.{avc,hevc}.nvenc` appear. A probe that skips the device reports "no hardware
  encoder".
- **`tools/vtdump.py` is a kext vtable dumper**, not a VideoToolbox lister as this ticket assumed. `vt list` does
  that job.
- **Owner setup is needed before a full baseline**:
  - Accessibility for the app running the harness. Until then the drags, Dock sweep and Safari scroll are skipped.
  - Safari's "Allow JavaScript from Apple Events", for Safari's drop counts.
  - `--sudo` for spindump, sample and purge, since Debugging Restrictions are on.
  - Instruments is unavailable: this machine has Command Line Tools only.
- **Smoke-run numbers on stock 2.5.5**, indicative only; the baseline ticket takes the real ones:
  - 4K hardware H.264 decode runs at 44 fps, and AVPlayer plays it at 39 fps, slowing down instead of dropping.
    HEVC decodes at 345 fps and Main10 at 259.
  - Hardware encode runs at 156 fps (H.264), 109 fps (HEVC) and 78 fps (Main10).
  - Dock minimize and Mission Control animate at about 66 fps within bursts at 180 Hz.
  - 1,578 VRAM refusals had piled up since boot.
  - `Device Utilization %` is absent.
  - Time to first window is 0.8–1.5 s across the six apps.
