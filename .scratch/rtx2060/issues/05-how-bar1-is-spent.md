# How BAR1 is spent on a 256 MB card

Type: research
Status: open
Blocked by:

## Question

On a card whose 256 MB BAR1 is smaller than its 6 GB of VRAM, what takes BAR1 space, for how long, and what happens
to a surface that is refused? Follow it from NVRM's placement of BAR1, through NVRMFB's surface budget, grants and
kernel mappings, and NVAccel's `NVVidMemory` wire/unwire, to the plugin's "family VRAM import refused - private image
+ copies" fallback and NVK's `LOCAL+mapped memory -> system RAM` choice.

The answer should say which of these spend BAR1 because the CPU must touch the memory and which only because of how
the code is arranged, what the copy path costs per frame at 2560×1440, and what Apple's IOAccelerator model actually
requires to be CPU-visible. Upstream #399, #169 and #92 have measurements from 256 MB cards.
