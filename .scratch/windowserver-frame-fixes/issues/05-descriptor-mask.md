# 05: mickys' descriptor-mask fix

**What to build:** WindowServer's descriptor writes cut to what actually changed, by cherry-picking mickys'
descriptor-mask fix as it is (adapted only if it conflicts with 04 or a measurement forces it, noted in the progress
log). See the spec, step 2, and user story 19.

**Blocked by:** 04 (Cache VRAM IOSurface imports).

**Status:** ready-for-agent

- [ ] The fix is on the branch as its own commit, crediting the original.
- [ ] The Metal self-test passes.
- [ ] Installed, `--warmup --only desktop` passes the 3% guard against the step-0 baseline in every desktop scenario.
- [ ] The run's numbers, with descriptor-building CPU per frame from the spindumps, are logged in the spec's progress.
