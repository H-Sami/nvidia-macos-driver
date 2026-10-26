# Build the fork from source on Tahoe

Type: task
Status: open
Assignee: H-Sami
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

## Progress

2026-10-26, claimed on Tahoe (macOS 26.7.1, x86_64). Findings before any build:

- **Toolchain on the machine**: Command Line Tools only (Apple clang 21, SDKs 15.4, 26.5, with `Kernel.framework`
  headers). No Xcode, Homebrew, Rust, Meson, Ninja, pkg-config or glslang. Python 3 is `/usr/bin/python3`.
- **NVRM can't be built from this repo.** Its sources are here, but the link needs an RM (`libnvkernel.a`) and NVKMS
  (`libnvkms.a`) built for `Darwin_x86_64` from `open-gpu-kernel-modules`, with a `compile_cmds.sh` that `rmcc.py`
  and `build-completion-archive.py` read. The recipe that makes them (`build-nvrm.sh`) was never published, in any
  branch or tag. The loaded 2.5.5 NVRM is 14 MB; every other kext is small.
- **NVRMFB has no build script** but depends on no other NullMoth kext (loaded with IOKit dependencies only), so it
  should build from `kexts/NVRM/fb/` against the OGKM headers, as NVAccel does.
- Buildable from the repo as published: translator, plugin, NVK (Mesa `17ca6174` + patch), NVAccel 15/26, NVRMAGDC,
  NMDRM, NMHDA, NVPrimarySelector.
- **Installing a local build overwrites stock 2.5.5**, so it has to wait until the stock baseline runs are finished.
- **Decided with the owner**: NVRM is copied from the 2.5.5 release; everything else is built here. Making NVRM
  buildable becomes its own ticket, wanted only once a spec needs an NVRM change.
- The stock baseline is captured, so installing a local build no longer puts it at risk.
- **Built, 2026-10-26** (`build/rtx2060/build.sh all`, commit `b21636b`): everything but NVRM builds with Command Line
  Tools (Apple clang 21, SDK 26.5); no Xcode needed. Against the 2.5.5 release:
  - NVAccel 15 and 26, and NVRMFB: **byte-identical**. NVRMFB has no script upstream; it is `kexts/NVRMFB/fb`
    with NVAccel's flags (`kexts/NVRM/fb` is an older copy). RM's `-D` flags come from NVIDIA's Makefile run on
    Darwin, written to the `compile_cmds.sh` that `accel_build.sh` reads.
  - NVRMAGDC: same instructions and section sizes; only the newer `ld` places `__got` elsewhere.
  - Translator and plugin: same exports and linked libraries.
  - NVK: same libraries and C exports, except the RTX 50-only direct SASS entry points (`dispatch_sass_v2/v3`,
    `sass_*_handle_v1`). The published `nvk-macos.patch` lacks them, but the plugin turns direct SASS off on any card
    that isn't an RTX 50 before it looks for them, so this card takes the same path. NVK is built on the 610.57.04 RM
    headers (`~/ogkm610` in the source; 615 dropped the Turing class headers it uses). The patch also needs
    `build/rtx2060/nvk-cl-push-warning.patch`: it puts an `fprintf` into `nv_push.h`, which the OpenCL kernels
    include, so `mesa_clc` fails. Upstream's persistent build folder probably never rebuilt `nvkcl.spv`.
  - Toolchain, all in `~/rtx2060-build`, no sudo: rustup stable 1.99.1, bindgen 0.73.2, cbindgen 0.29.4,
    conda-forge (micromamba) Python 3.12 + Meson 1.12.1, and LLVM/clang/libclc/llvm-spirv 22 to build `mesa_clc`
    (NVK needs it), glslang 16.6.0.
