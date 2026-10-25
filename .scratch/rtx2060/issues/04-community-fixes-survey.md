# Survey community fixes

Type: research
Status: resolved
Blocked by:

## Question

What have others already built or measured that bears on a small-BAR Turing card on 2.5.5, and what is each worth to
us: what it changes, what it measured, whether it is already in 2.5.5, and whether it applies cleanly?

Start from: the `hostpages-2.5.4.diff` in upstream #399; PR #200 (keep a surface's VRAM across page-off) and #178
(host-copy coherence); watchthelight-labs/NvGfx (WindowServer draw path, #356; translator cache, #370); the #324
utilization daemon; other open upstream PRs and forks touching BAR1, the copy path, compositing, shader caching,
video or stats.

## Answer

Most older small-BAR fixes are already in 2.5.5 (#200, #245, #296, #177/#178, #64, #62). What remains is in three
forks and #399; the biggest is Dora-z's unmapped VRAM grants, tested on a GTX 1660 SUPER (TU116, 6 GB, 256 MB BAR1,
180 Hz), nearly this machine. All numbers are the authors' own, none from a TU106 on Tahoe.

Ranked shortlist:

1. Dora-z unmapped VRAM grants, a 48→96 MB BAR1 margin for NVENC, and WindowServer read marks (`d34ea85`, `1bf8737`,
   `40e9f96`, `b49176f`): 0 refusals with about 1.2 GB on unmapped grants; one hand merge, NVAccel + NVRMFB only.
2. mickys descriptor-mask fix: WindowServer's descriptor writes from 2.2 M/s to 35 k/s; a few lines.
3. WindowServer draw-path caching (NvGfx `37f2af4`, `18996e2`, `c73ea10`, or Dora-z `d0b2ee5`): drags 75→148
   flips/s on a fork; applies cleanly.
4. mickys page cache + async upload (or Dora-z `5cb3eba`): Safari 73→128 updates/s (4090), drags 36→45 fps (1660S).
5. #399 hostpages parts 1 and 3: GPU readback into the surface's own pages (1,258→389 µs CPU per frame), and the Mesa
   shader cache re-enabled for apps reopened at login.
6. Upstream PR #380 GPU utilization: covers the Stats goal; needs an NVRM rebuild.
7. mickys/nvenc decoders: VP9, H.264 4K 36→121 fps (TU117) through the `NVMTL_NVENCVT` hook; Safari can't use it.
8. NvGfx `cache-write-async` + `2b41c23`: shader-cache writes off the compositor thread, hit/miss counters.
9. Upstream PR #187 FxHash translator: 1.27× faster translation; needs a rebase.
10. Dora-z `nvfbscalehz`: only if a HiDPI mode at 180 Hz is wanted.

Open: Dora-z's grants were only tested on macOS 15, and new VRAM is not zero-filled; the four upload designs (Dora-z,
mickys, NvGfx `9eae44d`, #399) conflict, so choosing one is a spec decision; whether mickys/nvenc's decoders register on
TU106 is unverified; PR #62's author reports an RTX 2060 exposing an 8 GiB BAR1, which contradicts the map's 256 MB
ceiling (checked by the harness); #380 needs an NVRM build the fork doesn't have yet (NvGfx and Dora-z have harnesses
to copy).

Findings: branch `research/community-fixes`, file `research/community-fixes.md`.
