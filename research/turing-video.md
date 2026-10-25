# The Turing video path on Tahoe (RTX 2060, TU106)

Research for ticket `.scratch/rtx2060/issues/09-turing-video-path.md`. Checked against the `rtx2060` branch (code
identical to upstream tag `v2.5.5`), the v2.5.5 release tarball, NVIDIA's open-gpu-kernel-modules at tag `615.78.08`,
NVIDIA's support matrix, Apple's VideoToolbox docs and WebKit `main` (`89bfb3b`). Read on 2026-10-25. Builds on
`origin/research/community-fixes:research/community-fixes.md` §5 (mickys/nvenc), which this file does not repeat.

**Confidence tags.** **[code]** read in this tree. **[bin]** read from the shipped Mach-O files: symbols, strings and
constants only, nothing run. **[NV]** / **[Apple]** / **[WebKit]** primary source. **[issue]** a user's measurement in an
upstream issue. **[inferred]** my reading, not checked on hardware. Nothing here was run on a Mac.

## Gist

Hardware video on this driver is **four prebuilt user-space codec libraries**: H.264 and HEVC decode, H.264 and HEVC
encode. They ship inside `NVMTLDriver.bundle/Contents/MacOS/` and have no source in the repo. Each one drives
NVDEC/NVENC itself through NVAccel/NVRM. The Metal plugin `dlopen`s them and registers them with VideoToolbox's private
`VTRegister{Video,Encoder}WithInfo` SPI at rating 1000. That happens in two places:

- **In-process**, when a Metal device comes up (and so only if NVK came up).
- **Out of process**, from a load-time constructor in `VTDecoderXPCService`, for decoders only. Apple's sandboxed apps
  (Safari, QuickTime, Preview) send their decoding there.

On a TU106 the selection logic picks the right files: the classic-layout H.264 decoder (`_t2d`), the shared HEVC
decoder, and the `tu10x` encoders built for NVENC class `0xC4B7`, which is TU106's own class.

The copy-engine failure in #231 (`VkResult -13`) is NVK's **internal upload queue** failing on a copy-only channel. It
then falls back to a graphics channel, and that fallback worked in the #231 log. It does not touch the video libraries,
which open their own channels, and it does not touch page-off, which uses RM's in-kernel copy engine. The real risks to
the Video and Encode goals are elsewhere:

1. The H.264 decoder's CPU untile and copy path is about 36 fps at 4K on TU117.
2. There is no VP9 decoder at all.
3. The first VideoToolbox lookup misses the decoder in a fresh process.
4. Encoders are I/P only, allow one session per process, and register only in processes that make a Metal device.
5. On a 256 MB BAR1, the libraries' own mappings compete with the surface budget.

---

## 1. Where the libraries come from

| File in `NVMTLDriver.bundle/Contents/MacOS/` (v2.5.5) | Size | SHA-256 (first 8) | Factory export | Built for |
|---|---|---|---|---|
| `libnvdec_h264.dylib` | 62080 | `6068bacc` | `NVDecH264_CreateInstance` | Blackwell untile (mode 1) |
| `libnvdec_h264_t2d.dylib` | 62096 | `fdfd6e9c` | same | same code with mode 0 (classic). **TU106 loads this** |
| `libnvdec_hevc.dylib` | 80096 | `64b2353a` | `NVDecHEVC_CreateInstance` | every generation (`NVD265_LAYOUT`, default 0 = classic) |
| `libnvenc_h264_tu10x.dylib` | 62768 | `5c8beff5` | `NVEncH264_CreateInstance` | "Turing NVC4B7". **TU106 loads this** |
| `libnvenc_hevc_tu10x.dylib` | 71488 | `d6f1587e` | `NVEncHEVC_CreateInstance` | "Turing NVC4B7". **TU106 loads this** |
| `libnvenc_{h264,hevc}.dylib`, `*_ga10x.dylib` | — | — | — | Blackwell, Ampere |

Sources: `tar -tzf nullmoth-nvidia-2.5.5.tar.gz` (SHA-256 `3889abbe…`, matches the release's `SHA256SUMS.txt`); the
hashes and Mach-O facts come from a parser kept outside the extract directory. **[bin]**

- **No source, but not NVIDIA blobs.** All are x86_64 Mach-O, `minos 15.0`. The decoders were built against SDK 15.5
  and the `tu10x` encoders against SDK 26.5. They link only IOKit, CoreFoundation, CoreMedia, CoreVideo, VideoToolbox
  and libSystem. Each carries its own copy of an RM client shim (`nvRmApi*`, `nvrm_xnu_*`). Strings show it opening
  the **`NVAccel`** user client first and NVRM second ("no NVAccel and no NVRM service"). These are NullMoth's own
  closed codec implementations: bitstream parsers, DPB management, NVDEC/NVENC picture setup and a CPU detile/swizzle.
  **[bin]**
- **`_t2d` is the base decoder with one byte changed.** The two files differ at `0x163e` (`ba 01 00 00 00` →
  `ba 00 00 00 00`, the `nvd264_detile` mode) and in signature load commands. They share a UUID. This is the #65 patch
  (`tools/make_nvdec_t2d.py`). The script's hash guard (`ebf78288`, a 1.x build) no longer matches the 2.5.5 base
  (`6068bacc`), so re-running it against 2.5.5 would refuse. **[bin][code]**
- **The decoders' own description strings still say "RTX 5060 NVCFB0"**, the Blackwell class. The class they actually
  allocate is the newest one in the RM class list ("no NVDEC class in classlist"), which is `0xC4B0` on TU106.
  **[bin][inferred]**
- **The encoders replay recorded setups.** They contain the symbols `_nvs_I_0…4` / `_nvs_P_0…4` (H.264) and
  `_nvh_I_*` / `_nvh_P_*` (HEVC), the string "replayed oracle setup", and the knobs `ENC_SETUP`/`ENC_LAYOUT`. The plugin's
  comment says each library is "checked byte-for-byte against NVIDIA's own output on that generation"
  (`plugin/NVMTLDevice.m:233-238`). Their templates are I and P only: no B-pictures. **[bin][code]**
- **Pixel formats (inferred from FourCC constants in the binaries).**
  - H.264 decode: `420v`/`420f` (8-bit NV12).
  - HEVC decode: `420f`, `x420`, `xf20` (10-bit for Main10).
  - H.264 encode input: `420v`/`420f`.
  - HEVC encode input: also `x420`/`xf20`, plus knobs `NVE265_LAYOUT10` and `NVE265_P010SHIFT`.

  **[bin][inferred]**
- **Hard limits, from the strings.** **[bin]**
  - H.264 decode: "8-bit 4:2:0 only". It rejects interlaced/field/MBAFF, **SPS/PPS scaling matrices**, FMO, frame_num
    gaps and resolution changes mid-stream.
  - HEVC decode: "Main/Main10 4:2:0 only". It rejects range extensions and **tiles**, and changes of resolution, depth or
    DPB mid-stream.
  - Encoders: "engine already in use in this process" (one session per process, `_g_busy`), and a size range ("outside
    the engine's H.264 range"; HEVC: "outside the range this encoder was measured for").
- **How frames move.** **[bin][inferred]**
  - The decoders take a buffer from `VTDecoderSessionGetPixelBufferPool`, lock it
    (`CVPixelBufferLockBaseAddress`/`GetBaseAddressOfPlane`), detile on the CPU into it (`_detile_row`; HEVC splits rows
    with `dispatch_apply`), then call `VTDecoderSessionEmitDecodedFrame`.
  - The encoders do the reverse: they lock the source buffer and swizzle it on the CPU (`_sw_t2d`/`_sw_bw8`/`_sw_bw16`)
    into the engine's input layout.
  - So every 4K NV12 frame (≈12.4 MB) crosses the CPU once on each path.

## 2. Selection per generation

1. **NVRM publishes a profile.** `NVRM::publishGpuProfile()` (`kexts/NVRM/NVRM.cpp:1247-1289`) asks the RM for
   `MC_GET_ARCH_INFO` and the newest class of each engine type (`nvrm_query_gpu_profile`,
   `kexts/NVRM/nvrm_fbinfo.cpp:156-215`, where `xxB0` = decode and `xxB7` = encode). It publishes `nvrm-gpu-profile` on the
   PCI device. For TU106 that profile is: arch `0x160`, impl ≠ 7/8, so `generation = "Turing"` and `chip = "TU106"`;
   `class-nvdec 0xC4B0`, `class-nvenc 0xC4B7`, `class-copy 0xC5B5`; `video-layout = "classic"` (`arch < 0x1A0`);
   `scanout = "by-handle"` (BAR1 < VRAM). **[code]**
2. **RM's own class table agrees.** `gpuGetEngClassDescriptorList_TU106` in `src/nvidia/generated/g_gpu_class_list.c`
   (615.78.08) lists `NVC4B0_VIDEO_DECODER`, `NVC4B7_VIDEO_ENCODER` and `TURING_DMA_COPY_A` on `ENG_CE(0..4)`.
   For comparison, **TU117 has `NVB4B7` (a Volta-class NVENC)**, which explains why mickys' TU117 encoders don't carry
   over to TU106 and NullMoth's `tu10x` ones do. **[NV]**
3. **The plugin picks files** (`plugin/NVMTLDevice.m`):
   - `nvmtl_video_is_blackwell()` (`:221-230`) reads `video-layout`. For "classic" the H.264 decoder is
     `libnvdec_h264_t2d.dylib` (`:304`).
   - The HEVC decoder is always `libnvdec_hevc.dylib` (`:420`).
   - `nvmtl_nvenc_library_for_this_gpu()` / `…_hevc_…` (`:239-260`) match `generation` on its first word
     (`nvmtl_gen_is`, `:216-220`), so "Turing" gets `libnvenc_h264_tu10x.dylib` and `libnvenc_hevc_tu10x.dylib`. Ada
     gets none. `tools/test_gtx16_nvenc_picker.py` pins this. **[code]**
   - The block comment at `:185-189` ("The encoders are not registered on them") is stale: 2.4 added Turing and Ampere
     encoders (`CHANGELOG.md:77`). **[code]**
4. **Registration.** Each register function (`:286-315`, `:316-345`, `:402-431`, `:471-500`) does the same steps:
   - `dispatch_once`, then skip WindowServer.
   - `dlsym(RTLD_DEFAULT, "VTRegisterVideoDecoderWithInfo")`, or the encoder equivalent.
   - `dlopen` the library from the plugin's own directory (`dladdr` → `dirname`) and `dlsym` its `…_CreateInstance`.
   - Register `'avc1'`/`'hvc1'` with `{CMClassImplementationID: com.nvmtl.video{de,en}coder.{avc,hevc}.nvdec|nvenc,
     VTRating: 1000, VTIsHardwareAccelerated: YES}`.

   Opt-outs: `NVMTL_NO_NVDEC`, `NVMTL_NO_NVDEC_HEVC`, `NVMTL_NO_NVENC`, `NVMTL_NO_NVENC_HEVC`. **[code]**
5. **When registration runs.** In a normal process it runs from `-[NVMTLDevice initWithAcceleratorPort:]`
   (`:603-629`), and only after three things pass: `nvmtl_process_is_allowed()` (the shipped `nvmtl-allow.txt` is
   `*` / `!WindowServer`), `nvmtl_vk_init()` succeeding, and vendor `0x10de`. **No Metal device, or no NVK device, means
   no hardware codecs in that process.** **[code]**
6. **Opt-in external codecs.** `nvmtl_nvencvt_register()` (`:366-401`) loads `libnvencvt.dylib` (mickys) at rating
   1100 when `NVMTL_NVENCVT` is set. It is called only from the Metal-device path (`:628`), never from the decode
   service. **[code]**

## 3. Sandboxed apps (Safari, QuickTime, Preview)

- **Delegation (PR #349, in 2.5.4; refined in 2.5.5).** `nvmtl_decode_is_delegated()` (`:279-284`) is true when the
  process is sandboxed (`sandbox_check(getpid(), NULL, 0)`), is not `VTDecoderXPCService`, and has a main-bundle ID
  starting `com.apple.`. In those processes the decoders are not registered in-process (`:292-295`, `:408-411`).
  VideoToolbox then decodes in `VTDecoderXPCService`. Chromium and Electron keep in-process decoders (`CHANGELOG.md:5`;
  `tools/test_decode_delegation.py`). **[code]**
- **Registration inside the service (#175, in 2.1.0).** The constructor `nvmtl_nvdec_in_decode_service()`
  (`:439-469`) runs when Metal maps the bundle into `VTDecoderXPCService`. It runs **without** a Metal device. It finds
  an NVIDIA display-class PCI device, reads `video-layout`, then registers the H.264 and HEVC decoders on a
  `dispatch_async` utility queue (kept async on review of #349, so it does not dlopen under dyld's lock). **[code]**
- **Why the libraries work in a sandbox at all.** They open the `NVAccel` (IOAccelerator) user client before NVRM.
  #175 found the `VTDecoderXPCService` profile denies the NVRM user client (`IOServiceOpen` → `0xe00002e2`), and that
  the WebKit GPU process denies `file-map-executable` under `/Library/GPUBundles`. **[bin][issue]**
- **Encoders have no out-of-process route.** No `VTEncoderXPCService` hook exists, so the encoders register only
  in-process, and only after a Metal device. #349's review removed the sandbox skip from encoders for that reason
  (`pr view 349`). A require-hardware encode session opened before any `MTLDevice` returns `-12908` (#175, RTX 3060 Ti,
  2.5.1). **[issue]**
- **First-lookup race (still open).** VideoToolbox copies its decoder list (`FigRegistryCopyFilteredItemList`) before
  the GPU enumeration that loads the plugin. So in a fresh process the first `VTIsHardwareDecodeSupported(H264)` is
  `0`, then `1` (#175, 2.5.1). mickys reports the same for ffmpeg. Whether `VTDecoderXPCService`'s first session also
  misses (its registration is async) is untested. **[issue]**
- **Third-party VT plug-in bundles don't help.** A decoder bundle in `/Library/Video/Plug-Ins` was not loaded, even at
  score 1000 (#175, eisda). Apple documents no third-party decoder plug-in interface. `VTRegisterSupplementalVideoDecoderIfAvailable`
  (macOS 11+) registers only *system* supplemental decoders ("if one exists on the current system").
  **[issue][Apple]**

## 4. The copy-engine failure (#231, `VkResult -13`)

**What the code does** (`nvk/nvk-macos.patch`, file `src/nouveau/vulkan/nvkmd/nvrm/nvkmd_nvrm_ctx.c`):

- `nvkmd_nvrm_create_exec_ctx()` (patch lines 8990-9002) first tries `…_on(…, allowCe=true)`. For
  `NVKMD_ENGINE_COPY` with `CECHAN` on (the default: `nvrm610_on()` returns true unless `NVRM_610_CECHAN=0` or
  `CECHAN=0` is in `nvrm610.conf`, lines 8089-8112), that builds a copy-only channel on
  **`NV2080_ENGINE_TYPE_COPY4`** (8770-8771). It is a privileged channel with no TSG (8794).
- If the channel is refused, it retries on GRAPHICS (8809-8813).
- The copy object is then allocated with **NULL alloc params** (8853). The partner-CE retry with
  `NVB0B5_ALLOCATION_PARAMETERS` runs **only when `!ctx->ceOnly`** (8854-8870). On the copy-only channel the failure
  goes straight to `NV_CHECK`, which maps every RM error to `VK_ERROR_UNKNOWN` = **-13** (8194).
- The outer function then logs `copy-engine queue could not be built on this GPU (VkResult -13) - copy queue on a
  graphics channel` and rebuilds on a GRAPHICS channel (8997-8999). There a NULL-param copy object is refused once
  more on Turing, and the partner-CE retry names the engine (comment at 8840-8847, from a GTX 1650 log on 10-07).
  **[code]**

**Why -13 on Turing (likely cause, not tested on hardware).** In RM `chandesConstruct_IMPL`
(`src/nvidia/src/kernel/gpu/fifo/channel_descendant.c`, 615.78.08), the object's engine comes from the channel's
engine type only "from Ampere onwards", when per-runlist CHRAM or host engine expansion is on. "For legacy chips"
(Turing) the engine comes from the alloc params via `kceGetEngineDescFromAllocParams`
(`kernel_ce_context.c:60-149`). With NULL params it falls to `gpuGetClassByClassId(TURING_DMA_COPY_A)`, the first CE
listed for the class, which is not the COPY4 the channel is bound to. The object is then refused, or fails the runlist
check (`kfifoRunlistSetIdByEngine_HAL`). Ampere and later resolve it from the channel, which is why the copy-only path
works there. The #231 log line `nvkmd_nvrm_ctx.c:764: VK_ERROR_UNKNOWN` matches an `NV_CHECK` in this function.
**[NV][inferred]**

**What uses that queue.** Only NVK's internal upload queue (`nvk_upload_queue_init`, patch line 4228). Upstream Mesa
builds it with `NVKMD_ENGINE_COPY`. It carries NVK's own uploads: shader heap, descriptor tables, small buffer fills.
The plugin's Metal queues are on the graphics+compute family (`plugin/nvmtl_vk.c:768`). **[code][inferred]**

**What falls back, and what that costs.** The upload queue runs on a second GRAPHICS channel:
- **CPU and time:** one extra failed-channel setup and teardown at every `vkCreateDevice`, in every Metal process.
- **GPU:** uploads time-slice on the graphics engine with rendering instead of running on an async copy engine.
- **VRAM:** that second channel's GR context, plus the preemption buffers this path allocates for every non-CE
  channel (8879-8925, `NVKMD_MEM_LOCAL`).

None of these costs has been measured. My estimate is a small per-process VRAM cost and some extra start-up time, not
a per-frame cost. **[inferred]**

**Relation to video.** Indirect only:
- The codec libraries never touch NVK. They allocate their own NVDEC/NVENC channels through their own RM client
  (`nvd264: classes…`, `nve264: classes: encoder 0x%x channel 0x%x`). **[bin]**
- The one real coupling is that in-process registration is gated on `nvmtl_vk_init()` (`NVMTLDevice.m:618-629`). If the
  graphics-channel fallback also failed, `vkCreateDevice` would fail, so there would be no Metal device and no hardware
  codecs. In #231 the fallback worked (Metal 3 shown). **[code]**
- `VTDecoderXPCService` registration doesn't depend on NVK at all. **[code]**

**Relation to surface page-off.** None. Page-off copies (`kexts/NVRM/nvrm_pageoff.c`) use RM's in-kernel `CeUtils`
(`memmgrInitCeUtils`, `ceutilsMemcopy`), a separate kernel channel. They don't use NVK's upload queue. **[code]**

**What #231's "video decode fails" probably is.** Not the -13. Two data points:
- **RTX 2060, 2.0.x-era, Tahoe:** no decode log was posted.
- **GTX 1650 SUPER, 2.3.0, 26.7.1:** YouTube in Safari errors out silently, while BAR1 is **100 % full**
  (`nvrmfb_vram_mapped_bytes == budget`, refusals still climbing).

Both predate 2.5.4's Safari delegation. My candidates, in order: BAR1 exhaustion (new pixel-buffer surfaces refused,
and the libraries' own BAR1 maps; Dora-z saw NVENC fail with `NV_ERR_NO_MEMORY` at a 16 MB margin), the Safari GPU
process not loading the plugin, and VP9 (see §5). **[issue][inferred]**

## 5. Codec matrix (TU106)

Hardware: NVIDIA support matrix, rows "GeForce RTX 2060 / 2070" (NVENC 7th gen, 1 NVENC) and "GeForce RTX 2060
(TU104)". Engine classes: `g_gpu_class_list.c`. **[NV]**

| Codec | TU106 hardware | macOS asks VT for it? | Wired today (2.5.5) |
|---|---|---|---|
| H.264 decode 8-bit 4:2:0 | Yes (NVDEC 4th gen, `C4B0`) | Yes (Safari, QuickTime, AVFoundation, Chromium) | **Yes**, `libnvdec_h264_t2d`. No interlaced, no scaling matrices. 4K ≈ 36 fps on TU117 (community-fixes §5) |
| H.264 decode 10-bit / 4:2:2 | No | — | — |
| HEVC Main decode | Yes | Yes | **Yes**, `libnvdec_hevc`. No tiles. Correct on GA104 (#65). **Not yet confirmed on Turing** |
| HEVC Main10 decode | Yes (also 12-bit, 4:4:4) | Yes (HDR in Safari, QuickTime, TV) | **Yes** (`x420`/`xf20` output); untested on Turing |
| VP9 decode 8/10/12-bit | Yes | Yes: WebKit asks `VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)` | **No** in NullMoth. Only mickys `libnvencvt` (opt-in, Metal-device processes only, **not** in `VTDecoderXPCService`, so not Safari) |
| AV1 | No | — | Out of scope |
| H.264 encode | Yes (`C4B7`) | Yes | **Yes**, `libnvenc_h264_tu10x`: I/P only, 1 session per process; keyframe `NotSync` fixed in 2.5.5 (#388, measured on an RTX 2060) |
| HEVC Main encode | Yes, B-frames too | Yes | **Yes**, `libnvenc_hevc_tu10x`: I/P only; "keeps going past the second frame" fix in 2.4.4 |
| HEVC Main10 encode | Yes | Yes (HDR export) | Probably (`x420`, `NVE265_LAYOUT10` in the binary); untested |

**Why VP9 matters most for Safari** **[WebKit]**. In `Source/WebCore/platform/graphics/cocoa/VP9UtilitiesCocoa.mm`:

- `shouldEnableSWVP9Decoder() = isSWDecodersAlwaysEnabled() || (!vp9HardwareDecoderAvailable() && !systemHasBattery())`.
- `isVP9DecoderAvailable()` on macOS is `(shouldEnableSWVP9Decoder() && VideoDecoder::isVPXSupported()) ||
  vp9HardwareDecoderAvailable()`.

A desktop Mac with no battery (this machine, MacPro7,1) therefore advertises VP9 and decodes it with WebKit's software
libvpx. **If YouTube serves VP9 to Safari for 4K60, that playback is software today, whatever NVDEC H.264 does.**
That last step is inferred; check it with "Stats for nerds".

## 6. Known-broken list (upstream issues)

| Issue | Card / version | Status for us |
|---|---|---|
| #231 | RTX 2060, Tahoe; GTX 1650S 2.3.0 | Open; owner asked for a retest on 2.5.x. -13 is the upload-queue fallback (§4); decode failure undiagnosed (BAR1 full in the TU116 data) |
| #206 | RTX 2070S, hand-patched H.264 encoder | Open. Sunshine opens a 2nd session before closing the 1st, and the lib refuses it ("engine already in use in this process"), so x264 is used. The string is still in 2.5.5's `tu10x` libs, so likely still present |
| #388 | RTX 2060, 2.5.4, UU Remote | Fixed in 2.5.5 (`CHANGELOG.md:6`): sync frames no longer carry `NotSync=false` |
| #175 | 5070 Ti / 3060 Ti | Closed (2.1.0 decode-service registration). Still open inside it: first-lookup race; no encoder before an `MTLDevice` |
| #65 | GA104, TU117 | Fixed: `_t2d` decoder; the encoders were later rebuilt per generation |
| #179 | 5070 Ti | Green lines from VideoToolbox's Metal scaler (translator); fixed in #180. VT's transfer path runs through our shader translator (`NVMTLLibraryLoad.m:381-385`) |
| #215 / #237 | RTX 2060 SUPER / 3070M, 2.0.x | "Video jumps to previous frames": desktop presentation, said fixed in 2.1.0 / better in 2.5.2 |
| PR #348 / #349 | 4080, Sequoia | Merged 2.5.4: ANGLE for Discord; Safari, QuickTime and Preview decode via `VTDecoderXPCService`. **Not verified on Tahoe or Turing** |

## 7. What replacing or extending the libraries involves

- **The interface we must fill (from the binaries' imports and locals).**
  - Decoders: a CoreMedia derived object (`CMDerivedObjectCreate` with a `VTVideoDecoder` class ID) whose vtable gives
    `StartSession`, `DecodeFrame`, `CopySupportedPropertyDictionary`, `SetProperties`/`CopyProperty`,
    `CanAcceptFormatDescription`, `FinishDelayedFrames`, `Invalidate`/`Finalize`. Output goes through
    `VTDecoderSessionSetPixelBufferAttributes`/`GetPixelBufferPool`/`EmitDecodedFrame`.
  - Encoders: the same, with `EncodeFrame`/`CompleteFrames` and `VTEncoderSessionEmitEncodedFrame`.
  - The headers are private SPI. mickys vendors WebKit's copies (`vendor/`, MIT repo). **[bin][inferred]**
- **Drop-in replacement with no plugin change.** Ship a dylib with the same name exporting the same `…_CreateInstance`.
  `dlopen` only needs the file next to `NVMTLDriver`, then re-sign the bundle (`codesign -f -s -`, as #388 did). That
  is the cheapest path for H.264 and HEVC.
- **New codecs (VP9).** These need plugin code: a `nvmtl_nvdec_vp9_register()` registering `'vp09'`. It must be called
  from the Metal path **and** from `nvmtl_nvdec_in_decode_service()`, and kept out of the `nvmtl_decode_is_delegated`
  skip. Alternatively, load mickys `libnvencvt.dylib` in the decode service (today `nvmtl_nvencvt_register` runs only at
  `:628`). Either way it must also answer `VTIsHardwareDecodeSupported('vp09')`, which is what WebKit asks.
- **Engine programming.** We can build on these:
  - NVIDIA's open-gpu-doc publishes NVDEC/NVENC driver structs (`classes/video/nvdec_drv.h`, `nvenc_drv.h`) and later
    class headers (`clc5b0`, `clc6b0`, `clc5b7`, …). The open kernel module gives `clc4b0.h`/`clc4b7.h` names only.
  - mickys/nvenc (MIT) already has C4B0-class decoders that are bit-exact against ffmpeg on TU117, including VP9. Its
    TU117 *encoder* setups target `B4B7` and don't apply to TU106.
  - The NullMoth encoders replay NVIDIA-captured setups. A new TU106 encoder (B-frames, multiple sessions) would need
    new captures from NVIDIA's Windows or Linux driver on this card, plus a byte compare.
- **Performance work inside a library.**
  - Replace the CPU detile with output in a layout the client accepts (mickys' 4K finding: hand out pictures from a
    pool made with the client's destination attributes, so VideoToolbox does not run a pixel transfer per frame:
    15 → 0.05 ms per 4K frame on GA10x).
  - Or untile on the GPU into an IOSurface-backed pool.
- **Licensing and trust.** The NullMoth libraries ship under the repo's PolyForm Noncommercial license with no source.
  mickys is MIT. `libnvencvt` must be root-owned in a root-owned directory (`nvmtl_loadable_root_only`, `:355-365`).

## 8. Candidate levers (not designs)

1. **Install mickys `libnvencvt` (0.9.5) on TU106** and measure its C4B0 decoders (H.264 4K, HEVC, VP9) in QuickTime and
   AVFoundation. Its encoders likely won't open, since it targets B4B7. Check that ours remain the fallback (rating 1100
   vs 1000).
2. **Load the external decoders in `VTDecoderXPCService`**: extend the constructor at `:439` to `nvmtl_nvencvt_register`
   (decoders only). This is the one route by which Safari and QuickTime could get VP9 and the faster H.264.
3. **Register a VP9 decoder** so `VTIsHardwareDecodeSupported(VP9)` is true. That flips WebKit off libvpx (§5).
4. **Reserve BAR1 for the codec libraries** (Dora-z `1bf8737`/`40e9f96`: 48–96 MB margin) whatever the surface plan is.
5. **Close the first-lookup race**: register at plugin load instead of at Metal device creation, or poke VideoToolbox so
   its list is copied after registration.
6. **Encoder session limit (#206)**: allow two sessions per process, or release on `Invalidate` before the next
   `StartSession`.
7. **Silence or fix the -13**: pass `NVB0B5_ALLOCATION_PARAMETERS{VERSION_1, engineType=COPY4}` on the copy-only channel
   on Turing, or set `CECHAN=0` for TU106 and skip the doomed attempt. Low value for video; small start-up and VRAM win.
8. **Fix the stale comment** at `NVMTLDevice.m:185-189` and the dead hash guard in `tools/make_nvdec_t2d.py`.
   Cosmetic.

## 9. What to verify on Tahoe (RTX 2060)

- **Boot log and profile:** `ioreg -l | grep -A20 nvrm-gpu-profile`. Expect Turing TU106, nvdec `0xc4b0`, nvenc
  `0xc4b7`, copy `0xc5b5`, video-layout classic.
- **Does the -13 line still appear on 2.5.5,** and is there an `nvk-reason: nvrm copy-engine retry …` line with
  `retry rc 0`? Compare VRAM per Metal process with `NVRM_610_CECHAN=0`.
- **`nvmtl.log` per process:** `nvdec: H.264 decoder REGISTERED … libnvdec_h264_t2d.dylib`, the HEVC decoder,
  `nvenc: … libnvenc_h264_tu10x.dylib`, `libnvenc_hevc_tu10x.dylib`. In `VTDecoderXPCService`: `decode service, GPU
  10de:1f08 …` (or whichever TU106 ID this card has).
- **Which decoder actually runs:**
  - `sample VTDecoderXPCService` during Safari and QuickTime playback: frames in `libnvdec_*`, not `AppleH264SW` or
    `AppleHEVC*`.
  - Test 1080p and 4K60 H.264, HEVC Main and Main10.
  - Count dropped frames: AVPlayer `droppedVideoFrames` logs, or Safari "Stats for nerds".
- **Per-picture timing:** `NVDEC_VT_VERBOSE=1` and `NVD265_VERBOSE=1`. The HEVC close line prints feed+engine / pool /
  detile / emit ms per picture, which is the 4K60 budget check (16.7 ms).
- **YouTube in Safari:** which codec "Stats for nerds" shows (vp09 vs avc1), and the CPU use of the WebKit GPU and
  WebContent processes.
- **First-lookup race:** a fresh process calling `VTIsHardwareDecodeSupported('avc1')` twice; and the first session in
  `VTDecoderXPCService`.
- **Encoders:**
  - `VTCopyVideoEncoderList` in an app that made an `MTLDevice`.
  - OBS (VideoToolbox H.264/HEVC), HandBrake (GUI vs CLI: no Metal device, so expect Apple's software encoder).
  - FaceTime (`avconferenced`) and Screen Sharing: does `com.nvmtl.videoencoder.*` get picked, and does the process log
    an NVMTLDevice?
  - Sunshine or any two-session client (#206).
- **BAR1 during video:** `sysctl debug.nvrmfb_vram_mapped_bytes debug.nvrmfb_vram_budget_bytes debug.nvaccel_vm_refused`
  before and during 4K playback and encode. Watch for `NV_ERR_NO_MEMORY` / `alloc … -> 0x51` in the libraries' stderr.
- **HEVC decode correctness on Turing** (no green or shifted rows; only GA104 is confirmed). Also scaling-matrix H.264
  streams: they should fall back to software rather than fail.

## Sources

- Code: `plugin/NVMTLDevice.m` (lines cited), `kexts/NVRM/NVRM.cpp:1238-1289`, `kexts/NVRM/nvrm_fbinfo.cpp:149-215`,
  `kexts/NVRM/nvrm_pageoff.c`, `nvk/nvk-macos.patch` (lines cited), `package/install.sh:47,386-406`, `CHANGELOG.md`,
  `tools/make_nvdec_t2d.py`, `tools/test_gtx16_nvenc_picker.py`, `tools/test_decode_delegation.py`.
- Release: https://github.com/nullmoth/nvidia-macos-driver/releases/tag/v2.5.5 (`nullmoth-nvidia-2.5.5.tar.gz`).
- NVIDIA: https://developer.nvidia.com/video-encode-and-decode-gpu-support-matrix-new ;
  https://github.com/NVIDIA/open-gpu-kernel-modules/blob/615.78.08/src/nvidia/generated/g_gpu_class_list.c ;
  `…/src/nvidia/src/kernel/gpu/fifo/channel_descendant.c` ; `…/src/nvidia/src/kernel/gpu/ce/kernel_ce_context.c` ;
  `…/src/common/sdk/nvidia/inc/class/clc4b0.h`, `clc4b7.h` ; https://github.com/NVIDIA/open-gpu-doc/tree/master/classes/video
- Apple: https://developer.apple.com/documentation/videotoolbox/vtregistersupplementalvideodecoderifavailable(_:) ;
  https://developer.apple.com/documentation/videotoolbox/kvtvideodecoderspecification_requirehardwareacceleratedvideodecoder
- WebKit: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/cocoa/VP9UtilitiesCocoa.mm
- Upstream issues and PRs (read-only): nullmoth/nvidia-macos-driver #231, #206, #388, #175, #179, #215, #237, #65,
  PR #348, #349.
- mickys/nvenc README: https://github.com/mickys/nvenc (pushed 2026-10-24, tag v0.9.5).
