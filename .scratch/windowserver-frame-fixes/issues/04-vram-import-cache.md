# 04: Cache VRAM IOSurface imports

**What to build:** WindowServer imports each IOSurface into VRAM once and reuses the import while the surface lives,
so the per-frame import and the worker's per-frame free disappear. A strong cache of the shared import, keyed by
IOSurface ID, plane and format and holding a retain on the IOSurface. Each commit sweeps entries whose IOSurface only
the cache still holds, and a cap of about 512 entries with LRU eviction backs it. Wrappers become views on the cached
import. The per-import `open("/dev/null")` goes in the same commit. Wrappers of a refused surface still share one
private image. Built test-first in the surface-wrapper bench. See the spec, step 1, and user stories 12-18.

**Blocked by:** 02 (Fresh-boot drag-small recheck and the local warm baseline), 03 (Prefactor: the VRAM import as a
shared object).

**Status:** ready-for-agent

- [ ] The extended surface-wrapper bench (local plugin through `NM_TEST_PLUGIN`) shows: rewrapping the same IOSurface
      reuses the import and wrapper cost per frame drops; a write through one wrapper is read back through the next; a
      released IOSurface is swept and its VRAM freed; an IOSurface ID reused after release never gets the old import;
      the cap and LRU hold with more surfaces than the cap; private-image widths still share one image.
- [ ] No `open("/dev/null")` per import.
- [ ] The Metal self-test passes.
- [ ] Installed, `--warmup --only desktop` passes the 3% guard against the step-0 baseline in every desktop scenario.
- [ ] Surface refusals, `nvaccel_vm_*` and VRAM counters don't rise against the baseline.
- [ ] The run's numbers, including drag main-thread and worker CPU per frame, are logged in the spec's progress.
