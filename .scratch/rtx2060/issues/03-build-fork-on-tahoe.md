# Build the fork from source on Tahoe

Type: task
Status: open
Blocked by:

## Question

Can every shipped component (translator, plugin, NVK, the kexts, NVAccel for Tahoe) be built from `rtx2060` on the
Tahoe install, installed, and booted, with the result behaving like stock 2.5.5?

The build scripts in `build/` assume the maintainer's own layout (`~/nvmtl-build/LIVE/...`, a build lock, Xcode 16)
and need NVIDIA's `open-gpu-kernel-modules` at `615.78.08` and Mesa `17ca6174` with `nvk/nvk-macos.patch`. Pieces not
built from this repo (the video codec libraries, `NVIDIAShared.bundle`, GSP firmware) come from the release tarball.

Done when the answer records: the toolchain versions that worked; a build script for this machine committed to
`rtx2060`; which installed files are built here and which are copied from the 2.5.5 release; how to install a local
build and how to get back to stock; and one boot of the local build with Metal 3 reported. Driven by Claude Code on
Tahoe; the owner reboots.
