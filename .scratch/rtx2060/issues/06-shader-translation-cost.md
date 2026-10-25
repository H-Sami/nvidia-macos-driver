# Shader translation and pipeline cost

Type: research
Status: open
Blocked by:

## Question

Where, on which thread and how often does a Metal shader on this driver get translated (AIR → SPIR-V) and compiled
(NAK)? What is cached in memory and on disk, per process or shared? And why would that make login, app launches and
System Settings icons slow?

Upstream #370 shows WindowServer's Core Animation pipeline thread inside `nvmtl_translate_with_fc_cached` and
`nak_compile_shader`, with an `fsync` per cache write on that thread, and an in-memory memo that starts empty each
launch. The answer should cover the plugin's library-load path, the translator cache, NVK's pipeline cache, and what
a real Mac's driver does instead (Apple caches compiled shaders system-wide).
