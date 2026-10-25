# Community fixes that bear on a small-BAR Turing card on 2.5.5

Research for ticket `.scratch/rtx2060/issues/04-community-fixes-survey.md`. Surveyed 2026-10-25.

**Gist.** Most of the old small-BAR work (#200, #245, #296, #177/#178, #64, #62) is already in 2.5.5. The big wins left
come from three forks. **Dora-z** (GTX 1660 SUPER, TU116, 6 GB, 256 MB BAR1, 180 Hz: a near twin of this card) gives
surfaces VRAM with no BAR1 mapping, so BAR1 stops limiting them. **mickys** keeps surface page imports and stops
waiting on uploads, which took Safari from 73 to 128 updates/s, and ships open-source NVDEC/NVENC with VP9. **NvGfx**
and #399 cut WindowServer's per-draw and copy-path cost. None of it was measured on a TU106 or on macOS 26 with a
256 MB BAR1, so every item needs our own harness run.

How each item was checked:

- **In 2.5.5?** Grep of the tree at tag `v2.5.5` (the `rtx2060` branch's code is identical to it; only `.scratch/`
  and `GLOSSARY.md` differ), plus `CHANGELOG.md`.
- **Applies cleanly?** `git apply --check` against `v2.5.5`. Where that failed on context alone, a `git cherry-pick`
  or `git merge` into a throwaway detached worktree at `v2.5.5`.
- **Numbers** are the authors' own, quoted with their card. None are ours.

Upstream is `nullmoth/nvidia-macos-driver`, shortened to `NM` below.

---

## 1. Already in 2.5.5 (baseline, nothing to take)

| Item | What it does | Measured (author's card) | Evidence it's in 2.5.5 |
|---|---|---|---|
| [NM PR #200](https://github.com/nullmoth/nvidia-macos-driver/pull/200) keep a surface's VRAM across page-off | `deallocPhysical` parks the allocation, the next `allocPhysical` returns the same memory | Black windows gone (3070); on a TU117 with a 256 MB BAR1 it stopped the iop-flip judder (wavycastic comment) | Landed in 2.0.0. `nvaccel_vm_sticky` and `vm_parked` are in `kexts/NVRM/accel/nvrm-accel.cpp` |
| [NM PR #245](https://github.com/nullmoth/nvidia-macos-driver/pull/245) restore parked VRAM before marking dirty | `IOAccelVidMemory::wire` brings parked memory back, so dirty marks stop failing | **RTX 2060 Super, Tahoe 26.7.1, 1080p75**: 2,798 dirty updates, 0 rejected; WindowServer readbacks 76→0; presents 24.0→32.4/s; flip time 12.14→7.59 ms | Merged in 2.3.6 (`CHANGELOG.md` line 89) |
| [NM PR #178](https://github.com/nullmoth/nvidia-macos-driver/pull/178) host-copy coherence | Refreshes the host copy behind buffers and textures on every submission, including submit-ahead | Pass rate 0/21→21/21 on a 3080 (GeekAudio); 4050 adaptation 0/32→32/32 (`docs/host-copy-coherence-review.md`) | KolliasG7's adaptation is in as `deadee2`; `nvmtl_submission_copies` is in `plugin/NVMTLEventSync.m:512` |
| [NM PR #177](https://github.com/nullmoth/nvidia-macos-driver/pull/177) one private image per IOSurface | Readers and writers share one private image | Preview black tiles fixed; 24/24 tests pass | 2.0.0 changelog (#173/#177/#181/#188/#189) |
| [NM PR #296](https://github.com/nullmoth/nvidia-macos-driver/pull/296) surface-in from the surface's own pages | Imports the IOSurface pages and lets the copy engine read them, instead of a CPU copy | 4K Safari (4090): 20.9→34.3 updates/s; WindowServer CPU 73→56 % | 2.5.1 (`CHANGELOG.md:40`); `NVMTL_SURFIN_UPLOAD` in `NVMTLObjects.m` |
| [NM PR #96](https://github.com/nullmoth/nvidia-macos-driver/pull/96) second staging slot | Defers the upload fence wait | 4K120 (5080): 59.5→114.3 presents/s | **Partly.** `ea99805` landed, then `77e4c98` put the wait back (an image freed right after upload was still being written). mickys re-enables a fixed form (§3) |
| [NM PR #64](https://github.com/nullmoth/nvidia-macos-driver/pull/64) clear granted VRAM with 8-byte stores | `rep stosq` instead of `rep stosb` over BAR1 | 8 MB grant 183→31 ms | Shipped since 1.14.0 |
| [NM PR #62](https://github.com/nullmoth/nvidia-macos-driver/pull/62) BAR1 placement with unused subordinate buses | Loosens the `placeLargeBar1()` guard | "Works on RTX 2060" (author claims ReBAR exposed 8 GiB) | `kexts/NVRM/NVRM.cpp:1154` |
| [NM PR #294](https://github.com/nullmoth/nvidia-macos-driver/pull/294) keep the AIR digest | Stops re-hashing AIR on every lookup | Displays pane CPU 7.7 s→3.6 s per 12 s (5070 Laptop, [NvGfx#6](https://github.com/watchthelight-labs/NvGfx/issues/6)) | `CHANGELOG.md` (2.4.3) |
| [NM PR #289](https://github.com/nullmoth/nvidia-macos-driver/pull/289), [#223](https://github.com/nullmoth/nvidia-macos-driver/pull/223) | Submit-ahead at commit; copy-buffer scan once | — | Merged |
| [NM PR #323](https://github.com/nullmoth/nvidia-macos-driver/pull/323) GPU temperature | 250 ms TSENS read into `PerformanceStatistics` `Temperature(C)` | 51 °C idle / 68 °C load (3080) | 2.5.1 |
| NVENC keyframe `NotSync` fix ([NM #388](https://github.com/nullmoth/nvidia-macos-driver/issues/388)) | Remote-desktop apps find keyframes | — | 2.5.5 changelog, done another way than Dora-z's plugin wrapper (`7ea290a`, which is not needed) |

---

## 2. BAR1 and surface memory

### 2a. Dora-z: surface VRAM without a BAR1 mapping (zero-copy past the budget)

Source: branch [`Dora-z/nvidia-macos-driver@zerocopy-unmapped-vram`](https://github.com/Dora-z/nvidia-macos-driver/tree/zerocopy-unmapped-vram)
(commit `d34ea85`), plus `1bf8737` and `40e9f96` (BAR1 margin) and `b49176f` (read marks) on `bar1-headroom`. Based
on 2.5.4. The fork's README is in Chinese. Test machine: **GTX 1660 SUPER (TU116, 6 GB, 256 MB BAR1), macOS 15.6,
1080p 180 Hz.**

- **What it changes.** NVAccel's `allocPhysical` sends `NVRM_VRAM_FLAG_UNMAPPED_OK`. When the BAR1 budget is spent,
  or `mapMemory` fails below it (fragmentation), NVRMFB's new `vramGrantUnmapped` allocates scanout-type VRAM through
  `fKms->allocateMemory` with no kernel or BAR1 mapping. The GPU reaches it through the RM handle; the cap is
  `debug.nvrmfb_vram_unmapped_cap_mb` (2048). The VRAM is not zero-filled: the plugin uploads system memory first,
  and NVAccel never flips or pages off a copy the plugin has not written. `1bf8737` and `40e9f96` keep a 48 MB, then
  96 MB, BAR1 margin so the NVENC libraries' own BAR1 mappings still fit. `b49176f` makes WindowServer mark the
  shared surfaces it samples; writers wait up to 50 ms, which fixes header flicker while scrolling with zero-copy on.
- **Measured.** BAR1 filled about 20 s after boot. Afterwards there were 4,000+ surfaces and about 1.2 GB on unmapped
  grants with **0 refusals** (stock had tens of thousands of refusals in minutes); counters show the family never
  asked these surfaces for a CPU address. Read marks: about 11 % of writes waited, and the flicker "mostly gone". NVENC
  failed with `NV_ERR_NO_MEMORY` at a 16 MB margin and works at 48 MB; HiDPI streaming needed 96 MB.
- **Corroboration.** On an RTX 2070 Super laptop with a 256 MB BAR1, Exop63 built a local "GPU-only backing" version
  ([NM #169 comment](https://github.com/nullmoth/nvidia-macos-driver/issues/169)). Mapped BAR1 fell from 200 to 71 MB
  and 311,904,480 pixels were checked exact. The separate `surfdirty_no_handle` lifecycle problem remained, possibly
  covered since by #245.
- **In 2.5.5?** No: `vram_unmapped`, `READ_MARKS` and `UNMAPPED_OK` are absent.
- **Applies cleanly?** Partly. `d34ea85` conflicts in one hunk of `nvrm-accel.cpp` against 2.5.5's refusal-log
  throttle (`f675901`, #387), a trivial hand merge. After that, `1bf8737`, `40e9f96` and `b49176f` cherry-pick cleanly.
  It needs a rebuild of NVAccel and NVRMFB only (no NVRM).
- **Caveats.** Built and tested only on macOS 15 (its installer refuses 26). TU116, not TU106. The VRAM is not
  zero-filled.
- **Worth to us: highest.** This attacks the BAR1 constraint itself: surface refusals go to zero and refused windows
  no longer take the copy path. It is the best candidate design for the "Surface memory on a 256 MB BAR1" spec.

### 2b. NM #399 `hostpages-2.5.4.diff` (mrtzygt): make the copy path cheap

Source: [NM #399](https://github.com/nullmoth/nvidia-macos-driver/issues/399), attachment `for-nullmoth.zip`, which
also has `compbench.m`, `surfcheck.m` and `nvtest_device.h`. Test machine: **RTX 2070 SUPER (TU104), 256 MB BAR1,
macOS 26.7.1, 2.5.4, 1080p120.**

- **What it changes** (plugin only, 198 lines):
  1. `nvmtl_vk_image_read_host`: surface-out with `vkCmdCopyImageToBuffer` straight into the imported IOSurface pages,
     with no staging buffer and no CPU memcpy (`NVMTL_SURFOUT_READBACK=cpu` turns it off).
  2. Imported pages kept per texture (`_hostPages`), capped by `NVMTL_HOST_PAGES_MB` (default 256).
  3. Fixes an inherited unwritable `MESA_SHADER_CACHE_DIR`. loginwindow runs as root and passes root's cache dir to
     the 27 apps reopened at login, so their Mesa disk cache is off.
- **Measured.**
  - Copy-path harness: uncapped 586→1,003 fps and 1,258→389 µs CPU per frame. At 120 Hz with 8 CPU-dirtied layers,
    59 %→24 % of a core and worst frame 18.3→11.1 ms.
  - 0 of 32.7 M pixels wrong; the repo's `bench_surface_*` and `bench_copy_coherence` tests pass.
  - Desktop counters from the same report: `vm_refused` 17,280 against 5,151 allocations; refusals start at
    194–242 MB of a 243 MB budget because of fragmentation.
  - `NVRM_EVENT_WAIT=1` cut app CPU by 44 % (still opt-in in 2.5.5, `docs/EVENT-WAIT.md`).
- **In 2.5.5?** No: no `image_read_host` or `_hostPages`. The `MESA_SHADER_CACHE_DIR` bug is still at
  `plugin/nvmtl_vk.c:692`.
- **Applies cleanly?** Yes, `git apply --check` is clean on v2.5.5. It conflicts with Dora-z's async surface-in
  (`5cb3eba`), with NvGfx `9eae44d` (adjacent hunk in `nvmtl_vk_image_write_host`) and with mickys `dev`: pick one
  upload design.
- **Caveat.** NM #368 (TroyMoss16) notes that WindowServer wraps the same IOSurface in a new texture on most frames.
  A per-texture cache like `_hostPages` would then miss in WindowServer, which is why #368 and mickys key the cache
  per IOSurface. The #399 harness reuses the same textures, so it cannot show this.
- **Worth to us: high.** Part 1 (GPU readback into the pages) and part 3 (cache-dir fix, a few lines) are worth taking
  as they are. Part 2 should be re-keyed per IOSurface. Even with 2a in, the copy path still serves surfaces that
  cannot share VRAM (rows not a multiple of 32 bytes, multi-plane).

### 2c. Older small-BAR forks (superseded)

- [`wavycastic@fix/small-bar1-surface-sync`](https://github.com/wavycastic/nvidia-macos-driver/tree/fix/small-bar1-surface-sync)
  (GTX 1650 Mobile, 256 MB BAR1, 1.15.0): #200 integration, re-import on NO_CACHE dirty, a 4-slot flip cache.
  Superseded by #200/#245 in 2.5.5. Too old to apply. Low.
- [`yuanjing-hash@test/rtx6000-smallbar-v2.0.3`](https://github.com/yuanjing-hash/nvidia-macos-driver/tree/test/rtx6000-smallbar-v2.0.3):
  contiguous-scanout experiment on 2.0.3. Low.
- [NM #27](https://github.com/nullmoth/nvidia-macos-driver/issues/27): the surface budget is fixed at 192 MB for any BAR1
  under 4 GB. Moot at 256 MB, but it explains the 192 MB figure.

---

## 3. Copy path and compositor CPU (WindowServer)

### 3a. mickys overlay (`mickys/nvidia-macos-driver`, default branch `dev`, release `v2.5.4-mickys.1`)

Source: [`overlay/PERFORMANCE.md`](https://github.com/mickys/nvidia-macos-driver/blob/dev/overlay/PERFORMANCE.md),
[`overlay/UPSTREAM-CANDIDATES.md`](https://github.com/mickys/nvidia-macos-driver/blob/dev/overlay/UPSTREAM-CANDIDATES.md).
Test machine: macOS 26.7.1 in a KVM VM, **RTX 4090**, and **GTX 1650 (TU117)** up to 2.5.0. Each change has a switch in
`nvrm610.conf`.

- **What it changes.** Ten listed upstream candidates. The ones that matter to us:
  - **#1 descriptor masks** (`NVMTL_DESC_MASK`). Any pipeline with framebuffer fetch voided the binding mask, so every
    CoreAnimation draw wrote all ~180 descriptors: 2.2 M descriptor writes/s in WindowServer. The fix drops that to
    35 k/s, a few lines.
  - **#9 page cache + async upload.** Page imports are kept per surface (64 entries, ≤512 MB wired), the upload copy
    is not waited for, and a 500 ms reaper runs.
  - **#10 unlocked page-off wait** (NVAccel): the page-off waits for the GPU without the accelerator lock.
  - Reader skip, plane seed, VRAM import cache (128 entries), GPU copy-out of NV12 capture surfaces, ordered
    captured frames.
- **Measured (4090, 1080p165 local display).**
  - Full-screen Safari animation 67–68→72.8–74.0 updates/s with descriptor masks (#1), then **→127.8–129.3** with the
    page cache (#9). At 4K HiDPI 48.5→60 (the refresh rate), with system CPU 28 %→7 %.
  - Screen recording plus Screen Sharing: 81–93 fps with 142–183 frames out of order, against 129–154 fps with 0 out
    of order.
  - GTX 1650: WindowServer CPU 73→60 %; Parsec 1080p 46→71 fps.
- **In 2.5.5?** No: no `skip_fetch` or `NVMTL_DESC_MASK` in `plugin/`; the #96 deferral is reverted (§1).
- **Applies cleanly?** Kexts yes (`git apply --check`). Plugin: `git apply` fails on context at `nvmtl_vk.c:6045`
  (2.5.5's view-format change), but `git merge` of `dev` into v2.5.5 completes **with no conflicts**. It does not
  combine with hostpages (conflicts) or with Dora-z `d34ea85` (one hunk in `nvrm-accel.cpp`).
- **Worth to us: very high.** Descriptor masks (#1) is a cheap, isolated bug fix on every WindowServer draw. The page
  cache (#9) has the biggest measured gain for CPU-drawn windows. Caveats: the page cache was tested only on the 4090
  (and is the newest change), all measurements ran in a VM, and the overlay carries much else (game fixes, capture
  ordering). Cherry-pick by item; don't take the whole branch.

### 3b. watchthelight-labs/NvGfx: WindowServer draw path (NM #356)

Source: [NvGfx](https://github.com/watchthelight-labs/NvGfx), branch `nvgfx-2.5.3` (based on v2.5.3; PolyForm NC like
upstream). Test machine: **RTX 5070 Laptop, 2560×1600 165 Hz, macOS 26.7.1.** Commits:

- `37f2af4` one framebuffer-fetch descriptor set per pass
- `18996e2` skip a repeated `setRenderPipelineState` inside a pass
- `c73ea10` keep the encoder's sampler-variant choice
- `4b3bdd5` the commit-time ahead pass on its own queue
- `9eae44d` async upload of CPU-written IOSurfaces in apps
- `2b41c23` per-module memo for `newFunctionWithName`
- `f1193e9` remember refused pipeline links
- `7e6dc68` shader cache in the process's own folder when the shared one is refused (WindowServer sandbox)
- `224aed2` unbound-slot sampler

**What it measured:**

- [NM #356](https://github.com/nullmoth/nvidia-macos-driver/issues/356) comment: an 800×500 Finder drag ran at
  75–77 flips/s on stock 2.3.7 and **145–148** on their 2.4.3 fork. A spindump put a third of WindowServer's samples
  in `drawIndexedPrimitives` (descriptor snapshot per draw, fetch set and barrier per draw, an IOSurface import per
  frame). They did not measure the commits one at a time.
- The #356 reporter (3060 Laptop, 2.5.3): about 20 ms per drag frame whatever the size or refresh rate, with
  WindowServer at 100 % of a core.
- `2b41c23`: a VideoToolbox session's Metal setup takes 75 ms→2 ms warm.
- [NvGfx#11](https://github.com/watchthelight-labs/NvGfx/issues/11): drags run at 11–28 flips/s for the first 2–4
  minutes after login, then 75–77.
- Geekbench 6 Metal 103,094.

**In 2.5.5?** No: reverse-apply checks fail for all of them. **Applies cleanly?** Yes: the whole fork plugin diff
(`v2.5.3..nvgfx-2.5.3 -- plugin translator`, 276+/47−) applies cleanly to v2.5.5, and so does each commit alone.
`9eae44d` is the only one that conflicts with hostpages.

**Overlap.** Dora-z's `d0b2ee5` (compositor-draw-caching) re-implements `37f2af4`, `18996e2` and `c73ea10` in 29 lines
on 2.5.4, cleanly applicable. Take one set, not both. mickys' descriptor-mask fix is complementary: it shrinks each
set, these reuse the set.

**Worth to us: high** for the three draw-path commits, or Dora's `d0b2ee5`. They target exactly the per-draw cost
behind #356, and 180 Hz leaves 5.5 ms a frame. Medium for `2b41c23` (Settings icons, VideoToolbox setup) and `7e6dc68`
(only if our Tahoe log shows `spvcache: ... not writable` in WindowServer).

### 3c. Dora-z async surface-in and Chromium sync

- `5cb3eba` (`NVMTL_ASYNC_SURFIN=1`, off by default): WindowServer's upload at `setFragmentTexture` is left in
  flight. The barrier goes from TOP_OF_PIPE to ALL_COMMANDS, which fixes a one-frame triangle flicker. **Window drag
  at 180 Hz on the GTX 1660 SUPER: 36→45 fps**, with the wait taking 26 % of the compositor thread. Applies cleanly.
  It is an alternative to mickys #9 (which measured more) and to hostpages: pick one.
- `ca8fa4d`: `NVMTL_SCHEDULE_AFTER_SURFACE_WRITES` on by default in Chromium GPU processes (fixes a blank-page flash
  under Graphite). `b158462`: stencil-export detection only from a push-constant block (fixes Graphite icons drawn as
  solid boxes). Both apply cleanly and are small. Medium (Metal correctness in Chrome and Edge).

### 3d. Open upstream items, not yet code we can take

- [NM #368](https://github.com/nullmoth/nvidia-macos-driver/issues/368) per-IOSurface pinned imports (5080, 5120×1440
  144 Hz): drag around 97 fps at 110 % CPU, with 12 % of main-thread samples in import, wait and free. The patch was
  never attached (only a description), so there is nothing to apply. The same idea is mickys #9.
- [NM PR #139](https://github.com/nullmoth/nvidia-macos-driver/pull/139) AVX2 non-temporal stores for staging uploads:
  −18 % CPU per 2880×1800 upload. Closed and not merged; 2.5.5 has a different streaming-*load* path
  (`nvmtl_copy_surface_stream`). Low.
- [`artpetrow-cmyk@rtx2070-macos26`](https://github.com/artpetrow-cmyk/nvidia-macos-driver/tree/rtx2070-macos26)
  (2.0.1): NVRM gives WindowServer channel groups HIGH interleave and a 2 ms timeslice. Too old, needs an NVRM build,
  not measured. Low, but an idea to keep for frame pacing.

---

## 4. Shader translation and caching (NM #370)

- **[NM #370](https://github.com/nullmoth/nvidia-macos-driver/issues/370)** (2070 SUPER, Sequoia, 2.5.3):
  - WindowServer's `coreanimation.pipelines` thread was in `create_fragment_shader → nvmtl_translate_with_fc_cached`
    for 317 of 353 samples, with `writeToFile:atomically:`/`fsync` on the same thread.
  - The reporter's follow-up shows this was a **cold cache**. The cache key includes the translator hash, so every
    release that changes the translator invalidates all ~404 files (73 MiB). With a warm cache there are no `.spv`
    writes during use.
  - WindowServer memory still grows (716→814 MB RSS in 7 min idle), an open problem.
  - **For us:** every rebuild of our own translator resets the cache, so the harness must warm the cache before a
    run, or count the cold run on purpose.
- **NvGfx `cache-write-async`** (`a3f23a7`, `23a79cf`, `4894359`, `bdc92d4`; 2.5.3-nvgfx.2, **not built or booted**
  by its author):
  - Moves every cache write and touch to one background queue; `NVMTL_CACHE_SYNC_IO=1` for A/B.
  - Logs memo/disk/translated counts after 500 lookups.
  - In 2.5.5? No. Applies cleanly? Yes on top of the NvGfx plugin diff (the combined diff
    `v2.5.3..cache-write-async` applies to v2.5.5). It does not apply alone: it depends on `2b41c23`'s
    `NVMTLLibraryLoad.m` changes.
  - Worth: medium. It removes only the fsyncs; translation still runs on the calling thread. The counter is useful to
    the harness at once.
- **[NM PR #187](https://github.com/nullmoth/nvidia-macos-driver/pull/187)** (modesttao): FxHash instead of SipHash in
  the translator. 1.27× faster translation (82.6→64.9 s over 407 modules), SPIR-V byte-identical. **Open; nullmoth
  "still want this" but it needs a rebase.** `git apply --check` fails on v2.5.5 (`multi_exit.rs:162`). The change is
  mechanical across 158 files. Medium: it shortens every cold translation, but it is a re-do, not a cherry-pick.
- **[`GeekAudio@fix/shared-shader-cache-install`](https://github.com/GeekAudio/nvidia-macos-driver/tree/fix/shared-shader-cache-install)**
  (1.9.0): the installer creates the shared AIR cache dirs. Old; check whether 2.5.5's installer already does it. Low.
- **NvGfx open issues** to reuse as harness cases:
  - [#10](https://github.com/watchthelight-labs/NvGfx/issues/10): Settings icons are placeholders for 3 s and complete
    by 15 s on first load.
  - [#11](https://github.com/watchthelight-labs/NvGfx/issues/11): slow drags for the first minutes after login.

---

## 5. Video decode and encode

- **[mickys/nvenc](https://github.com/mickys/nvenc)** (MIT): open-source NVENC and NVDEC driven from user space,
  loaded through 2.5.5's existing `NVMTL_NVENCVT=1` hook (`libnvencvt.dylib`). It needs no plugin change.
  - Decoders: H.264, HEVC 8–12 bit, **VP9**, AV1 (not on Turing), MPEG-1/2/4, bit-exact against ffmpeg.
  - **GTX 1650 (TU117):** H.264 decode 1080p/4K 154/36 fps (NullMoth) against **447/121**; VP9 580/180 fps
    (NullMoth has none); HEVC level.
  - The 4090 gets 4K H.264 at about 210 fps.
  - **Safari's GPU process cannot load it**, per the mickys README: Safari keeps Apple's software decoders.
  - TU117's NVENC is the older 6.6 generation. The README says other RTX 20 cards "keep NullMoth's encoders", so its
    encoders likely don't apply to TU106. Whether its **decoders** register on TU106 is unverified (Turing NVDEC
    should be one class).
  - **Worth: high for the Video goal outside Safari** (VP9, 4K60 H.264 headroom). It costs an install and a test, not
    a code change. Related symptoms reported on stock: [NvGfx#3](https://github.com/watchthelight-labs/NvGfx/issues/3)
    (4K H.264 about 30 fps), [#2](https://github.com/watchthelight-labs/NvGfx/issues/2) (intermittent HEVC
    `nvd265 TIMEOUT`), [#4](https://github.com/watchthelight-labs/NvGfx/issues/4)
    (`VTIsHardwareDecodeSupported(H264)` false).
- **Dora-z BAR1 margin** (`1bf8737`/`40e9f96`, §2a): NVENC maps through BAR1 and fails with `NV_ERR_NO_MEMORY` when
  surfaces leave only 16 MB. This matters for the Encode goal on a 256 MB card whatever we do with surfaces.
- **[NM #231](https://github.com/nullmoth/nvidia-macos-driver/issues/231)** (RTX 2060, Tahoe): copy-engine queue fails
  (`VkResult -13`) and video decode fails. No fix posted; nullmoth asked for a retest on 2.5.x. Our baseline should
  check whether `copy-engine queue could not be built` still logs on 2.5.5.

---

## 6. Utilization stats (Activity Monitor and iStat)

- **[NM PR #380](https://github.com/nullmoth/nvidia-macos-driver/pull/380)** (GeekAudio, open):
  - NVRM opens a private kernel RM client and polls `NV2080_CTRL_CMD_PERF_GET_GPUMON_PERFMON_UTIL_SAMPLES_V2` once a
    second on its own work loop.
  - NVAccel publishes `Device Utilization %`, `GPU Core Utilization %`, `GPU Memory Utilization %`,
    `GPU Video Engine Utilization %` and `GPU Video Decode Utilization %` in `PerformanceStatistics`.
  - The parser handles the firmware's 72-entry ring; reading `samples[0]` alone gives a sample about 14 s old.
  - Keys are dropped when stale (over 5 s) instead of showing 0 %.
  - Measured: builds and boots on a 3080 (macOS 26.7.1), and the value rises under load. Sleep/wake is unchecked.
  - In 2.5.5? No. Applies cleanly? **Yes** (`git apply --check`). It **needs an NVRM rebuild**, with NVIDIA's
    615.78.08 open-gpu-kernel-modules; NvGfx `build/nvgfx/` and Dora-z `fork/build.sh` show such a harness.
  - **Worth: high**: the whole Stats goal in one patch, from the owner of the #324 approach.
- **[NM #324](https://github.com/nullmoth/nvidia-macos-driver/issues/324) `nvstatd`**: the same RM call from a root
  daemon, plus a separate ~300-line kext to republish the values. GR utilization read 10–18 % idle and 93 % under
  load on a 3080. The firmware samples step every 14.4 s. Superseded by #380 unless we want to avoid rebuilding NVRM.
  Low.
- **NvGfx `tools/nvgfx-smi`** and **BlueMonkey262 `feat/telemetry-poll`**: read-only telemetry through RUSD (class
  `0x00DE`, `RM_USER_SHARED_DATA`). `perfDevUtil` (GPU and memory busy) is populated, with no root needed and none of
  GPUMON's 14 s step. Useful as a harness probe, or as an alternative source if #380's GPUMON proves too coarse.
  Medium.

---

## 7. Display at 180 Hz

- **Dora-z `303a300`** (`nvfbscalehz=<hz>`): NVRMFB kept only the first 64 timings, so every HiDPI mode above 60 Hz
  was dropped. The fix orders unscaled timings first, then the scaled desktops at the given rate, up to 224 timings.
  Measured: HiDPI at 180 Hz on the 1660 SUPER. In 2.5.5? No. Applies cleanly? Yes. Opt-in boot-arg; off means
  unchanged behaviour. **Worth: medium.** It matters only if the owner wants a scaled (HiDPI) mode at 180 Hz; native
  2560×1440 at 180 Hz doesn't need it.
- **NM 2.5.2 `debug.nvrmfb_flip_latch=2`** (already in 2.5.5, opt-in): gives back about half a refresh period per
  frame. Worth an A/B in the baseline.

---

## Ranked shortlist for the RTX 2060

1. **Dora-z unmapped VRAM grants plus the BAR1 margin plus read marks** (`d34ea85`, `1bf8737`, `40e9f96`, `b49176f`).
   The only change that removes surface refusals on a 256 MB BAR1; measured on a TU116 twin. One trivial hand merge,
   then a rebuild of NVAccel and NVRMFB.
2. **mickys descriptor masks** (`NVMTL_DESC_MASK`, candidate #1). A few lines; 2.2 M→35 k descriptor writes/s in
   WindowServer, about +8 % Safari updates/s.
3. **WindowServer draw-path caching**: NvGfx `37f2af4`, `18996e2`, `c73ea10` or Dora-z `d0b2ee5`. Measured 75→148
   flips/s on a fork; apply cleanly.
4. **mickys page cache plus async upload** (candidate #9, with #2 and #3), or Dora-z `5cb3eba`. Safari 73→128
   updates/s (4090); 36→45 fps drags (1660S). Use it instead of hostpages' per-texture cache.
5. **#399 hostpages parts 1 and 3**: GPU readback into the pages (copy-path CPU 1,258→389 µs per frame), plus the
   `MESA_SHADER_CACHE_DIR` fix for the 27 login apps. Applies cleanly.
6. **NM PR #380 GPU utilization**: the whole Stats goal; applies cleanly; needs an NVRM rebuild.
7. **mickys/nvenc decoders**: VP9 and 3× faster H.264 decode on Turing; drop-in through `NVMTL_NVENCVT`; Safari
   excluded; TU106 unverified.
8. **NvGfx `cache-write-async` plus `2b41c23`**: fsyncs off the compositor thread, cache-hit counters, Settings and
   VideoToolbox setup memo. Our harness must also warm the cache.
9. **NM PR #187 FxHash translator**: 1.27× faster translation; needs a rebase.
10. **Dora-z `nvfbscalehz`**, only if HiDPI at 180 Hz is wanted.

Dropped: wavycastic, yuanjing-hash and Gusyaru08 (old, superseded); PR #139 (unmerged, different approach shipped);
the #324 daemon (superseded by #380); Dora-z `7ea290a` (fixed differently in 2.5.5).

## Open uncertainties

- **Nothing above was measured on a TU106 or on Tahoe with a 256 MB BAR1.** The closest are Dora-z (TU116, macOS 15)
  and #399 (TU104, Tahoe, copy-path harness only). Every gain needs our harness against the stock baseline.
- **Dora-z's unmapped grants on macOS 26**: they were never built for Tahoe. Their safety rests on "the family never
  asks for a CPU address", shown by counters on one machine and Sequoia only. Tahoe's IOAccelerator family may behave
  differently, and the VRAM is not zero-filled.
- **The upload designs exclude one another.** Dora-z async, mickys page cache, NvGfx `9eae44d` and #399 hostpages
  touch the same functions. Picking one is a spec decision.
- **mickys/nvenc on TU106**: decoder registration is not verified; Safari can't use it.
- **NM PR #62's claim that an RTX 2060 exposed an 8 GiB ReBAR BAR1** contradicts the map's "64/128/256 MB only" for
  TU106. It's probably a different board or VBIOS, but worth one `lspci -vv` look at this card's ReBAR capability
  mask before closing the question for good.
- **#380 and #9 need an NVRM build harness** that this fork does not have yet; NvGfx and Dora-z show how.

## Reproducing the apply checks

All checks ran on v2.5.5 (`bf23ca7`):

- **#399:** `git apply --check hostpages-2.5.4.diff`, from the zip attached to NM #399.
- **NvGfx:** `git remote add nvgfx https://github.com/watchthelight-labs/NvGfx.git`, fetch `nvgfx-2.5.3` and
  `cache-write-async`, then `git diff v2.5.3 nvgfx/nvgfx-2.5.3 -- plugin translator | git apply --check -`.
- **Forks:** `git fetch https://github.com/<owner>/nvidia-macos-driver.git <branch>`, then `git cherry-pick` or
  `git merge` into a detached worktree at v2.5.5.
- **Upstream PRs:** `gh pr diff <n> -R nullmoth/nvidia-macos-driver | git apply --check -`.
