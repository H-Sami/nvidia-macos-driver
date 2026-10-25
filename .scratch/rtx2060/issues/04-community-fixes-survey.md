# Survey community fixes

Type: research
Status: open
Blocked by:

## Question

What have others already built or measured that bears on a small-BAR Turing card on 2.5.5, and what is each worth to
us: what it changes, what it measured, whether it is already in 2.5.5, and whether it applies cleanly?

Start from: the `hostpages-2.5.4.diff` in upstream #399; PR #200 (keep a surface's VRAM across page-off) and #178
(host-copy coherence); watchthelight-labs/NvGfx (WindowServer draw path, #356; translator cache, #370); the #324
utilization daemon; other open upstream PRs and forks touching BAR1, the copy path, compositing, shader caching,
video or stats.
