# 07: Re-profile and choose the next lever

**What to build:** the next step of the loop, chosen from data. Spindump drag-small, drag-large and drag-15-windows on
the build with 04-06, split CPU per frame by thread and bucket as in the stock-warm profile, and break WindowServer's
own CPU down for driver-caused work (IOSurface lock and seed traffic, waits counted against Core Animation, slower Core
Animation paths chosen because of what the plugin reports). If every drag already holds 180 Hz, the spec is done. See
the spec, step 4, and user stories 21-25.

**Blocked by:** 06 (NvGfx `bd09e42`: the cheaper writer key).

**Status:** ready-for-agent

- [ ] A new profile beside the stock-warm one, in the same shape, for the three drags.
- [ ] The targets checked: main thread under 5.5 ms of CPU per frame and no gap over 11 ms in each drag.
- [ ] One of: the spec marked done; new lever tickets (08 onward) in this folder, each one commit under the guard; a
      kext lever filed as an rtx2060 map ticket blocked by "Make NVRM buildable"; or, if WindowServer's own work alone
      keeps a drag over 5.5 ms, a stop report with spindump evidence for the owner.
