# Write the measurement harness

Type: task
Status: open
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
