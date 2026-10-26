# 06: NvGfx `bd09e42`: the cheaper writer key

**What to build:** texture binds stop building a string key and stop taking the global command-buffer class lock for
the pending-write record, by cherry-picking NvGfx `bd09e42` as it is (adapted only if it conflicts or a measurement
forces it, noted in the progress log). See the spec, step 3, and user story 20.

**Blocked by:** 05 (mickys' descriptor-mask fix).

**Status:** ready-for-agent

- [ ] The commit is on the branch as its own commit, crediting the original.
- [ ] The Metal self-test passes.
- [ ] Installed, `--warmup --only desktop` passes the 3% guard against the step-0 baseline in every desktop scenario.
- [ ] The run's numbers are logged in the spec's progress.
