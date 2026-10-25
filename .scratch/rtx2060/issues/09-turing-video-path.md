# The Turing video path on Tahoe

Type: research
Status: open
Blocked by:

## Question

How do hardware video decode and encode reach VideoToolbox on this driver for a Turing card, and what is known to
break them on Tahoe? Cover where the decoder and encoder libraries come from (they are not in the source tree), how
they are registered and picked per generation, how sandboxed apps (Safari, QuickTime) are served, and why the
copy-engine queue fails on a Turing card (`VkResult -13`, upstream #231).

The answer should also say which codecs Turing's NVDEC and NVENC support that macOS can use (H.264, HEVC, HEVC Main10,
VP9), which are wired up today, and what replacing or extending the prebuilt libraries would involve.
