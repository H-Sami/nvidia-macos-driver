#!/bin/bash
# build.sh [setup|build|package|all]: build the rtx2060 fork on this Tahoe machine (RTX 2060, x86_64, Command Line
# Tools only) and package it as an installable pkgroot. Everything lives in $W (default ~/rtx2060-build); nothing
# needs sudo until the install itself.
#
#   setup    toolchains and sources: rustup (stable), bindgen, cbindgen, a conda-forge env with Python 3.12 + Meson +
#            Ninja + Mako, another with LLVM/clang/libclc/SPIR-V 22 for mesa_clc, glslang, Mesa 17ca6174 with
#            nvk/nvk-macos.patch, open-gpu-kernel-modules 615.78.08 (kexts) and 610.57.04 (NVK), the 2.5.5 release.
#   build    translator, plugin (release), NVK, NVAccel 15/26, NVRMFB, NVRMAGDC from this tree's HEAD.
#   package  $W/pkg/pkgroot: the 2.5.5 release with the built files swapped in, re-signed, SHA256SUMS redone.
#            NVRM, the codec libraries, NVIDIAShared, the Vulkan loader, air-opt/air-runtime and the GSP firmware
#            stay the release's: NVRM's RM and NVKMS archives have no published build.
#
# Install:      cd $W/pkg/pkgroot && sudo ./install.sh && sudo shutdown -r now
# Back to stock: cd $W/release/x/pkgroot && sudo ./install.sh && sudo shutdown -r now
#               (or the OpenCore picker's "start once without NVIDIA driver", then the same)
set -euo pipefail
W=${W:-$HOME/rtx2060-build}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MESA_SHA=17ca6174dcc6cb22059ac343bc29f8af7800f42e
REL=https://github.com/nullmoth/nvidia-macos-driver/releases/download/v2.5.5
REL_SHA=3889abbe5073cda1f0a0d22e1d89f2c98157c12190708983bfa841f121089ef1
MM="$W/mamba/bin/micromamba"; export MAMBA_ROOT_PREFIX=$W/mamba/root
env_nvk() {
  export PATH=$W/hostbin:$W/glslang/bin:$W/pyenv/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin
  export LIBCLANG_PATH=/Library/Developer/CommandLineTools/usr/lib
}
say() { echo "== $*"; }

setup() {
  mkdir -p "$W" && cd "$W"
  [ -x "$HOME/.cargo/bin/cargo" ] || { curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path; }
  "$HOME/.cargo/bin/rustup" component add rustfmt
  [ -x "$HOME/.cargo/bin/bindgen" ] || "$HOME/.cargo/bin/cargo" install --locked bindgen-cli
  [ -x "$HOME/.cargo/bin/cbindgen" ] || "$HOME/.cargo/bin/cargo" install --locked cbindgen
  [ -x "$MM" ] || { mkdir -p mamba && curl -sSL https://micro.mamba.pm/api/micromamba/osx-64/latest | tar xj -C mamba bin/micromamba; }
  [ -d pyenv ] || "$MM" create -y -q -p "$W/pyenv" -c conda-forge python=3.12 meson ninja mako pyyaml packaging
  [ -d clcenv ] || "$MM" create -y -q -p "$W/clcenv" -c conda-forge llvmdev=22 clangdev=22 libclang-cpp=22 libclc=22 \
    llvm-spirv=22 libllvmspirv=22 pkg-config zlib zstd
  [ -x glslang/bin/glslangValidator ] || { mkdir -p glslang && curl -sSL https://github.com/KhronosGroup/glslang/releases/download/16.6.0/glslang-16.6.0-macos-universal-release.tar.gz | tar xz -C glslang; }
  [ -d ogkm ] || git clone -q --depth 1 --branch 615.78.08 https://github.com/NVIDIA/open-gpu-kernel-modules.git ogkm
  [ -d ogkm610 ] || git clone -q --depth 1 --branch 610.57.04 https://github.com/NVIDIA/open-gpu-kernel-modules.git ogkm610
  if [ ! -d mesa-src ]; then
    rm -rf mesa && mkdir mesa && git -C mesa init -q && git -C mesa fetch -q --depth 1 https://gitlab.freedesktop.org/mesa/mesa.git $MESA_SHA
    # no .git in the build tree: Mesa would stamp git-<sha> into the binary
    mkdir mesa-src && git -C mesa archive FETCH_HEAD | tar x -C mesa-src
    (cd mesa-src && patch -p1 --batch --forward -s < "$REPO/nvk/nvk-macos.patch" && patch -p1 --batch --forward -s < "$REPO/build/rtx2060/nvk-cl-push-warning.patch")
    # NVK's NVRM backend reads RM headers from here; it was built on 610's, which still carry the Turing classes
    ln -sfn "$W/ogkm610" mesa-src/src/nouveau/vulkan/nvkmd/nvrm/open-gpu-kernel-modules
  fi
  if [ ! -x hostbin/mesa_clc ]; then
    say "mesa_clc (host tool, against conda LLVM 22)"
    ( env_nvk; export PATH=$PATH:$W/clcenv/bin PKG_CONFIG=$W/clcenv/bin/pkg-config CC=/usr/bin/clang CXX=/usr/bin/clang++
      export PKG_CONFIG_PATH=$W/clcenv/lib/pkgconfig:$W/clcenv/share/pkgconfig
      printf "[binaries]\nllvm-config = '%s'\n" "$W/clcenv/bin/llvm-config" > clc-native.ini
      meson setup --wipe build-clc mesa-src --native-file clc-native.ini -Dbuildtype=release -Db_ndebug=true -Dvulkan-drivers= \
        -Dgallium-drivers= -Dplatforms= -Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dllvm=enabled -Dshared-llvm=enabled -Degl=disabled \
        -Dglx=disabled -Dglvnd=disabled -Dshared-glapi=disabled -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dexpat=disabled \
        -Dzstd=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dgallium-rusticl=false -Dspirv-tools=enabled > clc-setup.log
      ninja -C build-clc src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 > clc-ninja.log )
    mkdir -p hostbin && cp build-clc/src/compiler/clc/mesa_clc build-clc/src/compiler/spirv/vtn_bindgen2 hostbin/
  fi
  # RM's -D flags as NVIDIA's own Makefile sets them on Darwin; accel_build.sh reads them from compile_cmds.sh
  local NV=ogkm/src/nvidia P; P=$(mktemp); printf 'print-%%:\n\t@echo $($*)\n' > "$P"
  mkdir -p $NV/_out/Darwin_x86_64
  echo "clang $(make -s -C $NV -f Makefile -f "$P" print-CFLAGS 2>/dev/null | tail -1 | tr ' ' '\n' | grep -E '^-D' | sort -u \
    | sed 's/^-DMBEDTLS_USER_CONFIG_FILE=.*$/-DMBEDTLS_USER_CONFIG_FILE="<nvrm_mbedtls_config.h>"/' | tr '\n' ' ') -c arch/nvalloc/unix/src/osapi.c" \
    > $NV/_out/Darwin_x86_64/compile_cmds.sh; rm -f "$P"
  if [ ! -d release/x/pkgroot ]; then
    mkdir -p release && curl -sSL -o release/nullmoth-nvidia-2.5.5.tar.gz $REL/nullmoth-nvidia-2.5.5.tar.gz
    echo "$REL_SHA  release/nullmoth-nvidia-2.5.5.tar.gz" | shasum -a 256 -c --quiet
    mkdir -p release/x && tar xzf release/nullmoth-nvidia-2.5.5.tar.gz -C release/x
  fi
  say "setup done in $W"
}

build() {
  cd "$W"; [ -d mesa-src ] && [ -x hostbin/mesa_clc ] || { echo "STOP: run setup first"; exit 2; }
  local C; C=$(git -C "$REPO" rev-parse --short HEAD)
  rm -rf src out && mkdir -p src out/plugin out/nvk && git -C "$REPO" archive HEAD | tar x -C src
  say "translator"
  ( cd src/translator && RUSTFLAGS="--remap-path-prefix=$W/src/translator=/src --remap-path-prefix=$HOME=/build" \
      "$HOME/.cargo/bin/cargo" build -q --release --manifest-path wrapper/Cargo.toml --target-dir target ) > out/xlate.log 2>&1 \
    || { tail -20 out/xlate.log; exit 4; }
  cp src/translator/target/release/libnvmtl_translate.dylib out/ && strip -S out/libnvmtl_translate.dylib
  install_name_tool -id @rpath/libnvmtl_translate.dylib out/libnvmtl_translate.dylib
  say "plugin (release)"
  ( cd src/plugin && xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 -Wno-protocol \
      -Wno-incomplete-implementation -Werror=unguarded-availability-new -I"$W/mesa-src/include" -o "$W/out/plugin/NVMTLDriver" \
      NVMTLDevice.m -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation ) \
    2> out/plugin/build.err || { grep -A2 ': error:' out/plugin/build.err | head -20; exit 5; }
  say "NVK"
  ( env_nvk
    [ -f build-nvk/build.ninja ] || meson setup build-nvk mesa-src -Dbuildtype=release -Db_ndebug=true -Dvulkan-drivers=nouveau \
      -Dgallium-drivers= -Dplatforms= -Degl=disabled -Dglx=disabled -Dglvnd=disabled -Dllvm=disabled -Dmesa-clc=system \
      -Dshared-glapi=disabled -Dvulkan-layers= -Dtools= -Dbuild-tests=false -Dexpat=disabled -Dzstd=disabled -Dlibunwind=disabled \
      -Dlmsensors=disabled -Dvalgrind=disabled -Dxlib-lease=disabled -Dgallium-rusticl=false -Dspirv-tools=disabled > out/nvk-setup.log
    meson configure build-nvk "-Dc_args=-ffile-prefix-map=$W/mesa-src=/src -ffile-prefix-map=$HOME=/build" \
      "-Dcpp_args=-ffile-prefix-map=$W/mesa-src=/src -ffile-prefix-map=$HOME=/build" \
      "-Drust_args=--remap-path-prefix=$W/mesa-src=/src --remap-path-prefix=$HOME=/build" > /dev/null
    nice ninja -C build-nvk src/nouveau/vulkan/libvulkan_nouveau.dylib > out/nvk-ninja.log 2>&1 ) || { grep -A6 '^FAILED' out/nvk-ninja.log | head -30; exit 6; }
  local U; U=$(nm -m build-nvk/src/nouveau/vulkan/libvulkan_nouveau.dylib | grep '(undefined)' | grep -v weak | grep 'dynamically looked up' || true)
  [ -z "$U" ] || { echo "STOP: unresolved strong references (dlopen fails in WindowServer):"; echo "$U"; exit 6; }
  cp build-nvk/src/nouveau/vulkan/libvulkan_nouveau.dylib out/nvk/ && strip -S out/nvk/libvulkan_nouveau.dylib
  say "NVAccel 15 and 26"
  OGKM=$W/ogkm bash src/build/accel_build_all.sh src/kexts/NVRM out/kexts
  say "NVRMFB"   # no script upstream; NVAccel's flags give the 2.5.5 binary byte for byte
  ( OGKM=$W/ogkm SRC=src/kexts/NVRMFB OUT=out/kexts/fb; mkdir -p $OUT/NVRMFB.kext/Contents/MacOS
    eval "$(sed -n '/^SDK=/,/^  -Wall/p' src/build/accel_build.sh)"
    xcrun clang++ "${CFLAGS[@]}" -I"$SRC/fb" -c "$SRC/fb/nvrm-fb.cpp" -o $OUT/fb.o 2> $OUT/fb.err || { grep error $OUT/fb.err | head; exit 7; }
    xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext $OUT/fb.o -o $OUT/NVRMFB.kext/Contents/MacOS/NVRMFB
    cp "$SRC/fb/Info.plist" $OUT/NVRMFB.kext/Contents/Info.plist )
  say "NVRMAGDC"   # build_agdc.sh's flags on the repo's tree
  ( D=src/kexts/NVRMAGDC OUT=out/kexts/agdc; mkdir -p $OUT/NVRMAGDC.kext/Contents/MacOS
    KHDR="$(xcrun --show-sdk-path)/System/Library/Frameworks/Kernel.framework/Headers"
    xcrun clang++ -arch x86_64 -fapple-kext -mkernel -nostdinc -I"$KHDR" -I"$D" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
      -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override \
      -Wno-unused-function -O2 -c $D/nvrm-agdc.cpp -o $OUT/k1.o 2> $OUT/cc.err || { grep error $OUT/cc.err | head; exit 8; }
    xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext -lkmodc++ -lkmod -lcc_kext $OUT/k1.o -o $OUT/NVRMAGDC.kext/Contents/MacOS/NVRMAGDC
    cp $D/Info.plist $OUT/NVRMAGDC.kext/Contents/Info.plist )
  echo "$C" > out/COMMIT
  say "built $C into $W/out"
}

package() {
  cd "$W"; [ -f out/COMMIT ] || { echo "STOP: run build first"; exit 2; }
  local P=$W/pkg/pkgroot L GB EX; rm -rf pkg && mkdir pkg && ditto release/x/pkgroot "$P"
  L=$P/Library; GB=$L/GPUBundles; EX=$L/Extensions
  local M=$GB/NVMTLDriver.bundle/Contents/MacOS
  cp out/plugin/NVMTLDriver "$M/NVMTLDriver"
  cp out/libnvmtl_translate.dylib "$M/libnvmtl_translate.dylib" && codesign -f -s - "$M/libnvmtl_translate.dylib" 2>/dev/null
  codesign -f -s - "$GB/NVMTLDriver.bundle" 2>/dev/null
  cp out/nvk/libvulkan_nouveau.dylib "$GB/nvmtl/libvulkan_nouveau.dylib" && codesign -f -s - "$GB/nvmtl/libvulkan_nouveau.dylib" 2>/dev/null
  rm -f "$GB/nvmtl/libvulkan_nouveau.dylib.syms"   # symbols of the release binary, wrong for this one
  local k
  for k in 15 26; do rm -rf "$L/NullMoth/kexts/$k/NVAccel.kext" && ditto out/kexts/$k/NVAccel.kext "$L/NullMoth/kexts/$k/NVAccel.kext"; done
  rm -rf "$EX/NVAccel.kext" && ditto out/kexts/15/NVAccel.kext "$EX/NVAccel.kext"   # the release puts the 15 build here too
  rm -rf "$EX/NVRMFB.kext" && ditto out/kexts/fb/NVRMFB.kext "$EX/NVRMFB.kext"
  rm -rf "$EX/NVRMAGDC.kext" && ditto out/kexts/agdc/NVRMAGDC.kext "$EX/NVRMAGDC.kext"
  for k in "$EX"/NVAccel.kext "$EX"/NVRMFB.kext "$EX"/NVRMAGDC.kext "$L"/NullMoth/kexts/*/NVAccel.kext; do
    plutil -replace CFBundleVersion -string 2.5.5 "$k/Contents/Info.plist"
    plutil -replace CFBundleShortVersionString -string 2.5.5 "$k/Contents/Info.plist"
  done
  { echo "rtx2060 $(cat out/COMMIT) on v2.5.5, built $(date '+%Y-%m-%d %H:%M') with $(xcrun clang --version | head -1)"
    echo "NVRM, codecs, NVIDIAShared, Vulkan loader, air-runtime and firmware from the 2.5.5 release"; } > "$P/BUILD-INFO"
  ( cd "$P" && grep -v 'libvulkan_nouveau.dylib.syms' MANIFEST.txt > MANIFEST.tmp && mv MANIFEST.tmp MANIFEST.txt
    find . -type f ! -name SHA256SUMS ! -name .DS_Store | sed 's#^\./##' | LC_ALL=C sort | xargs -I{} shasum -a 256 {} > SHA256SUMS
    shasum -a 256 --strict -c SHA256SUMS --quiet )
  say "package $(cat out/COMMIT): $P"
  say "install: cd $P && sudo ./install.sh && sudo shutdown -r now"
}

case "${1:-all}" in
  setup) setup;; build) build;; package) package;;
  all) setup; build; package;;
  *) echo "usage: $0 [setup|build|package|all]"; exit 1;;
esac
