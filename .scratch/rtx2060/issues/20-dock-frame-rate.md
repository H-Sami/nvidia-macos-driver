# Why the Dock misses 180 Hz while WindowServer idles

Type: research
Status: open
Blocked by:

## Question

Dock minimize and Dock sweep run at 65-88 fps on stock (worse warm: sweep pauses over 50 ms go from 2 to 88), yet in
the stock-warm dock-sweep spindump WindowServer's main thread is 85% idle and 86% of its CPU is WindowServer's own
work, mostly the Dock's IPC (`profiles/2026-10-26-stock-warm-windowserver-split.md`). So what paces the Dock's
frames: the Dock process, its render path through the plugin, a wait on the GPU or flip, or WindowServer waiting on
the Dock? Profile with `diagnosing-bugs`: spindump the Dock and WindowServer together, and check what each waits on per
frame. The answer names the bottleneck and the lever, and whether it fits the
[WindowServer per-frame fixes](12-windowserver-frame-fixes.md) spec or needs its own.
