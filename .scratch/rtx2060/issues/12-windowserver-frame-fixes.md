# Choose the WindowServer per-frame fixes

Type: grilling
Status: open
Blocked by:

## Question

Which of the levers in [WindowServer's frame cost while compositing](07-windowserver-frame-cost.md) go into the
spec, in what order, so a WindowServer frame fits in 5.5 ms at 180 Hz with no frame gap over 11 ms during drag, Dock
and Mission Control?

Candidates: the NvGfx changes `18996e2` (skip a repeated pipeline set), `c73ea10` (remember the sampler variant) and
`bd09e42` (cheaper writer key, off the global lock); mickys' descriptor-mask fix; caching VRAM IOSurface wrappers;
cutting descriptor churn per layer; letting submit-ahead take parts with host copies; batching per-surface kernel
escapes at commit; keeping the composited frame in VRAM. Settle with the baseline's profile: the split by thread
between encoding, commit, the scheduled wait and the kernel copy.
