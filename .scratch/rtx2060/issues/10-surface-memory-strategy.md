# Choose the surface-memory strategy for a 256 MB BAR1

Type: grilling
Status: open
Blocked by: 02

## Question

Which surfaces get BAR1 at all, for how long, and how does everything else reach the compositor without the copy
path? Pick one strategy, with its acceptance target (zero surface refusals in normal use, no copy-path frames).

Candidates from [How BAR1 is spent on a 256 MB card](05-how-bar1-is-spent.md) and
[Survey community fixes](04-community-fixes-survey.md): Dora-z's unmapped VRAM grants (plus the larger NVENC margin
and WindowServer read marks); mapping on demand; unmapping parked surfaces; exempting only the composited frame;
dropping the scanout mapping while flips are zero-copy; asking the GPU firmware for the real free and largest-free
BAR1. Also decide how much BAR1 to reserve for the codec libraries ([The Turing video path on Tahoe](09-turing-video-path.md)).

Settle with the baseline numbers: refusals from the budget versus fragmentation, the card's offered BAR sizes (if it
really offers more than 256 MB, this ticket changes shape), and whether Dora-z's unzeroed VRAM is acceptable.
