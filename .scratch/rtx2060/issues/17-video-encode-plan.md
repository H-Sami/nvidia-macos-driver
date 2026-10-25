# Choose the video encode plan

Type: grilling
Status: open
Blocked by: 02

## Question

What does hardware H.264 and HEVC encode need so OBS, HandBrake, FaceTime and Screen Sharing all use it: more than
one encoder session per process (#206), B-frames, HEVC 10-bit, a route for sandboxed clients like the decoders'
`VTDecoderXPCService` hook, and the H.264 keyframe flag issue (#388)?

Inputs: [The Turing video path on Tahoe](09-turing-video-path.md) and the baseline's record of which encoders each
client picked. Decide which of these are in the spec and the acceptance target per client.
