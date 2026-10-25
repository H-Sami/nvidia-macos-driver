# Shader translation and pipeline cost

Type: research
Status: resolved
Blocked by:

## Question

Where, on which thread and how often does a Metal shader on this driver get translated (AIR → SPIR-V) and compiled
(NAK)? What is cached in memory and on disk, per process or shared? And why would that make login, app launches and
System Settings icons slow?

Upstream #370 shows WindowServer's Core Animation pipeline thread inside `nvmtl_translate_with_fc_cached` and
`nak_compile_shader`, with an `fsync` per cache write on that thread, and an in-memory memo that starts empty each
launch. The answer should cover the plugin's library-load path, the translator cache, NVK's pipeline cache, and what
a real Mac's driver does instead (Apple caches compiled shaders system-wide).

## Answer

Translation and NAK compilation both run on whichever thread made the Metal call, and every cache is per process or
per cache folder. So WindowServer, the system agents and each sandboxed app all pay separately, and pay again after
any translator or NVK rebuild. Apple compiles once, at pipeline creation, in `MTLCompilerService`, with an on-disk
cache. (Code reading; nothing measured on Tahoe.)

- Translation (AIR → SPIR-V) runs inside `newFunctionWithName:`, once per distinct constant-value set (a whole-module
  translate each time, about 584 KB per entry), and at draw time for sampler variants (`NVMTLObjects.m:2728-2774`,
  `4306+`). The `completionHandler:` variants just call the blocking ones.
- NAK compiles in `vkCreateGraphicsPipelines(VK_NULL_HANDLE)` (`nvmtl_vk.c:4308`): NVK's in-memory cache starts empty in
  every process; whether the shipped NVK has Mesa's disk cache on is unconfirmed.
- Cache keys: the SPIR-V cache key includes a SHA-256 of the translator library and the NVK disk cache key is NVK's
  build ID, so any rebuild throws everything away (and a sweep deletes it). Only the AIR text cache survives.
- Cache folders are per user and per sandbox; nothing is shared across WindowServer, iconservicesagent and apps.
- Blocking I/O on the caller thread: each cache write (`writeToFile:atomically:`, fsync), each read, a `utimes` on
  every hit, hashing the translator library once per process, hashing and indexing each library.
- The in-memory memo holds 256 entries / 96 MiB, about 165 full-module entries, against 404 seen in one WindowServer
  cache (#370).
- Candidate levers: a cross-process cache; a key based on the translator's output version; pre-warming system shaders
  at install or boot; moving writes and `utimes` off the calling thread; a larger, persistent memo; truly async
  function creation and no draw-time variant builds; a real shared Vulkan pipeline cache.
- To measure on Tahoe: whether the Mesa disk cache is on; WindowServer spindumps at +30/+75/+240 s after login (wiped
  cache, unchanged, plugin-only rebuild); per-process hit/miss and cache folder; whether temp-folder caches survive a
  reboot; draw-time sampler-variant counts at login and in System Settings; whether Core Animation's render thread
  waits on its pipelines thread; app first-frame times compared with stock.

Findings: branch `research/shader-cost`, file `research/shader-cost.md`.
