#!/bin/bash
# run.sh [--label NAME] [--only SECTIONS] [--sudo] - the RTX 2060 measurement harness. One command on the Tahoe install
# records the 10/10 list's numbers into ~/rtx2060-runs/<date>-<label>/ and writes summary.md there; nothing is uploaded.
#   --label NAME     names the run folder (stock, fork-abc123, ...); default "run"
#   --only SECTIONS  comma list of state,desktop,launch,video,stats,login; default all but login
#   --sudo           asks for the password once at the start, for spindump, sample and purge; without it they are skipped
# Works against the stock driver. Desktop input needs Accessibility for the app running this (Terminal, iTerm, Claude):
# without it the drag, Dock sweep and scroll scenarios are skipped and the summary says so.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=run; ONLY=state,desktop,launch,video,stats; SUDO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --label) LABEL="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --sudo) SUDO=1; shift ;;
        *) sed -n '2,9p' "$0"; exit 2 ;;
    esac
done
# The harness drives the owner's desktop and launches their apps, so it must run as them; --sudo is how root gets in.
if [ "$(id -u)" = 0 ]; then
    echo "run.sh must not run as root (it drives your desktop and opens your apps as you)."
    echo "Run it as yourself and pass --sudo for the parts that need root:  ./run.sh --label stock --sudo"
    exit 1
fi
want() { case ",$ONLY," in *",$1,"*) return 0 ;; esac; return 1; }

ROOT="$HOME/rtx2060-runs"
RUN="$ROOT/$(date +%Y-%m-%d-%H%M%S)-$LABEL"
BIN="$ROOT/.bin"; CLIPS="$ROOT/.clips"
mkdir -p "$RUN/raw" "$BIN" "$CLIPS"
exec > >(tee -a "$RUN/run.log") 2>&1
say() { echo "[$(date +%H:%M:%S)] $*"; }
say "run folder $RUN"

# --- helpers, rebuilt when their source changes ------------------------------------------------------------------
build() {  # build NAME SOURCE COMMAND...
    local name="$1" src="$2"; shift 2
    local stamp="$BIN/$name.sha"; local sum; sum="$(shasum "$src" | cut -d' ' -f1)"
    if [ ! -x "$BIN/$name" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$sum" ]; then
        say "building $name"
        "$@" || { say "FAILED to build $name"; exit 1; }
        echo "$sum" > "$stamp"
    fi
}
build framegap "$HERE/framegap.c" clang -O2 -o "$BIN/framegap" "$HERE/framegap.c"
for s in drive launch vt; do
    build "$s" "$HERE/$s.swift" swiftc -O -swift-version 5 -suppress-warnings -o "$BIN/$s" "$HERE/$s.swift"
done

if [ $SUDO = 1 ]; then
    sudo -v && { while true; do sudo -n true; sleep 50; kill -0 $$ 2>/dev/null || exit; done & }
fi
root() { sudo -n true 2>/dev/null; }
TRUSTED="$("$BIN/drive" trusted)"
HZ="$(system_profiler SPDisplaysDataType 2>/dev/null | sed -n 's/.*@ \([0-9.]*\)Hz.*/\1/p' | head -1)"; HZ="${HZ:-60}"
echo "{\"label\": \"$LABEL\", \"panel_hz\": $HZ, \"accessibility\": $TRUSTED, \"root\": $(root && echo 1 || echo 0)}" > "$RUN/raw/run.json"

counters() { sysctl -a 2>/dev/null | grep -E '^debug\.nv'; }
ws_cpu() { ps -o time= -p "$(pgrep -x WindowServer)" | tr -d ' '; }

# measure NAME SECONDS COMMAND... - counters, WindowServer CPU and the frame-gap sampler around COMMAND; a spindump of
# WindowServer across it when root is available. COMMAND should take about SECONDS.
measure() {
    local name="$1" secs="$2"; shift 2
    local d="$RUN/raw/desktop/$name"; mkdir -p "$d"
    counters > "$d/counters-before.txt"; ws_cpu > "$d/ws-cpu-before.txt"
    "$BIN/framegap" "$secs" "$HZ" "$d/framegap.json" & local fg=$!
    # wait on these by pid: a bare wait would also wait on the --sudo keep-alive loop, which never ends
    local sp=""
    if root; then sudo -n spindump WindowServer "$secs" 10 -o "$d/WindowServer.spindump.txt" >/dev/null 2>&1 & sp=$!; fi
    local t0; t0=$(python3 -c 'import time; print(time.time())')
    "$@" > "$d/command.log" 2>&1
    wait $fg
    python3 -c "import time; print(time.time() - $t0)" > "$d/wall-seconds.txt"
    ws_cpu > "$d/ws-cpu-after.txt"; counters > "$d/counters-after.txt"
    [ -n "$sp" ] && wait $sp
    say "  $name done"
}
APP="${TERM_PROGRAM:-the app running this}"; [ "$APP" = Apple_Terminal ] && APP=Terminal
[ "$TRUSTED" = 1 ] || say "no Accessibility for $APP: System Settings > Privacy & Security > Accessibility, turn $APP on, then quit and reopen $APP"
skip() { mkdir -p "$RUN/raw/desktop/$1"; echo "$2" > "$RUN/raw/desktop/$1/skipped.txt"; say "  $1 skipped: $2"; }

finder_window() {  # finder_window X1 Y1 X2 Y2 - prints the new window's id
    osascript -e "tell application \"Finder\" to set w to make new Finder window to (path to home folder)" \
              -e "tell application \"Finder\" to set bounds of w to {$1, $2, $3, $4}" \
              -e "tell application \"Finder\" to get id of w"
}
close_finder() { for id in "$@"; do osascript -e "tell application \"Finder\" to close window id $id" >/dev/null 2>&1; done; }

# --- state ------------------------------------------------------------------------------------------------------
if want state; then
    say "state"
    S="$RUN/raw/state"; mkdir -p "$S"
    sw_vers > "$S/sw_vers.txt"
    kextstat 2>/dev/null | grep -i nullmoth > "$S/kexts.txt"
    for b in /Library/GPUBundles/NVMTLDriver.bundle /Library/GPUBundles/NVIDIAShared.bundle /Library/Extensions/NV*.kext; do
        v=$(defaults read "$b/Contents/Info" CFBundleShortVersionString 2>/dev/null); echo "$b $v"
    done > "$S/bundles.txt"
    shasum -a 256 /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/* /Library/GPUBundles/nvmtl/*.dylib 2>/dev/null > "$S/binaries.sha256"
    ioreg -l -w0 | grep '"nvrm-gpu-profile"' | sed 's/^[ |]*//' > "$S/gpu-profile.txt"
    nvram boot-args > "$S/boot-args.txt" 2>&1
    cp /Library/GPUBundles/nvmtl/nvrm610.conf "$S/" 2>/dev/null
    system_profiler SPDisplaysDataType > "$S/displays.txt" 2>/dev/null
    sysctl -n kern.boottime > "$S/boottime.txt"
    # BAR1: what the Resizable BAR capability offers and what NVRM placed (the 256 MB working constraint)
    /usr/bin/log show --last boot --predicate 'sender == "NVRM" AND eventMessage CONTAINS "bar1:"' --style compact 2>/dev/null \
        | grep 'bar1:' | sed 's/^.*bar1: /bar1: /' | sort -u > "$S/bar1-log.txt"
    counters > "$S/counters-start.txt"
fi

# --- desktop ----------------------------------------------------------------------------------------------------
if want desktop; then
    say "desktop (panel $HZ Hz, accessibility $TRUSTED)"
    measure idle 5 sleep 5
    if [ "$TRUSTED" = 1 ]; then
        W=$(finder_window 400 300 1300 900); sleep 1
        measure drag-small 8 "$BIN/drive" drag 850 312 8
        close_finder "$W"
        W=$(finder_window 200 100 2200 1300); sleep 1
        measure drag-large 8 "$BIN/drive" drag 1200 112 8
        close_finder "$W"
        IDS=""; for i in $(seq 1 14); do IDS="$IDS $(finder_window $((100 + i * 40)) $((150 + i * 30)) $((900 + i * 40)) $((700 + i * 30)))"; done
        W=$(finder_window 400 300 1300 900); sleep 1
        measure drag-15-windows 8 "$BIN/drive" drag 850 312 8
        close_finder "$W" $IDS
        measure dock-sweep 8 "$BIN/drive" sweep 8
    else
        for s in drag-small drag-large drag-15-windows dock-sweep safari-scroll; do
            skip "$s" "no Accessibility permission for $APP"
        done
    fi
    W=$(finder_window 400 300 1300 900); sleep 1
    measure dock-minimize 9 bash -c "for i in 1 2 3; do osascript -e 'tell application \"Finder\" to set collapsed of window id $W to true'; sleep 1.5; osascript -e 'tell application \"Finder\" to set collapsed of window id $W to false'; sleep 1.5; done"
    close_finder "$W"
    measure mission-control 8 bash -c 'for i in 1 2; do open -a "Mission Control"; sleep 2; open -a "Mission Control"; sleep 2; done'
    if [ "$TRUSTED" = 1 ]; then
        python3 "$HERE/pages.py" scroll "$CLIPS/scroll.html"
        SAFARI_WAS=$(pgrep -x Safari >/dev/null && echo 1 || echo 0)
        osascript -e 'tell application "Safari" to make new document with properties {URL:"file://'"$CLIPS/scroll.html"'"}' \
                  -e 'tell application "Safari" to set bounds of front window to {200, 80, 1800, 1300}' -e 'tell application "Safari" to activate' >/dev/null
        sleep 3
        measure safari-scroll 8 "$BIN/drive" scroll 1000 700 8
        osascript -e 'tell application "Safari" to close front window' >/dev/null
        [ "$SAFARI_WAS" = 0 ] && osascript -e 'tell application "Safari" to quit' >/dev/null
    fi
fi

# --- launch -----------------------------------------------------------------------------------------------------
cache_sizes() {  # every shader cache folder the plugin can pick, per user and per sandbox container
    { du -sk "$HOME/Library/Caches/nvmtl"/* /Library/GPUBundles/nvmtl/aircache 2>/dev/null
      du -sk "$HOME"/Library/Containers/*/Data/Library/Caches/nvmtl 2>/dev/null
      du -sk "$(getconf DARWIN_USER_CACHE_DIR)"nvmtl/* "$(getconf DARWIN_USER_TEMP_DIR)"nvmtl/* 2>/dev/null
      ls -d "$HOME"/.cache/mesa_shader_cache* "$(getconf DARWIN_USER_CACHE_DIR)"mesa_shader_cache* 2>/dev/null | sed 's/^/mesa-disk-cache /'
    } | sort -u
}
if want launch; then
    say "launch"
    L="$RUN/raw/launch"; mkdir -p "$L"
    cache_sizes > "$L/caches-before.txt"
    for app in com.apple.TextEdit com.apple.calculator com.apple.ActivityMonitor com.apple.systempreferences com.apple.Photos com.apple.Safari; do
        root && sudo -n purge
        for pass in first second; do
            "$BIN/launch" "$app" 30 2>/dev/null > "$L/$app-$pass.json"
            say "  $app $pass: $(cat "$L/$app-$pass.json")"
            sleep 2
        done
    done
    cache_sizes > "$L/caches-after.txt"
fi

# --- video ------------------------------------------------------------------------------------------------------
if want video; then
    say "video"
    V="$RUN/raw/video"; mkdir -p "$V"
    "$BIN/vt" list > "$V/list.json" 2> "$V/list.stderr"
    for c in h264 hevc hevc10; do
        counters > "$V/encode-$c-counters-before.txt"
        "$BIN/vt" encode $c 3840 2160 60 12 "$V/encode-$c.mov" > "$V/encode-$c.json" 2> "$V/encode-$c.stderr"
        counters > "$V/encode-$c-counters-after.txt"
        ioreg -r -c IOAccelerator -w0 -l | grep PerformanceStatistics | sed 's/^[ |]*//' > "$V/encode-$c-perfstats.txt"
        say "  encode $c: $(cat "$V/encode-$c.json")"
        # keep a clip to decode even when hardware encode fails; the software one is made once and reused
        if grep -q '"hardware":true' "$V/encode-$c.json"; then mv "$V/encode-$c.mov" "$CLIPS/$c.mov"
        else rm -f "$V/encode-$c.mov"; [ -f "$CLIPS/$c.mov" ] || "$BIN/vt" make $c 3840 2160 60 12 "$CLIPS/$c.mov" >/dev/null 2>&1; fi
    done
    for c in h264 hevc hevc10; do
        "$BIN/vt" decode "$CLIPS/$c.mov" > "$V/decode-$c.json" 2> "$V/decode-$c.stderr"
        say "  decode $c: $(cat "$V/decode-$c.json")"
        counters > "$V/play-$c-counters-before.txt"
        "$BIN/vt" play "$CLIPS/$c.mov" 10 > "$V/play-$c.json" 2> "$V/play-$c.stderr"
        counters > "$V/play-$c-counters-after.txt"
        say "  play $c: $(cat "$V/play-$c.json")"
    done
    # Safari: the sandboxed path through VTDecoderXPCService. Starting playback and reading the frame count need
    # Safari's Develop menu > "Allow JavaScript from Apple Events"; without it the result says so. Safari is brought to
    # the front: frame callbacks stop while its window is hidden.
    SAFARI_WAS=$(pgrep -x Safari >/dev/null && echo 1 || echo 0)
    safari_js() { osascript -e "tell application \"Safari\" to do JavaScript \"$1\" in front document" 2>&1; }
    for c in h264 hevc hevc10; do
        python3 "$HERE/pages.py" video "$CLIPS/safari-$c.html" "$CLIPS/$c.mov"
        osascript -e 'tell application "Safari"' -e 'activate' \
            -e 'make new document with properties {URL:"file://'"$CLIPS/safari-$c.html"'"}' -e 'end tell' >/dev/null
        # the first call can land before the page has loaded and come back empty
        for _ in 1 2 3 4 5; do sleep 1; [ "$(safari_js 'window.nvstart()')" = started ] && break; done
        SP=""
        if root; then (sleep 3; sudo -n sample VTDecoderXPCService 4 -file "$V/safari-$c-VTDecoderXPCService.sample.txt" >/dev/null 2>&1) & SP=$!; fi
        sleep 10
        safari_js 'JSON.stringify(window.nvq())' > "$V/safari-$c.json"
        osascript -e 'tell application "Safari" to close front window' >/dev/null
        say "  safari $c: $(cat "$V/safari-$c.json")"
        [ -n "$SP" ] && wait $SP
    done
    [ "$SAFARI_WAS" = 0 ] && osascript -e 'tell application "Safari" to quit' >/dev/null
    [ -f /tmp/nvmtl.log ] && grep -i -E 'regist|nvdec|nvenc|-13' /tmp/nvmtl.log | tail -200 > "$V/nvmtl-log-video.txt"
fi

# --- stats ------------------------------------------------------------------------------------------------------
if want stats; then
    say "stats"
    ioreg -r -c IOAccelerator -w0 -l | grep -E 'PerformanceStatistics|"IOClass"' | sed 's/^[ |]*//' > "$RUN/raw/perfstats.txt"
fi

# --- login: 240 s of WindowServer CPU and flips per second, for a run started right after login ------------------
if want login; then
    say "login (240 s)"
    G="$RUN/raw/login"; mkdir -p "$G"
    cache_sizes > "$G/caches-before.txt"
    counters > "$G/counters-before.txt"
    for i in $(seq 1 240); do
        echo "$i $(ws_cpu) $(sysctl -n debug.nvaccel_iop_flips) $(sysctl -n debug.nvaccel_vm_refused)" >> "$G/per-second.txt"
        sleep 1
    done
    counters > "$G/counters-after.txt"
    cache_sizes > "$G/caches-after.txt"
fi

counters > "$RUN/raw/counters-end.txt"
python3 "$HERE/summarize.py" "$RUN" && say "summary: $RUN/summary.md"
