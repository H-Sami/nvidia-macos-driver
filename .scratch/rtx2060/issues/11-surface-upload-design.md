# Choose the surface upload and readback design

Type: grilling
Status: open
Blocked by: 02, 10

## Question

Once the surface-memory strategy is chosen, which design moves pixels between CPU-written IOSurfaces and the GPU:
Dora-z's async upload (`5cb3eba`), mickys' per-IOSurface page cache with async upload, NvGfx `9eae44d`, or #399's
hostpages (GPU readback into the surface's own pages)? They conflict, so this picks one (or a named combination) and
its acceptance target.

Inputs: [Survey community fixes](04-community-fixes-survey.md) for what each measured, the baseline's copy-path
timings, and what is left of the copy path after
[Choose the surface-memory strategy for a 256 MB BAR1](10-surface-memory-strategy.md).
