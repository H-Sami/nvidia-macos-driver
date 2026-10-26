# 02: Fresh-boot drag-small recheck and the local warm baseline

**What to build:** a baseline every lever can be trusted against. After the owner reboots, Claude runs
`--warmup --only desktop --sudo` on the local build soon after login and compares drag-small with the stock runs. If
drag-small is still clearly below stock (105 vs 115 fps before), a `diagnosing-bugs` ticket is opened and blocks 04
onward. Otherwise this run becomes the step-0 baseline the 3% guard and the targets are measured against. See the spec,
step 0, and user stories 10, 11.

**Blocked by:** 01 (Harness warm-up pass and a cold-cache flag).

**Status:** ready-for-human (the owner reboots; Claude runs the rest)

- [ ] A fresh-boot warm run of the local build exists under the rtx2060 runs, flagged warm.
- [ ] drag-small is compared with stock-cold and stock-warm, and the verdict (settled, or a new diagnosing ticket) is
      written into the spec's progress log.
- [ ] The run is named as the step-0 baseline in the spec's progress log, with its headline numbers per desktop
      scenario (fps, p99 gap, WindowServer main-thread and whole-process CPU per frame).
