# Spec: WindowServer per-frame fixes

Status: ready-for-agent

Comes from the rtx2060 map, ticket 12 (Choose the WindowServer per-frame fixes); its Answer and the stock-warm
profile (`.scratch/rtx2060/profiles/2026-10-26-stock-warm-windowserver-split.md`) hold the numbers this spec is built on.

## Problem Statement

On this RTX 2060 (TU106, 6 GB, 256 MB BAR1) at 2560×1440 and 180 Hz, moving windows never feels native. In the
stock baseline a small-window drag runs at about 117 fps, a large-window drag at 90, and a drag with 15 windows open at
63 fps with hundreds of hitches, and frames land on every third refresh. The cause is CPU time on WindowServer's
compositing thread, not the GPU: in the 15-window drag WindowServer spends 18.8 ms of CPU per frame, against a
180 Hz budget of 5.5 ms.

About 8 ms of that is the driver on WindowServer's main thread: 3.1 ms building descriptor sets per draw, 2.9 ms
re-importing the same IOSurfaces into VRAM textures every frame (four kernel calls each, plus an `open` of
`/dev/null`), 1.9 ms of other encoding, and smaller costs in commit and the writer key. The plugin's worker thread
spends another ~2.6 ms a frame freeing those same imports, mostly in NVRM zeroing GPU page tables, and holds the
driver lock the main thread then waits on. WindowServer's and Core Animation's own work is 5.8 ms, already over the
budget on its own, and nobody yet knows how much of it the driver causes.

## Solution

Every window drag, including the 15-window one, holds 180 Hz: WindowServer's main thread spends under 5.5 ms of CPU
per frame and no frame gap within the drag exceeds 11 ms (two refresh periods), measured by the harness on warm runs.

The work goes lever by lever, each one its own commit and its own measured harness run, in a fixed order: first make
measurements trustworthy (a warm-up pass, a fresh-boot recheck, a local warm baseline); then cache the VRAM IOSurface
imports so WindowServer stops re-importing and freeing the same surfaces every frame; then mickys' descriptor-mask
fix; then NvGfx `bd09e42` (cheaper writer key, off the global lock). After that the spec loops: re-profile, take the
largest remaining cost, fix it, measure, until every drag holds 180 Hz. Breaking down WindowServer's own 5.8 ms for
driver-caused work is part of that loop. If some of it proves to be WindowServer's alone, the spec stops and reports it
with evidence; the owner decides, the spec never relaxes its target.

## User Stories

1. As the owner, I want a window drag to hold 180 Hz, so that moving a window looks as smooth as on a real Mac.
2. As the owner, I want a drag with 15 windows open to hold 180 Hz too, so that a busy desktop doesn't fall back to
   every third refresh.
3. As the owner, I want a large-window drag to hold 180 Hz, so that window size doesn't decide smoothness.
4. As the owner, I want no hitch over 11 ms during any drag, so that motion never visibly freezes.
5. As the owner, I want the Dock, Mission Control and Safari scrolling to get no worse while drags are fixed, so that
   one gain isn't paid for elsewhere.
6. As the owner, I want every fix measured on its own, so that I know what each one bought and can revert one alone.
7. As the owner, I want each fix's numbers logged in this spec's progress, so that the history of the gains is
   readable later without rerunning anything.
8. As the owner, I want every comparison made on a warm SPIR-V cache, so that a rebuilt translator's one-time
   retranslation never shows up as a regression or hides one.
9. As the owner, I want the harness to warm the cache itself, so that warming up can't be forgotten.
10. As the owner, I want the drag-small gap between the local build and stock (105 vs 115 fps) settled on a fresh boot
    before any fix, so that every fix is measured against a baseline I trust.
11. As the owner, I want a drag-small gap that survives the fresh boot handed to `diagnosing-bugs` before the fixes
    start, so that a hidden regression in the local build doesn't skew every later number.
12. As the owner, I want WindowServer to import each IOSurface into VRAM once and reuse it while the surface lives, so
    that the per-frame import and free disappear.
13. As the owner, I want a cached import released as soon as WindowServer drops its surface, so that VRAM on a 6 GB
    card isn't held for dead surfaces.
14. As the owner, I want the import cache bounded, so that a surface-heavy session can't grow it without limit.
15. As the owner, I want surface refusals, pinned VRAM and BAR1 use to not rise with the cache, so that the fix doesn't
    hurt the surface budget.
16. As the owner, I want a reused IOSurface ID never to get another surface's stale import, so that windows never show
    wrong pixels.
17. As the owner, I want what one wrapper writes into a cached surface to be seen by the next wrapper, so that
    compositing stays correct.
18. As the owner, I want the per-import `open("/dev/null")` gone, so that sandbox and endpoint-security checks stop
    costing WindowServer a quarter millisecond a frame.
19. As the owner, I want WindowServer's descriptor writes cut to what actually changed, so that the 3.1 ms of
    descriptor building per frame shrinks.
20. As the owner, I want the writer key off the global command-buffer lock and cheap to build, so that texture binds
    stop allocating strings and contending with the worker.
21. As the owner, I want a fresh spindump profile after the three planned fixes, so that the next lever is chosen from
    data, not from the old guess list.
22. As the owner, I want the loop to keep going until every drag holds 180 Hz, so that the spec ends at native
    smoothness, not at a planned list.
23. As the owner, I want WindowServer's own CPU per frame broken down for driver-caused work (IOSurface lock and seed
    traffic, waits counted against Core Animation, slower Core Animation paths chosen because of what the plugin
    reports), so that the 5.8 ms isn't assumed to be untouchable.
24. As the owner, I want a report with evidence if some of WindowServer's own time can't be cut, so that I decide what
    happens to the target, not the implementer.
25. As the owner, I want any lever that needs a kext change split into its own map ticket blocked by "Make NVRM
    buildable", so that this spec doesn't stall on a build that doesn't exist yet.
26. As the owner, I want no runtime switch per fix, so that there are no dead code paths to keep alive.
27. As the owner, I want the NvGfx and mickys changes cherry-picked as they are, so that tested code isn't rewritten
    without a measured reason.
28. As the owner, I want the Metal self-test to pass after every fix, so that a speed-up never breaks rendering.
29. As an implementer, I want a check that exercises the import cache from a user-space Metal process with the local
    plugin, so that I can test reuse, sweeping and staleness without logging out.
30. As an implementer, I want the harness's per-run output (fps, gaps, WindowServer CPU per frame, counters,
    spindumps) compared with `compare.py` against the step-0 baseline, so that the 3% guard is mechanical.
31. As an implementer, I want the warm-up pass to be discarded from the recorded results, so that a run folder only
    holds the measured pass.
32. As an implementer, I want to know a run's cache was warm from the run itself, so that a cold run can be spotted
    afterwards without guessing.
33. As the owner, I want nothing posted upstream and nothing pushed without my say, so that the fork rules hold.

## Implementation Decisions

- **Targets** (warm runs, against the step-0 local baseline): in drag-small, drag-large and drag-15-windows,
  WindowServer's main thread under 5.5 ms of CPU per frame and no frame gap over 11 ms within the drag burst. The spec
  ends only when all three hold. fps is reported alongside.
- **Regression guard**: after each lever, no desktop scenario (drags, Dock minimize, Dock sweep, Mission Control,
  Safari scroll, idle) more than 3% worse in fps or WindowServer CPU per frame than the step-0 baseline. A lever that
  fails is reworked or dropped.
- **One lever per commit**, no per-lever switch in the driver config. Each commit gets a build, install, a warm-up
  pass and a measured `--only desktop` harness run, with the results appended to this spec's progress log.
- **Order**, each step blocked by the one before it:
  - **Step 0, measurement**: the harness gains a `--warmup` option that runs each selected scenario once, unrecorded,
    before the measured pass; it is required for every comparison in this spec. The run also records the
    `coreanimation.pipelines` queue CPU from the spindumps, so a cold cache is visible in the results. Then, on a fresh
    boot, the drag-small recheck against stock-cold; if the local build is still low it goes to `diagnosing-bugs` and
    the levers wait. Then the local build's warm baseline, which every later step compares with.
  - **Step 1, VRAM import cache** in the plugin's IOSurface texture path: a strong cache of the VRAM import (the
    buffer and its image alias), keyed by IOSurface ID, plane and format, holding a retain on the IOSurface. Each
    commit sweeps entries whose IOSurface only the cache still holds (retain count 1 or not in use); a hard cap of
    about 512 entries with LRU eviction backs it. Each wrapper becomes a view on the cached import. The per-import open
    of `/dev/null` goes in the same commit. The existing surface cache, which is weak and only holds failed imports,
    is folded into the new one or left alone, whichever keeps the private-image sharing rule intact (wrappers of a
    refused surface must still share one private image).
  - **Step 2**: mickys' descriptor-mask fix, cherry-picked.
  - **Step 3**: NvGfx `bd09e42` (writer key cheaper and off the global command-buffer class lock), cherry-picked.
  - **Step 4, loop**: re-profile drag-15-windows, drag-small and drag-large with spindumps; take the largest remaining
    cost on WindowServer's main thread or the plugin's worker; fix it as one commit under the same guard; repeat until
    the targets hold. Each pass breaks down WindowServer's own CPU for driver-caused work. A lever needing a kext change
    becomes a new rtx2060 map ticket blocked by "Make NVRM buildable" instead of work here. If WindowServer's own work
    alone keeps a drag over 5.5 ms, stop and report with spindump evidence.
- **Cherry-picks** apply as they are; they are adapted only when a measurement or a conflict with an earlier lever
  forces it, and the adaptation is noted in the progress log.

## Testing Decisions

- A good test here checks behaviour the owner or WindowServer can see: frame timing and CPU per frame from the
  harness, pixels and object lifetimes from Metal, never internal call counts as the pass condition. Call counts and
  spindump shares are diagnostics for choosing levers, not acceptance.
- **The harness** is the acceptance seam: the targets and the 3% guard are judged from its warm runs and `compare.py`.
  Its only change is the `--warmup` option and the warm/cold indicator.
- **The surface-wrapper bench** is extended into the import-cache check, run from a user-space Metal process that
  loads the local plugin by `NM_TEST_PLUGIN`: rewrapping the same IOSurface reuses the import (wrapper cost per frame
  drops); a write through one wrapper is read back through the next; a released IOSurface is swept and its VRAM freed;
  an IOSurface ID reused after release never gets the old import; the cap and LRU eviction hold under more surfaces
  than the cap; widths that can't share family VRAM still take the private-image path and share one image.
- **The Metal self-test** runs after every lever as the rendering-correctness guard; its surface-order checks cover the
  paths the cache and the descriptor mask touch.
- Prior art: the surface-wrapper and surface-order benches (Metal processes that build wrappers over IOSurfaces and
  check pixels), the self-test runner, and the harness runs in the rtx2060 baseline folder.

## Out of Scope

- NvGfx `18996e2` (skip a repeated pipeline set) and `c73ea10` (remember the sampler variant): measured at about zero.
- Batching per-surface kernel calls at commit: about 0.1 ms per frame.
- NVRM's GPU page-table zeroing on map and unmap: a kext change, blocked by "Make NVRM buildable"; the import cache
  removes most of those calls.
- Keeping the composited frame in VRAM, and letting submit-ahead take parts with host copies: they belong to the
  surface-memory strategy and surface upload design tickets.
- Frame pacing to the 180 Hz display mode and the display link itself: the map's "Display at 180 Hz" item.
- Why the Dock misses 180 Hz while WindowServer is mostly idle: rtx2060 ticket 20. Here the Dock is only under the
  regression guard.
- Other cards, and anything upstream.

## Further Notes

- Profile numbers (stock-warm, ms of CPU per frame): drag-15-windows 18.8 whole process (main 13.9, worker 2.6);
  drag-small 7.7 (main 6.4); dock-sweep 13.5 with the main thread 85% idle.
- Work happens on Tahoe only, on the `rtx2060` branch. Every reinstall of a changed translator empties the SPIR-V cache,
  which is why the warm-up is mandatory. Plugin-only rebuilds keep the translator's hash, but the warm-up still runs.
- Claude runs every harness and sudo step; the owner only reboots (fresh-boot recheck in step 0).

## Progress

<!-- one entry per ticket: run folder, headline numbers against the step-0 baseline, verdict -->
