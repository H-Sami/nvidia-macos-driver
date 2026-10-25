# RTX 2060 fork

The vocabulary for making this driver feel native on one RTX 2060 (TU106, 6 GB, 256 MB BAR1) under macOS Tahoe.

## Felt problems

**Hitch**:
A single frame shown late or repeated: a visible freeze in otherwise smooth motion. Measured as a frame gap longer
than two refresh periods.
_Avoid_: stutter, jank, lag spike

**Sluggishness**:
Motion or response that is steadily slower than the display: a low frame rate, input lag, or slow app launches and
icon loads.
_Avoid_: lag, slowness

## Memory

**BAR1**:
The window through which the CPU can see the card's video memory. 256 MB on this card, against 6 GB of VRAM.
_Avoid_: ReBAR window, aperture

**Surface budget**:
The part of BAR1 the driver lets surfaces occupy (about 192 MB of the 256 MB).

**Surface refusal**:
A surface that asked for space in the surface budget and did not get it.
_Avoid_: VRAM refusal, failed allocation

**Copy path**:
How a refused surface still reaches the compositor: its pixels are copied between a private GPU image and CPU memory
on every change.
_Avoid_: fallback path, slow path

**Zero-copy scan-out**:
The display reading the composited surface directly from video memory instead of from a finished copy.
_Avoid_: flip path, iop flip

## Measurement

**Stock baseline**:
The harness results on the unmodified NullMoth 2.5.5 release on this machine; every target is stated against it.
_Avoid_: mainstream driver, reference run

**Harness**:
The one repeatable command on Tahoe that produces every number a spec's acceptance target is stated in.
_Avoid_: benchmark, test script
