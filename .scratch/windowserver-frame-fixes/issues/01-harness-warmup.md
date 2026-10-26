# 01: Harness warm-up pass and a cold-cache flag

**What to build:** the harness can warm WindowServer's SPIR-V cache itself and says in every run whether the cache was
cold. `--warmup` runs each selected scenario once, unrecorded, before the measured pass; the run folder holds only the
measured pass. Each run reports the `coreanimation.pipelines` queue CPU taken from its WindowServer spindumps, and
`compare.py` shows it beside the other numbers, so a cold run is visible from its results alone. See the spec
(`../spec.md`), step 0, and user stories 8, 9, 31, 32.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] `run.sh --warmup` runs every selected scenario once before the measured pass and records nothing from the warm-up.
- [ ] Each scenario's summary carries its `coreanimation.pipelines` CPU, and `compare.py` prints it for both runs.
- [ ] A cold run is flagged (pipelines CPU above a few tenths of a second) in the summary and in `compare.py`.
- [ ] `--warmup --only desktop` on the current install comes out warm, and its numbers sit within the 3% guard of the
      last warm local run.
- [ ] The harness README documents `--warmup` and the flag.
