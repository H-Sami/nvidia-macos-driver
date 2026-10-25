# How BAR1 is spent on a 256 MB card (RTX 2060, TU106, 6 GB)

Research for `.scratch/rtx2060/issues/05-how-bar1-is-spent.md`. Tree: `rtx2060` at `v2.5.5-1-ga217742`.
Sources: the driver source (cited `file:line`), upstream issues #399, #169, #92, #364, #183 (read-only), and Apple's
Metal storage-mode documentation. **[MEASURE]** marks a claim that needs a number from this card on Tahoe.

## Answer in one paragraph

The CPU only has to touch BAR1 for a few small things: the boot console, the cursor, the gamma LUTs, and the
scanout when the display is on the copy path. Nearly all of the 256 MB goes elsewhere. NVRMFB's `vramGrant` maps
every IOSurface VRAM backing it hands to NVAccel into the kernel through BAR1 and keeps that mapping for the whole
life of the backing. That covers the parked ("sticky") backings that NVAccel keeps across the family's
unwire/rewire too. Nothing on the normal path reads those mappings. The plugin imports the memory as a GPU-only RM
handle, page-off uses the copy engine, and a zero-copy flip passes NVKMS a memory handle. So the BAR1 cost comes
from how the code is arranged. Apple's model does not require it. When the budget runs out (or the window is too
fragmented for a contiguous mapping), the surface gets no VRAM. The plugin then gives it a private image and copies
it out to system memory after every GPU write, and in again before every use. If the refused surface is
WindowServer's composited frame, the kernel also copies it with the CPU into the BAR1-mapped scanout on every frame.
At 2560×1440 that is about 3 to 5 ms of transfers for each full-screen surface, against a 5.56 ms frame at
180 Hz. NVK already keeps its own CPU-mapped "local" memory out of BAR1 on this card.

## Correction to the ticket's file pointers

`kexts/NVRM/fb/nvrm-fb.cpp` (1,656 lines, last changed in `4406276`) is a **stale copy**. The live framebuffer is
`kexts/NVRMFB/fb/nvrm-fb.cpp` (3,978 lines), which is what `tools/test_bar1_budget.py`,
`tools/test_vram_display_budget.py` and `tools/test_vram_park_hold.py` compile from. The two disagree on the
points that matter here: the old copy has a fixed 192 MB budget and unmaps parked blocks. The live copy has a
display-aware budget and keeps parked blocks mapped. Every NVRMFB reference below is to the live file.
`GLOSSARY.md`'s "about 192 MB" is the budget **before** the display is measured. After that it is larger (next
section).

## 1. Lifecycle of a surface's BAR1 space

1. **BAR1 placement (NVRM).** `NVRM::placeLargeBar1()` (`kexts/NVRM/NVRM.cpp:996`) reads the Resizable-BAR
   capability. Turing offers at most 256 MB (`:1036-1060`), so there is nothing to resize. If the firmware console
   sits inside BAR1, BAR1 is moved at the same size to the top of the host bridge's 64-bit window (`:1046-1057`,
   `:1133-1136`). `readBARs()` (`:1290`) records BAR1 as `nv->bars[NV_GPU_BAR_INDEX_FB]`.
   `publishGpuProfile()` (`:1247`, logic at about `:1267-1287`) sets `scanout = static-bar1` only when
   BAR1 ≥ VRAM. On this card it is **`by-handle`**: the display is meant to be addressed by an RM handle, not by
   a BAR1 address.
2. **Budget (NVRMFB).** `nvrmVramBudget()` (`kexts/NVRMFB/fb/nvrm-fb.cpp:68-74`) gives ¾ of a 256 MB BAR1 =
   192 MB. `nvrmSurfaceBudget()` (`:86-95`) replaces that, once the display is mapped, with
   `BAR1 − (scanout + cursor) − 16 MB` (the 16 MB is an untracked margin for RM's own mappings). The scanout is
   counted at `:1043-1047`, the cursor at `:2036-2040`. Scanout memory is sized for the panel's widest validated
   raster (`computeScanoutCaps`, `:1003-1018`). For 2560×1440 that is 10,240 × 1,440 = 14,745,600 B, and the
   cursor is 256 KB, so the budget is ≈ 268.4 − 15.0 − 16.8 ≈ **236.6 MB (225.7 MiB)**. **[MEASURE]**
   `debug.nvrmfb_vram_display_bytes` and `debug.nvrmfb_vram_budget_bytes`: a monitor that lists a larger mode
   makes the scanout bigger.
3. **Grant (NVRMFB `vramGrant`, `:3260-3431`).** The request is rounded up to 64 KB. It is refused when
   `mapped + parked + want > budget` (`:3269-3297`). Otherwise NVRMFB calls NVKMS `allocateMemory(useVideoMemory)`
   and then **`mapMemory(KERNEL)`** (`:3312`). That mapping is the BAR1 spend. The BAR1 CPU-physical address is
   taken from the mapping (`fPhysForVa`), checked for overlap with the scanout or console, and the block is then
   zero-filled and probed **through the CPU** (`:3400-3418`). The kva, the BAR1 physical address and the RM handle
   are returned to the caller. A grant can also fail with `mapMemory(KERNEL) failed` while under budget, because
   BAR1 is fragmented (#399: 7.6 MB windows refused at 194–242 MB of 243 MB; #364: 8 MB refused at 217 MB).
4. **Console and scanout parks (NVRMFB, `:3173-3180`, `:3326-3380`).** An allocation whose BAR1 address overlaps
   the console or scanout is parked: it stays **allocated and mapped** and counts against the budget. On a 256 MB
   BAR1 parks are capped at 32 MB. Parks last until reboot (`gParkedForever`).
5. **Wire (NVAccel `NVVidMemory::allocPhysical`, `kexts/NVRM/accel/nvrm-accel.cpp:959-1014`).**
   IOAcceleratorFamily2 calls this when a resource needs a GPU copy. It reuses its own park if that is big enough
   (`:976-985`). Otherwise it asks NVRMFB (`askFramebufferForVram`, `:553-560`). On refusal it returns false
   (`:992-1006`), and the IOSurface has no VRAM.
6. **Unwire (`NVVidMemory::deallocPhysical`, `:1016-1040`).** With `gVmSticky = 1` (the default, `:956`) the
   backing is **parked, not freed**: handle, kva and BAR1 mapping are all kept so that the next wire returns the
   same memory the plugin imported (upstream PR #200, see #169). The BAR1 space is released only in
   `NVVidMemory::free()` (`:1059-1066`), when the resource is destroyed, or when the resource grows (`:984`). In
   practice a granted surface **holds its BAR1 for its whole life, whether or not it is currently wired.**
7. **Import (plugin → NVK → NVAccel).** `nvmtl_vk_surface_vram()` (`plugin/nvmtl_vk.c:2021-2056`) stages a record
   and calls `vkAllocateMemory`. NVK's `nvkmd_nvrm_import_dma_buf` (`nvk/nvk-macos.patch:9871-9905`) issues
   `NVRM_ESC_SURF_VRAM`. `nvAccelSurfVram` (`nvrm-accel.cpp:1718-1732`) wires the vidmem and `NV04_SHARE`s its RM
   handle (`kexts/NVRM/nvrm_surfshare.cpp:24-41`). NVK `DUP`s it as `LOCAL|VRAM|SHARED` **with a GPU VA only**
   (`nvk-macos.patch:9900-9901`, no `CAN_MAP`). **The plugin never CPU-maps the imported VRAM.**
8. **CPU access to a granted surface (page-off).** `NVResource::pageoff` (`nvrm-accel.cpp:1772-1866`) copies
   VRAM to the IOSurface's system pages **on the copy engine** (`nvrm_ce_copy_to_pages`,
   `kexts/NVRM/nvrm_pageoff.c:109`), into a contiguous staging buffer followed by `writeBytes`, or page by page. It
   does not use BAR1. Only when the CE copy is unavailable does it fall back to `IOAccelResource2::pageoff`. That
   fallback may read through `getApertureMemoryDescriptor` (`:919-945`), an `IODeviceMemory` over the **BAR1**
   physical range. **[MEASURE]** whether the family's fallback page-off ever runs on Tahoe, given the Turing CE
   queue failure in #231/#92 ("Unable to program runlist for CE0").
9. **Display.** A zero-copy flip (`nvAccelIopFlip`, `:2046`, through NVRMFB `flipToMemory`) passes the NVKMS
   **memory handle**. Scan-out reads VRAM directly and needs no BAR1. The flip is possible only if the composited
   surface has RM VRAM, which today means it went through the BAR1 grant (`nvaccel_iop_flip_novram`, `:1317`).
   Otherwise the transaction is copied by the CPU into the scanout's kernel mapping (`:1185-1218`).

## 2. BAR1 consumers

| Who | Size on this machine | Lifetime | Does the CPU really need it? |
|---|---|---|---|
| Firmware/boot console (BAR1 + 0) | ≈14.7–25 MB (2560×1440 GOP; #28 quotes 25 MB) | until NVRMFB takes over; parks guard it until reboot | **Yes before the driver starts**; after that only as an overlap hazard |
| NVRMFB scanout (`fMem`, kernel + user maps, `nvrm-fb.cpp:990-1047`) | 14.7 MB (sized for widest raster) | driver lifetime | **Only for the copy path** (K6 copy `nvrm-accel.cpp:1210-1218`, boot paint/HUD). Zero-copy scan-out does not need it. **[MEASURE]** whether the USER map takes a second BAR1 range |
| Cursor plane (`nvrm-fb.cpp:1994-2040`) | 256 KB | driver lifetime | **Yes**: the CPU packs the cursor image into it (tiny) |
| Gamma output-LUT surfaces ×2 (`:1843-1870`) | < 64 KB each | driver lifetime | **Yes**, tiny |
| RM's own mappings | 16 MB margin assumed, untracked (`:91`) | driver lifetime | unknown. **[MEASURE]** with RM `NV2080_CTRL_CMD_FB_GET_INFO` BAR1 free/largest-free indexes (open-gpu-kernel-modules `ctrl2080fb.h`; NVK already queries `BAR1_SIZE` there, `nvk-macos.patch:10613`) |
| NVRMFB console/scanout parks and guard blocks (`:3326-3380`) | ≤ 32 MB | until reboot | **No**: they exist because overlap is judged by BAR1 address, and only mapped blocks have one |
| NVAccel grants: IOSurface VRAM backings (`vramGrant` via `allocPhysical`) | the rest of the budget (≈ 236 MB minus parks): about 16 full-screen 1440p surfaces, or ~29 1080p windows (#399) | from first wire to resource free | **No** on the normal path: zero-fill and probe at grant, a resource-only iop copy (`:1170-1177`), capped debug copies/samplers (`:2302`, `:2397`), and the family's fallback page-off. GPU, CE and display use handles |
| NVAccel sticky parks (`deallocPhysical`, `:1029-1035`) | part of the above | across every unwire until resource free | **No**: they preserve handle identity, which needs no CPU mapping |
| NVK `NVKMD_MEM_BAR` (DEVICE_LOCAL\|HOST_VISIBLE types, `nvk-macos.patch:4326-4331`) | ≈ 0 by default | per allocation | The plugin avoids these types. `memtype()` prefers non-device-local host-visible types (`plugin/nvmtl_vk.c:1101-1110`) and "shared-in-VRAM" is off unless `NVMTL_SHARED_VRAM=1` (`:1114-1120`). Its own budget is `heap − 256 MB` (`:1130`), which is 0 if the BAR heap is 256 MB. **[MEASURE]** heap sizes from `vulkaninfo`/plugin log |
| NVK LOCAL+mapped memory | 0 | n/a | `nvrm_local_map_stays_vram()` (`nvk-macos.patch:9627-9641`) returns false unless BAR1 ≥ VRAM *and* `NVK_LOCAL_MAP_SYSMEM=0`, so `:9765-9771` puts such allocations in **system RAM (GART)**. No BAR1 is spent, but the GPU reads them over PCIe |

## 3. Refusal → copy path, and what it costs per frame

**Flow.** `vramGrant` refuses (budget or fragmentation). `allocPhysical` returns false. The family's resource has
no VRAM. `nvAccelSurfVram` replies `NVRM_SS_NO_VRAM`. `vkAllocateMemory` fails with
`VK_ERROR_INVALID_EXTERNAL_HANDLE` (−1000072003, the code seen in #92 and #399). The plugin logs
`family VRAM import refused - private image + copies` (`nvmtl_vk.c:2039`) and `nvmtl_surface_image_create`
makes a private VRAM image (`plugin/NVMTLDevice.m:980-996`). From then on:

- **Surface-out after every GPU write** (`plugin/NVMTLObjects.m:1300-1318`): `IOSurfaceLock`, then
  `nvmtl_vk_image_read` (`nvmtl_vk.c:6398-6421`). That means GPU `CopyImageToBuffer` into a system-RAM staging
  buffer, a **synchronous** `submit_wait`, and then a **CPU memcpy** of every row into the IOSurface.
- **Surface-in before every use, if the seed moved** (`NVMTLObjects.m:1227-1256`): `nvmtl_vk_image_write_host`
  (`nvmtl_vk.c:6326-6352`) imports the IOSurface pages as a host pointer (no CPU copy, but import, map and free
  each time) and DMAs them into the image. The fallback is a CPU copy into an upload stage.
- **If the refused surface is WindowServer's composited frame**, there is no zero-copy flip
  (`nvaccel_iop_flip_novram`). Each display transaction has the **kernel CPU** copy 14.7 MB from the IOSurface
  pages into the scanout's BAR1 mapping (`nvrm-accel.cpp:1185-1218`), after waiting for the GPU
  (`nvSurfWaitReady`).

**Per-frame cost at 2560×1440×4 = 14,745,600 B.** These are estimates. The bandwidth figures are assumptions,
not measurements on this machine. The RTX 2060 is PCIe 3.0 ×16 (≈ 12–13 GB/s usable). The 5700X3D's L3 is 96 MB,
so a 14.7 MB memcpy can stay mostly in cache.

| Step | Bytes | Assumed rate | Time |
|---|---|---|---|
| GPU image → system-RAM stage (DMA) | 14.7 MB | 12 GB/s | ≈ 1.2 ms of GPU/PCIe, with the CPU waiting on the fence |
| CPU stage → IOSurface memcpy | 14.7 MB read + write | 10–20 GB/s | ≈ 0.7–1.5 ms of CPU |
| Surface-in DMA (consumer side, when it changed) | 14.7 MB | 12 GB/s | ≈ 1.2 ms + per-upload host import overhead |
| Kernel CPU IOSurface → scanout through BAR1 (composited frame only) | 14.7 MB of write-combined MMIO writes | 3–6 GB/s | ≈ 2.5–5 ms of one core |

So one refused full-screen app surface costs ≈ 2–4 ms per change in the producer plus ≈ 1.2 ms in WindowServer. A
refused composited frame adds 2.5–5 ms of kernel CPU on every frame. A 180 Hz frame is 5.56 ms, and 14.7 MB × 180
= 2.65 GB/s for each copy. **[MEASURE]** all four rows on Tahoe. The plugin already logs surface-out ms
(`NVMTLObjects.m:1316`). The NVAccel counters `nvaccel_iop_src_surf`, `nvaccel_iop_flip_novram`,
`nvaccel_vm_refused` and `nvrmfb_vram_mapped_bytes` give the frame counts.

**Evidence from 256 MB cards.**

- **#399** (RTX 2070 S, TU104, macOS 26.7.1, 1080p @ 120 Hz):
  - After hours of use: `vm_refused` 17,280 against 5,151 allocs, 234 of 243 MB mapped. The refused sizes were
    whole 7.6–7.9 MB windows.
  - In-process profile: stock copy path 586 fps at 1,258 µs CPU per frame. With surface-out readback going
    straight into imported IOSurface pages and cached imports: 1,003 fps at 389 µs.
  - 120 Hz paced with 8 CPU-dirtied layers: 59 % of a core, worst frame 18.3 ms (stock), against 24 % and 11.1 ms
    (patched).
  - memmove was ~28 % of samples.
- **#169** (GTX 1650 Mobile, 2560×1440 @ 120 Hz):
  - The budget filled to 200.5 of 201.3 MB with ~50 live allocations.
  - The family unwires and rewires 14,745,600 B compositing surfaces, and the rewires fail with `BAR1 budget spent`
    or `mapMemory(KERNEL) failed`.
  - The TU104 follow-up (Exop63) gave 1–64 MiB surfaces **GPU-only backing with no CPU BAR1 mapping**
    (allocate → CE zero-fill → pin). Result: 11/11 imports in VRAM, 311,904,480 pixels correct, zero new
    refusals, and mapped usage fell from ~200 MB to 71 MB.
  - The same thread notes that handle/cookie lifecycle (unwire/rewire) is a separate problem from BAR1 pressure.
    Sticky parks fixed it on TU117 (155–165 MB mapped steady, 0 stale flips).
- **#92** (RTX 2060 SUPER, TU106): ~56 % of dirty marks refused, `family VRAM import refused (-1000072003)`,
  `LOCAL+mapped memory -> system RAM`, and a CE0 runlist failure. A later commenter attributed similar refusal
  numbers to `NO_CACHE` and then retracted that as cross-boot mixing.
- **#364** (GTX 1660 S): bursts of `mapMemory(KERNEL) failed` at 217 + 8 < 243 MB, which points to fragmentation.
  `-nvrmnoflip` (copy path everywhere) made the system laggier, so zero-copy matters on these cards.
- **#183** (RTX 2060 laptop): the driver itself chose `nvrm-flip = off (copy path)`. Multi-head and login hangs
  were suspected to come from BAR1, but this was not proven.

## 4. What Apple's IOAccelerator/IOSurface model requires to be CPU-visible

- **IOSurface memory is system memory.** The CPU reaches a surface only through `IOSurfaceLock` and the base
  address, which are system pages (the kernel uses `IOSurface::getMemoryDescriptor()` for page-off and the copy
  path, `nvrm-accel.cpp:1792`, `:1192`). A VRAM copy is an accelerator-private **device cache**
  (`IOGraphicsAccelerator2::deviceCacheForIOSurface`, `:1699`) whose validity bits (`valid[0]` system memory,
  `valid[6]` VRAM, `:1630-1633`) say which copy is newest. A CPU lock makes the driver page the VRAM copy off into
  system memory. This is DMA, and it is what the driver already does with the CE.
- **Metal on discrete Macs follows the same rule.** In Apple's "Choosing a Resource Storage Mode for Intel and AMD
  GPUs" (developer.apple.com/documentation/metal), *Shared* resources live in system memory, *Managed* resources
  keep a system copy and a VRAM copy synchronised by the driver, and *Private* resources are GPU-only. No Metal
  storage mode needs a CPU mapping of VRAM. The plugin already keeps Shared in system RAM by default
  (`nvmtl_vk.c:1119`).
- **The display needs nothing CPU-visible.** IOAccelDisplayPipe transactions name an IOSurface or resource, and the
  driver flips to it by handle (`nvAccelIopFlip`). CPU access is needed only for this driver's own CPU copy path.
- **Things this tree hands to the family as BAR1 that look optional:** `addToAperture` returns true "already in
  BAR1" (`:908-915`), `getApertureMemoryDescriptor` returns BAR1 physical ranges, and `vidmem+0xc8` is set to the
  BAR1 physical address (`:1010`). **[MEASURE/RE]** Find which IOAcceleratorFamily2 paths on Tahoe actually call
  these, and whether `+0xc8` is read as a GPU address or a CPU address. That determines whether a grant can drop
  its CPU mapping without the family noticing. The #169 experiment suggests it can for 1–64 MiB surfaces on the
  `SURF_VRAM` path.

Conclusion: Apple's model requires CPU visibility only for system-memory IOSurface pages and for whatever the
driver itself chooses to write with the CPU (cursor, LUT, copy-path scanout). VRAM surface backings do not need to
be in BAR1.

## 5. Levers (options, not a design)

1. **Unmapped grants.** Allocate IOSurface VRAM with no `mapMemory(KERNEL)`. Zero-fill with the CE, and take the
   overlap check and identity from the RM handle or VRAM offset instead of the BAR1 address. This is the #169
   experiment. *Depends on:* the CE working on this TU106 under Tahoe (#231); the remaining kva users
   (resource-only iop copy, debug copies, family fallback page-off, `getApertureMemoryDescriptor`, `+0xc8`)
   either removed or mapping on demand; and the console-overlap problem being restated in VRAM-offset terms.
2. **Map on demand.** Keep grants unmapped and map a small, bounded window only while the CPU needs one (the
   fallback page-off or a resource-only copy), then unmap. *Depends on:* the family tolerating a descriptor that
   appears and disappears; mapping latency (**[MEASURE]**); and the fragmentation behaviour of short-lived maps.
3. **Unmap parked backings.** Sticky parks need the handle, not the kva. *Depends on:* lever 1 or 2 so that a
   rewire does not need a new mapping; the #169 lifecycle fix (same handle and cookie) must be kept.
4. **Exempt only the composited frame or display-sized surfaces from BAR1.** A narrower version of lever 1 that
   protects zero-copy scan-out, which matters most (#364). *Depends on:* recognising WindowServer's swap surfaces
   at wire time.
5. **Make the copy path cheaper where it stays.** #399's plugin patch: surface-out straight into imported IOSurface
   pages (no staging and no memcpy), and imports cached per texture. Also `NVRM_EVENT_WAIT=1` (−44 % CPU per frame
   on Turing in #399). *Depends on:* host-pointer import working for every surface alignment (`nvmtl_vk.c:1412`
   copies otherwise), and whether the patch applies to 2.5.5.
6. **Fix the budget's knowledge of BAR1.** Ask RM for the real free and largest-contiguous BAR1 instead of
   assuming a 16 MB margin, so refusal happens before `mapMemory(KERNEL) failed`. *Depends on:* RM exposing those
   FB_GET_INFO indexes on this GSP build.
7. **Drop the scanout's CPU mapping when the display is in zero-copy mode.** This frees about 15 MB. *Depends on:*
   the copy-path fallback (`-nvrmnoflip`, refused flips) still having a target, perhaps by mapping it on fallback.
8. **Not a lever:** a bigger BAR1 (Turing's capability tops out at 256 MB), or NVK's `NVK_LOCAL_MAP_SYSMEM=0` (it
   needs BAR1 ≥ VRAM, so it stays off).

## 6. Needs measuring on Tahoe (this RTX 2060)

- `debug.nvrmfb_vram_budget_bytes`, `_display_bytes`, `_mapped_bytes`, `nvaccel_vm_refused`, `nvaccel_vm_parked`
  minus `_unparked` minus `_park_released` (live parks), and `nvaccel_iop_flip_novram` / `_iop_flips` /
  `_iop_src_surf`: idle desktop, then 10 windows, then Safari plus Photos for an hour.
- How many refusals come from the budget and how many from `mapMemory(KERNEL) failed` (fragmentation). The NVRMFB
  log prints both with the counters.
- Real BAR1 free and largest-free from RM, against the budget's assumptions (RM's own use and whether the USER map
  takes a second range).
- The four copy-path rows in section 3: surface-out ms from the plugin log, and kernel copy time per transaction
  (it is not timed today).
- Whether the CE page-off works on this card under Tahoe, and how often the family fallback page-off runs.
- Vulkan memory heaps and types NVK reports (is there a 256 MB DEVICE_LOCAL|HOST_VISIBLE heap?).
- Which IOAcceleratorFamily2 paths call `getApertureMemoryDescriptor` and read `vidmem+0xc8` (reverse-engineering
  or a counter).
