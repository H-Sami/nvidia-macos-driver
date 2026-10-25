# Choose the shader warm-up strategy

Type: grilling
Status: open
Blocked by: 02

## Question

How should translated and compiled shaders be cached and produced so login, app launches and System Settings icons
stop waiting on them, and what is the acceptance target (first-frame and launch times against the stock baseline)?

Candidates from [Shader translation and pipeline cost](06-shader-translation-cost.md) and
[Survey community fixes](04-community-fixes-survey.md): a cache shared across processes; a key based on the
translator's output version instead of its binary hash; pre-warming system shaders at install or boot; cache writes
and `utimes` off the calling thread (NvGfx `cache-write-async`, `2b41c23`); a larger persistent memo; truly async
function creation and no draw-time variant builds; a real shared Vulkan pipeline cache with Mesa's disk cache on
(#399 part 3); the FxHash translator speed-up (PR #187). Settle with the baseline's cold/warm launch times, spindumps
after login, and whether Mesa's disk cache is on.
