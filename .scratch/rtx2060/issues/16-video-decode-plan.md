# Choose the video decode plan

Type: grilling
Status: open
Blocked by: 02

## Question

What does it take for 4K60 H.264 and HEVC (and VP9, if kept in scope) to play in Safari and QuickTime on hardware
with no dropped frames: keep NullMoth's prebuilt decoders, adopt mickys' decoders, or replace them; and which fixes
come with it?

Candidates from [The Turing video path on Tahoe](09-turing-video-path.md): test mickys' decoders on TU106 and load
them in `VTDecoderXPCService`; register a VP9 decoder; move untiling off the CPU; fix the first-lookup race (#175);
reserve BAR1 for the codecs; pass the copy-engine parameters or skip the copy-only queue on TU106. Settle with the
baseline's playback numbers, the codec YouTube serves Safari, and whether HEVC Main10 output is correct on Turing.
Decide whether VP9 stays in the 10/10 list.
