# Shader translation and pipeline cost (ticket 06)

Research for `.scratch/rtx2060/issues/06-shader-translation-cost.md`. Code refs are to branch `rtx2060` (upstream tag
v2.5.5, commit a217742). Mesa refs are to `nvk/MESA_BASE` = `17ca6174` (fetched read-only from
gitlab.freedesktop.org). Nothing here was measured on Tahoe. Every claim about runtime behaviour comes from reading
the code, unless it cites #370 or NvGfx#11, which report measurements on other machines.

## Answer in one paragraph

On this driver a Metal shader is turned into GPU code in two stages. Both run **synchronously on the thread that made
the Metal call**. (1) AIR → SPIR-V: the in-process Rust translator runs inside `newFunctionWithName:` (no constants),
inside `newFunctionWithName:constantValues:` / `newFunctionWithDescriptor:` (one full-module translate per distinct
constant set), and again **at draw/dispatch time** for sampler-state and threadgroup variants. (2) SPIR-V → NIR →
NAK: runs inside `vkCreateGraphicsPipelines` / `vkCreateComputePipelines`, called from `newRenderPipelineState…`, and
also at draw time when a sampler variant needs a new pipeline. Caches: an in-process NSCache memo (empty at every
process start), a per-process library index, and on-disk caches. The disk caches live in **per-user, per-sandbox
folders**. Their keys include the **SHA-256 of the translator dylib** (SPIR-V) and the **LC_UUID of the NVK ICD**
(NAK binaries), so every translator or NVK rebuild throws them all away. A cache write happens on the caller's thread
(`writeToFile:atomically:`, which #370 caught as an `fsync`), and so do a read and a `utimes` on every hit. A real
Mac does little at `newFunction` time: GPU code is made at pipeline creation by the out-of-process
`MTLCompilerService` and kept in a system Metal shader cache, and binary archives can skip compilation altogether. So
login, first app launches and Settings icons pay for translation and NAK compilation in every process (WindowServer,
iconservicesagent, each sandboxed app) whenever its caches are cold. They are cold on the first boot after any
driver build that changes the translator or NVK, and the in-memory part is cold at every login.

## 1. The path, stage by stage

### 1a. Translator load (once per process)

- `nvmtl_xlate_ready()` `plugin/NVMTLLibraryLoad.m:101-145`: `dispatch_once` inside the first library or function
  call. It `dlopen`s `libnvmtl_translate.dylib` and then **reads and SHA-256-hashes the whole dylib**
  (`nvmtl_translator_cache_tag`, `:52-76`, called at `:109`) to make the cache tag `sha256-<hex>` (plus `-u2` unless
  `NVMTL_NO_AIR_UNROLL`, `:110`). Thread: whichever thread first touches a shader. Sync. The cost grows with the
  dylib's size; it is paid once per process.

### 1b. `newLibraryWithURL:` / `newLibraryWithFile:` / `newLibraryWithData:` (`plugin/NVMTLDevice.m:1290-1398`)

All of these run synchronously on the caller:

1. Read the whole metallib (`dataWithContentsOfURL`, `:1363`).
2. **Library key**: SHA-256 of the whole library, unless the **library key memo** (`lk1-<path hash>.bin` in the AIR
   cache folder) matches dev/ino/size/mtime/ctime and the first and last 64 KiB (`nvmtl_libkey_for_file`,
   `NVMTLLibraryLoad.m:1078-1124`). A miss writes a temp file and renames it, on the caller.
   `newLibraryWithData:` has no path, so it always hashes (`nvmtl_translate_metallib` → `nvmtl_lib_sha256`).
3. **Library index**: an in-process LRU of 16 libraries, 128 MiB budget, with weak entries
   (`nvmtl_translate_metallib_k`, `:1129-1183`). It is empty at process start.
4. On an index miss, the **disk index** `idx2-<libkey>.plist` (`nvmtl_index_metallib_disk`, `:1029-1058`). On a hit
   the AIR blobs are kept by reference and decoded lazily (`NVMTLLazyAirs`, `:979-998`). On a miss it scans the
   whole library and calls `nvmtl_air_to_text` **for every bitcode blob** (`:898-947`), then writes the plist with
   tmp+rename on the caller.
5. `nvmtl_air_to_text` (`:636-663`): AIR bitcode → LLVM text IR. It first tries the **AIR cache**
   `<sha256(air)>.ll|.u2.ll`, then an in-process LLVM bitcode reader (`:605-634`). Without that reader it
   **`posix_spawn`s `air-opt`** and polls `waitpid` every 10 ms for up to 20 s (`:445-474`), writing temp files to
   `NSTemporaryDirectory()`. A miss writes the `.ll` with `writeToFile:atomically:YES`. These texts are megabytes
   (comment at `:381-385`).
6. `newLibraryWithData:` also calls `nvmtl_vendor_compile_airs`. It is a no-op unless `NVMTL_VENDOR_COMPILER` is set
   (`plugin/NVMTLVendorCompiler.m:26-30, 211-224`). The direct-SASS path (`plugin/NVMTLSass.m` header) is RTX 50
   only (sm_120), so neither applies to TU106.

On Apple's stack, creating a library does no GPU code generation (WWDC22 10102, below).

### 1c. `newFunctionWithName:` with no constants (`plugin/NVMTLObjects.m:2351-2385`)

`nvmtlEntrySpirv` (`:2326-2349`) is memoized per `NVMTLLibrary` object in `_compiledFns`. On a miss it calls
`nvmtl_compile_library_entry` (`NVMTLLibraryLoad.m:854-896`):

- key `sha256(air bytes).<stage>.<tag>.c3.spv` (`nvmtl_spvcache_path`, `:375-379`);
- a synchronous `dataWithContentsOfFile` on every call (this path has **no NSCache memo**), then `utimes` on a hit;
- on a miss, `xlate()` (full translate), then `writeToFile:options:NSDataWritingAtomic` **on the caller** (`:870`).

### 1d. `newFunctionWithName:constantValues:` / `newFunctionWithDescriptor:` (`NVMTLObjects.m:2399-2544`)

This is the #370 stack: CA `load_shader_function` → `newFunctionWithDescriptor:` → `…constantValues:` →
`nvmtl_translate_with_fc_cached` (`NVMTLLibraryLoad.m:1240-1278`):

- key: SHA-256 over size‖AIR text‖sorted JSON `{stage, entry, constants}`, kind `fc1`. The AIR-text hash state is
  kept on the NSString (`nvmtl_air_state`, `:397-413`). The first key for each text pays a UTF-8 conversion and hash
  of megabytes.
- memo (`nvmtl_memo`, `:429-433`: NSCache, **256 entries / 96 MiB**, per process) → disk read → else
  **`specialize_air_function_constants` + full translate of the module** (`translator/wrapper/src/lib.rs:407-460`;
  the translator is stateless, so all caching is in the plugin);
- a miss does `writeToFile:atomically:YES` **on the caller** (`:1271`). Both memo and disk hits call `utimes()` on
  the caller (`:1254, 1258`).
- #370 measured `fc1` entries at about **584 KB each**. At that size the 96 MiB memo holds only about 165 of them,
  fewer than the 404 entries found in one WindowServer cache.
- The `completionHandler:` variants are **not asynchronous**. They call the sync method and then the handler inline
  (`NVMTLObjects.m:2510-2516, 2546-2551`).

Reflection (`refl1`, `nvmtl_reflect_air_cached`, `:1316-1350`) works the same way: memo → disk → translate, with a
sync write at `:1345`. It runs at first `nvmtl_function_reflection` (`:1390`), i.e. at pipeline creation.

### 1e. `newRenderPipelineStateWithDescriptor:` (`plugin/NVMTLDevice.m:1494-1629`)

- Sync on the caller. It links stages, reads reflection (above), and may build an A8 sampler variant
  (`nvmtl_translate_samplers`, `:1591`) and a varying-link SPIR-V (`nvmtl_varying_link`, `:827`, used at `:1601`).
  It then calls `nvmtl_vk_pipeline_create_rt` (`:1622/1624`).
- `nvmtl_vk_pipeline_create_rt` (`plugin/nvmtl_vk.c:4120-4320`) does `vkCreateShaderModule` ×2 (`:4214-4215`) and
  then `vkCreateGraphicsPipelines(g_dev, VK_NULL_HANDLE, …)` (`:4308`). Compute pipelines go the same way at
  `:4413-4422`. **No VkPipelineCache is passed.**
- The plugin keeps no cache of Metal pipeline states keyed by descriptor (besides the sampler-variant cache in 1f),
  so each call reaches NVK.
- The async forms (`:1675-1690`) run on `nvmtl.pipeline.compile`, an NSOperationQueue at QoS user-initiated whose
  width is cores−1 (at most 8, and at most half the RAM in GB) (`:1652-1673`). CA's `dispatch_async_pipeline` is
  CA's own thread calling the **sync** API, so on WindowServer this pool is not used for the #370 path.

### 1f. Draw and dispatch time: sampler and threadgroup variants

- Render: `nvmtlBindSamplerPipeline` (`NVMTLObjects.m:2776-2789`) → `nvmtlSamplerPipeline` (`:2728-2774`). The first
  time a pipeline is used with a given sampler set (per pipeline state, in `_samplerVariants`; device-wide
  `g_sampvar`, at most 1024 entries, cleared when full, `:2701-2714`), it **translates both stages again**
  (`nvmtl_translate_samplers`, `NVMTLLibraryLoad.m:1798+`) and **creates a whole new pipeline, NAK compile included**,
  inside the encoder call on the encoding thread.
- Compute: `nvmtlSamplerPipeline` (`NVMTLObjects.m:4306-4340`) → `nvmtl_translate_variant` (`variant1` cache, memo →
  disk → translate, sync write at `NVMTLLibraryLoad.m:1793`) → `nvmtl_vk_compute_pipeline_create`. This also runs at
  dispatch time.
- Neither exists on Apple's stack: Metal resolves sampler state at runtime and doesn't specialize on it.

### 1g. NVK: SPIR-V → NIR → NAK (Mesa 17ca6174 plus `nvk/nvk-macos.patch`)

- With `VK_NULL_HANDLE`, the Vulkan runtime uses `device->mem_cache` (`vk_pipeline.c:2257-2258, 2665-2666`). NVK
  creates it at device creation (`nvk_device.c:379-382`, `weak_ref`, `skip_disk_cache` not set). It is **in memory,
  per process, empty at start**, and backed by the physical device's disk cache (`vk_pipeline_cache.c:44-51,
  368-388, 442-452`).
- The disk cache (`nvk_physical_device.c:1466-1474`) is enabled when Mesa is built with `ENABLE_SHADER_CACHE`. The
  meson `shader-cache` option is allowed on everything except Windows (`meson.build:1245-1253`). Whether the shipped
  ICD was built with it is **not verified** (see "Measure").
  - Key: `nvk_<chipset>` + `driver_build_sha` + compiler flags. On macOS the patch derives `driver_build_sha` from
    the ICD's **Mach-O LC_UUID** (`nvk/nvk-macos.patch:4752-4780`), so **every NVK rebuild invalidates it**.
  - Folder: `$MESA_SHADER_CACHE_DIR` → `$XDG_CACHE_HOME` → `$HOME/.cache` → `pw_dir/.cache`
    (`disk_cache_os.c:880-983`). If HOME is not writable (WindowServer), the plugin sets
    `MESA_SHADER_CACHE_DIR=<DARWIN_USER_CACHE_DIR>nvmtl-mesa` (`plugin/nvmtl_vk.c:692-704`). A sandboxed app's HOME
    is its container, so that cache is per app.
  - Puts are **asynchronous** on Mesa's `disk$` util_queue (`disk_cache.c:85-93`). **Gets are synchronous** on the
    pipeline-creating thread.
- On a miss, `vk_pipeline_precompile_shader` (`vk_pipeline.c:906-979`: spirv_to_nir + `nak_preprocess_nir`) and the
  NAK backend (`nak_compile_shader`) run **on the calling thread**. #370 caught exactly this:
  `vk_common_CreateGraphicsPipelines → nak_preprocess_nir / nak_compile_shader`, 36 of 353 samples.

## 2. Cache layers

| Layer | Where | Key | Scope | Invalidated by |
|---|---|---|---|---|
| Translator tag | memory | SHA-256 of translator dylib | process | any translator rebuild (cold for every `.spv`) |
| `lk1-*.bin` library key memo | AIR cache dir | path hash; checks stat + 64 KiB edges | per cache dir | file change (macOS update replaces framework metallibs) |
| `idx2-*.plist` library index | AIR cache dir | library SHA-256 | per cache dir | library bytes |
| `*.ll` / `*.u2.ll` AIR text | AIR cache dir | SHA-256(AIR blob) | per cache dir | AIR bytes only (survives driver updates) |
| Library index LRU (16 / 128 MiB) | memory | library SHA-256 | process | process exit |
| `_compiledFns` | memory | function name | one MTLLibrary object | object freed |
| `nvmtl_memo` NSCache (256 / 96 MiB) | memory | `.spv` file name | process | process exit, memory pressure, count limit |
| `.spv` (entry), `fc1`, `refl1`, `variant1` | spvcache dir | SHA-256(AIR[+JSON]) + kind + **translator tag** | per cache dir | translator rebuild; stale sweep then **deletes** them (`:312-343, 362-369`); trim at 2 GiB → 80 % (`:199-268`) |
| `g_sampvar` / `_samplerVariants` | memory | descriptor + shaders + samplers | process / pipeline | process exit; cleared at 1024 |
| NVK `mem_cache` | memory | BLAKE3 of shader state | process | process exit |
| Mesa disk cache | `~/.cache/mesa_shader_cache` or `…/nvmtl-mesa` | chipset + **ICD LC_UUID** + flags | per HOME | NVK rebuild |

How the cache folder is picked (`nvmtl_aircache_dir`, `:152-174`; `nvmtl_spvcache_dir`, `:344-353`):

1. `/Library/GPUBundles/nvmtl/aircache`, if the process can write it (root only).
2. Otherwise `NSCachesDirectory/nvmtl/aircache`, i.e. `~/Library/Caches`. Non-sandboxed apps of one user share it;
   each sandboxed app gets its own container.
3. Otherwise `DARWIN_USER_CACHE_DIR/nvmtl/aircache`.
4. Otherwise `NSTemporaryDirectory()`.

spvcache goes beside the AIR cache, or into `NSTemporaryDirectory()/nvmtl/spvcache` if that is not writable. The
temporary-folder fallback was added for sandboxed agents such as iconservicesagent (`:293-302`,
`tools/test_spvcache_dir.py`). In #370, WindowServer's cache was
`/private/var/folders/zz/…/C/WindowServer/nvmtl/spvcache`. **Nothing is shared between WindowServer, system agents
and sandboxed apps.** Each of them translates and NAK-compiles the same CoreAnimation, CoreImage and CoreUI shaders
on its own.

## 3. Blocking I/O on the caller's thread

All of these are synchronous on whatever thread made the Metal call (for #370, `com.apple.coreanimation.pipelines`):

- whole-dylib read + SHA-256 (once per process), `:52-76`
- metallib read + whole-library SHA-256 unless `lk1` hits; `lk1` write on a miss (`:1117-1122`)
- `idx2` plist read and write (`:1031, 1052`)
- `.ll` read; on a miss, `.ll` atomic write; or `air-opt` spawn + temp files + 10 ms polling (`:445-474, 636-663`)
- `.spv` read on every non-memoized entry call, atomic write on a miss (`:859, 870`)
- `fc1` / `refl1` / `variant1` read on a memo miss, `writeToFile:atomically:YES` on a translate miss
  (`:1257, 1271, 1326, 1345, 1790, 1793`). #370 caught `NSData writeToFile → fsync` here (6 of 353 samples).
- `utimes()` on **every** hit, memo hits included (`:854-862, 1254, 1258, 1328, 1789`): a metadata write per
  `newFunction…` call, even in steady state. #370's warm-cache `fs_usage` showed only `utimes`/`getattrlist` on
  `.spv` files.
- Mesa `disk_cache_get` reads inside `vkCreate*Pipelines` (its writes are async)
- one-time folder probe writes (`nvmtl_dir_writable`, `:296-302`)

Already off-thread: the stale sweep (QoS utility, `:365`) and the trim (QoS background, `:278`).

## 4. Why cold cost keeps coming back

1. **Every login starts with empty memos.** NSCache memo, library LRU, NVK `mem_cache`, `g_sampvar` and
   `_compiledFns` all start empty when WindowServer and every agent start. At best a warm boot is then a stream of
   synchronous disk reads plus `utimes` on the CA pipelines thread. That is cheap per hit but repeated for hundreds
   of shaders. NvGfx#11: "the in-memory memo starts empty every time WindowServer starts".
2. **Any translator rebuild starts every `.spv` cache over.** The tag is the dylib's SHA-256, not a version of what
   the translator outputs. #370: 404 files and about 73 MiB rebuilt after 2.5.3; WindowServer at 62 % of a core over
   146 s with `create_fragment_shader` in 317 of 353 samples. The code comment at `:307-309` records 107 s at 79 % CPU
   on the login after an update. For this fork, **every build that touches the translator** starts over, which
   matters while specs iterate.
3. **Any NVK rebuild starts the NAK cache over** (LC_UUID key).
4. **Per-process folders.** Each sandboxed process, and each process running as a different user (WindowServer
   runs as `_windowserver`), pays the full translate and NAK compile for shaders another process already compiled.
   At login, WindowServer, Dock, Finder, loginwindow, ControlCenter, iconservicesagent, Spotlight and so on start
   together and each starts cold the first time. Settings icons are drawn by IconServices and CoreUI in sandboxed
   agents and extensions, so they wait on that agent's own translations.
5. **Specialization grows the work.** CA asks for many constant-specialized fragment functions. Each distinct
   constant set is a full-module translate (`fc1`, about 584 KB), and the memo holds only about 165 of those.
   Sampler and threadgroup variants add translations and pipeline builds **at draw time**.
6. **macOS updates** replace framework metallibs, which changes `lk1`, `idx2` and `.ll` keys (expected; the same is
   true on a real Mac).
7. **Temporary-folder fallbacks.** Where spvcache lives in `NSTemporaryDirectory()`, it can be purged between boots
   (not verified; see "Measure").

## 5. What a real Mac's driver does

These sources are Apple's own WWDC sessions (session pages and transcripts) and Apple's developer documentation
JSON.

- **GPU code is made at pipeline creation, not at function creation.** WWDC22 10102: "Once your Metal library is in
  memory, creating a Pipeline State Descriptor … is a lightweight operation. Until you create your pipeline state
  object … where just-in-time GPU binary generation takes place." *(high confidence)*
- **Out-of-process compiler, and a cache that is "system-wide".** WWDC20 10615: "apps have benefited from a
  system-wide shader cache that accelerates creating pipeline objects that have been created from previous runs of
  the application", and "If … the pipeline is not found the OS's MTLCompilerService will kick into gear and compile
  my AIR source to machine code, return the result, and cache the result in the Metal Shader Cache." *(high
  confidence on what is said; "system-wide" there means a cache the system keeps, not necessarily one shared across
  apps)*
- **That cache is on disk and grows as pipelines are made.** WWDC22 10102: "When you instantiate a PSO, Metal stores
  your GPU binaries in its file system cache … previously generated binaries that are referenced will be loaded from
  the cache." First launches still pay. WWDC20: "apps … can not benefit from the Metal Shader Cache before it's been
  populated." *(high)*
- **Binary archives** (`MTLBinaryArchive`, "a container for pipeline state descriptors and their associated compiled
  shader code", Apple docs) skip compilation when they hit. `MTLPipelineOptionFailOnBinaryArchiveMiss` turns a miss
  into an error. They need the same GPU and OS build, and "Metal gracefully upgrades your binary archives during OS
  updates … asynchronously, and in the background" (WWDC22). WWDC20 measured a 28× faster pipeline build (1 min 26 s
  → 3 s) on an empty shader cache. *(high)*
- **Concurrent compile threads**: `MTLDevice.shouldMaximizeConcurrentCompilation` and
  `maximumConcurrentCompilationTaskCount` (Apple docs). *(high)*
- **Where the shader cache lives** is not in Apple documentation. Community reports put it at
  `$(getconf DARWIN_USER_CACHE_DIR)/com.apple.metal/…`, keyed per app or bundle ID. That makes it per user and per
  app, like this driver's, so "shared across processes" should not be assumed. *(low-medium confidence: secondary
  sources only)*
- **What differs from this driver:**
  - Function creation and specialization are cheap on Apple. Compilation happens in `MTLCompilerService`, which can
    run in parallel and doesn't hold the caller's locks.
  - The cache key follows the OS and compiler build, not a hash of a dylib rebuilt by every driver build.
  - Apple keeps its own frameworks' shaders warm across OS updates (archives are upgraded in the background).
  - Nothing is translated at draw time.

## 6. Candidate levers (not designed here)

1. **Shared, persistent cache.** One cache folder all processes can read (and a broker or root-owned writer), so
   WindowServer, agents and sandboxed apps reuse each other's SPIR-V and NAK binaries.
2. **Stable key.** Key the SPIR-V caches on a translator output-format version instead of the dylib SHA-256, with an
   escape hatch, so a plugin-only or no-op translator rebuild keeps the cache (#370 suggests this).
3. **Pre-warm.** After a driver install, or at boot before login, translate and compile the known WindowServer, CA,
   CoreImage, CoreUI and IconServices libraries and constant sets in the background. Or ship a prebuilt cache for
   TU106 (only this card matters).
4. **Off-thread I/O.** Move cache writes and `utimes` off the caller (NvGfx `cache-write-async`). Drop `utimes` on
   memo hits.
5. **Bigger or keyed memo.** Raise the memo for WindowServer (fc1 entries of about 584 KB overflow 96 MiB), or keep
   it in a form that survives a restart (mmap'd pack file instead of one file per entry).
6. **Move translation off the waiting thread.** Make `newFunction…completionHandler:` really async, translate and
   NAK-compile ahead of use, and stop doing sampler and threadgroup variants at draw time (or warm them at pipeline
   creation).
7. **Pass a real VkPipelineCache.** Pass a VkPipelineCache shared across processes (`vkGetPipelineCacheData` into a
   shared file), or confirm Mesa's disk cache is on and point it at a shared folder.
8. **Check air-opt never runs.** Confirm the out-of-process `air-opt` fallback never runs on Tahoe (in-process
   reader present).

## 7. What needs measuring on Tahoe (RTX 2060)

- **Is the Mesa disk cache on?** Look for files under `…/nvmtl-mesa` and `~/.cache/mesa_shader_cache`, and run
  `strings` on the ICD for `ENABLE_SHADER_CACHE` behaviour. Does `nak_compile_shader` still show in a warm-boot
  spindump?
- **Login cost, cold vs warm.** A WindowServer spindump at +30 / +75 / +240 s after login on three boots:
  - after wiping the spvcache, AIR cache and Mesa caches;
  - on an unchanged second boot;
  - after rebuilding only the plugin.

  Split samples into translate / NAK / `fsync` / `utimes` / read.
- **Counters per process** for the first 5 min after login: `gSpvHit/Miss`, `gFcHit/Miss/Stored`, `gRfHit/Miss`,
  `gAirHit/Miss`, `gLkHit/Miss`, plus memo evictions. The log lines already exist (`fc cache:`, `refl cache:`,
  `library index:`, `library key memo:`).
- **Who translates at login, and where their caches are.** Grep the nvlog for `spvcache: … caching in`. Count
  per-process duplicates of the same `fc1` hash.
- **Cache sizes after a normal session**: file count, MiB, `fc1` sizes against the 96 MiB / 256-entry memo.
- **Do temporary-folder caches survive a reboot?** Check sandboxed agents and System Settings extensions.
- **Draw-time variant builds**: count `pixel sampler variant built` and `variant cache: miss` during login and while
  opening System Settings.
- **Does CA's render thread actually wait on `com.apple.coreanimation.pipelines`?** That decides whether
  translation time shows up as a hitch or only as a late first frame.
- **Translator dylib size and the one-time hash cost per process.**
- **App launch**: time to first frame for Safari, Photos and System Settings, cold vs warm, against stock.

## Sources

- Code: `plugin/NVMTLLibraryLoad.m`, `plugin/NVMTLObjects.m`, `plugin/NVMTLDevice.m`, `plugin/nvmtl_vk.c`,
  `plugin/NVMTLVendorCompiler.m`, `plugin/NVMTLSass.m`, `translator/wrapper/src/lib.rs`, `nvk/nvk-macos.patch`,
  `tools/test_spvcache_dir.py`, `tools/bench_pipeline_build.m`.
- Mesa 17ca6174: `src/vulkan/runtime/vk_pipeline.c`, `vk_pipeline_cache.c`, `src/nouveau/vulkan/nvk_device.c`,
  `nvk_physical_device.c`, `nvk_instance.c`, `src/util/disk_cache.c`, `disk_cache_os.c`, `meson.build`
  (https://gitlab.freedesktop.org/mesa/mesa/-/tree/17ca6174).
- nullmoth/nvidia-macos-driver#370 (report plus the cold-vs-warm follow-up); watchthelight-labs/NvGfx#11.
- Apple: WWDC20 10615 "Build GPU binaries with Metal" (https://developer.apple.com/videos/play/wwdc2020/10615/);
  WWDC22 10102 "Target and optimize GPU binaries with Metal 3"
  (https://developer.apple.com/videos/play/wwdc2022/10102/); WWDC21 10229 "Discover compilation workflows in Metal"
  (https://developer.apple.com/videos/play/wwdc2021/10229/); Apple docs `MTLBinaryArchive`,
  `MTLPipelineOption.failOnBinaryArchiveMiss`, `MTLDevice.shouldMaximizeConcurrentCompilation`,
  `maximumConcurrentCompilationTaskCount` (developer.apple.com/documentation/metal).
- Shader cache location (secondary, low confidence): community reports of `DARWIN_USER_CACHE_DIR/com.apple.metal`,
  e.g. https://www.ctrl.blog/entry/darwin-user-cache-gigabytes.html.
