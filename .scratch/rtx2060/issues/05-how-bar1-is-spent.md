# How BAR1 is spent on a 256 MB card

Type: research
Status: resolved
Blocked by:

## Question

On a card whose 256 MB BAR1 is smaller than its 6 GB of VRAM, what takes BAR1 space, for how long, and what happens
to a surface that is refused? Follow it from NVRM's placement of BAR1, through NVRMFB's surface budget, grants and
kernel mappings, and NVAccel's `NVVidMemory` wire/unwire, to the plugin's "family VRAM import refused - private image
+ copies" fallback and NVK's `LOCAL+mapped memory -> system RAM` choice.

The answer should say which of these spend BAR1 because the CPU must touch the memory and which only because of how
the code is arranged, what the copy path costs per frame at 2560×1440, and what Apple's IOAccelerator model actually
requires to be CPU-visible. Upstream #399, #169 and #92 have measurements from 256 MB cards.

## Answer

Almost all of BAR1 goes to kernel mappings of IOSurface VRAM that nothing on the normal path reads, so the space is
used up by how the code is arranged, not because the CPU needs it. Apple's model does not require VRAM to be
CPU-mapped either.

- The live framebuffer code is `kexts/NVRMFB/fb/nvrm-fb.cpp` (`kexts/NVRM/fb/` is an old copy). After display arm the
  surface budget is BAR1 − scanout − cursor − 16 MB, about 236 MB at 1440p; the 192 MB figure only applies before arm.
- `vramGrant` maps every granted VRAM block into the kernel for the surface's whole life; NVAccel's unwire parks the
  block with its mapping still held. The plugin imports it GPU-only, page-off uses the copy engine and zero-copy flips
  go by handle, so the mapping is idle on the normal path.
- What truly needs BAR1: the boot console, cursor (256 KB), gamma tables, and the 14.7 MB scanout only while on the
  copy path.
- A refused surface becomes a private image plus copies (GPU copy, fence wait, CPU memcpy, and back), estimated at
  2–4 ms per full-screen change plus about 1.2 ms in WindowServer; a refused composited frame adds 2.5–5 ms of kernel
  CPU per frame. The 180 Hz frame budget is 5.56 ms. (Estimates, not measured.)
- Candidate levers: grants with no kernel mapping, mapping on demand, unmapping parked surfaces, exempting only the
  composited frame, a cheaper copy path (#399), asking the GPU firmware for the real free/largest-free BAR1, and
  dropping the scanout mapping while flips are zero-copy. A larger BAR1 is impossible, and `NVK_LOCAL_MAP_SYSMEM=0`
  does not help.
- To measure on Tahoe: the budget/mapped/refused/parked counters under load, refusals from the budget versus from
  fragmentation, firmware-reported BAR1 free, copy-path timings, whether copy-engine page-off works on this card
  (#231 reports the 2060's copy engine failing on Tahoe), NVK heaps.

Findings: branch `research/bar1-spend`, file `research/bar1-spend.md`.
