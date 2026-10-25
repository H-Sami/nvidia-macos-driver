# The Turing video path on Tahoe

Type: research
Status: resolved
Blocked by:

## Question

How do hardware video decode and encode reach VideoToolbox on this driver for a Turing card, and what is known to
break them on Tahoe? Cover where the decoder and encoder libraries come from (they are not in the source tree), how
they are registered and picked per generation, how sandboxed apps (Safari, QuickTime) are served, and why the
copy-engine queue fails on a Turing card (`VkResult -13`, upstream #231).

The answer should also say which codecs Turing's NVDEC and NVENC support that macOS can use (H.264, HEVC, HEVC Main10,
VP9), which are wired up today, and what replacing or extending the prebuilt libraries would involve.

## Answer

On TU106 the plugin picks the right Turing codec libraries and registers them with VideoToolbox. The `VkResult -13`
of #231 is harmless to video: it only hits NVK's internal upload queue, which falls back to a graphics channel. What
threatens the Video and Encode goals is no VP9, a CPU untiling copy at 4K, a race on the first decoder lookup, and
encoder limits. (Code and binary reading; nothing run on a Mac.)

- Libraries: four closed x86_64 dylibs in `NVMTLDriver.bundle/Contents/MacOS/`; TU106 loads `libnvdec_h264_t2d`,
  `libnvdec_hevc`, `libnvenc_h264_tu10x` and `libnvenc_hevc_tu10x`. They are NullMoth's own codecs (not NVIDIA's) and
  reach the GPU themselves through NVAccel/NVRM; `_t2d` is the base decoder with one byte changed (#65).
- Selection: NVRM publishes a per-card profile (Turing, NVDEC `0xC4B0`, NVENC `0xC4B7`, classic tile layout), which
  matches NVIDIA's class table for TU106. The plugin registers them (`NVMTLDevice.m:286-500`) only in processes that
  create a Metal device with NVK running.
- Safari and QuickTime decode in `VTDecoderXPCService`, where a load-time hook registers our decoders
  (`NVMTLDevice.m:439-469`); encoders have no such route.
- Still broken: the first decoder lookup in a fresh process misses ours (#175); one encoder session per process
  (breaks Sunshine, #206); the codec libraries also map through the 256 MB BAR1 and compete with surfaces.
- The -13: NVK builds its upload queue on a copy-only channel and creates the copy object without the parameters
  pre-Ampere RM needs to pick a copy engine (likely cause, from code). The fallback costs start-up time and VRAM per
  process, not per-frame time; page-off doesn't use this queue. #231's decode failure is probably elsewhere (BAR1 100%
  full in the 1650 SUPER report; both reports predate Safari delegation in 2.5.4).
- Codec matrix (hardware / wired today): H.264 8-bit decode yes / yes (no interlaced or scaling-matrix streams; about
  36 fps at 4K on a GTX 1650 because untiling is on the CPU); HEVC Main and Main10 decode yes / yes, untested on Turing;
  VP9 decode yes / no (Safari on a desktop Mac decodes VP9 in software, so 4K YouTube is probably software today);
  H.264 and HEVC encode yes / yes, I and P frames only, HEVC 10-bit untested; no AV1.
- Candidate levers: test mickys' decoders on TU106; load them in `VTDecoderXPCService` too (the only way Safari gets
  VP9 or faster H.264); register a VP9 decoder; reserve BAR1 for the codecs; fix the first-lookup race; allow two
  encoder sessions per process; pass the copy-engine parameters or skip the copy-only attempt on TU106.
- To verify on Tahoe: the card profile in the registry; whether -13 still appears and the retry succeeds; registration
  lines in `nvmtl.log` per process; `sample VTDecoderXPCService` during 4K60 H.264, HEVC and Main10 playback in Safari
  and QuickTime with per-picture timings and drops; which codec YouTube serves Safari; the first-lookup race; whether
  OBS, HandBrake, FaceTime and Screen Sharing pick our encoders; BAR1 counters during playback and encode; HEVC
  output correctness on Turing.

Findings: branch `research/turing-video`, file `research/turing-video.md`.
