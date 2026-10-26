# 03: Prefactor: the VRAM import as a shared object

**What to build:** the VRAM import behind an IOSurface wrapper (the imported buffer and its image alias) becomes one
reference-counted object that wrappers hold, instead of a buffer each texture owns and frees itself. No behaviour
changes: each wrapper still makes its own import, exactly as today. This makes ticket 04's cache a small change. See the
spec, step 1.

**Blocked by:** None (can start immediately).

**Status:** ready-for-agent

- [ ] Wrappers over family VRAM hold the shared import object; the import is freed when the last holder goes.
- [ ] Views and the private-image path (surfaces that can't share family VRAM) behave as before.
- [ ] The Metal self-test passes with the local plugin.
- [ ] The surface-wrapper bench passes, including the widths that take the private-image path.
