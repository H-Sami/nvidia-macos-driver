# RTX 2060 measurement harness

One command on the Tahoe install records the numbers the 10/10 list on the `rtx2060` map is judged by, into a dated
folder. Nothing is uploaded. It works against the stock driver, so the stock baseline and every later build are
measured the same way.

```sh
tools/rtx2060/run.sh --label stock --sudo     # about 6 minutes; the screen is driven while it runs
tools/rtx2060/compare.py ~/rtx2060-runs/<stock> ~/rtx2060-runs/<fork> [desktop.drag]
```

Results: `~/rtx2060-runs/<date>-<label>/summary.md` (readable), `summary.json` (flat metric -> number, what
`compare.py` diffs), `raw/` (everything collected), `run.log`.

## One-time setup (owner)

- **Accessibility** for the app that runs the harness (System Settings > Privacy & Security > Accessibility: Terminal,
  iTerm or Claude), then quit and reopen that app: the permission is read when it starts. Without it the drag, Dock sweep and Safari scroll scenarios are skipped, and the summary says so.
- **Safari > Settings > Advanced > "Show features for web developers"**, then **Develop > Allow JavaScript from Apple
  Events**. Without it the Safari video clips don't start and their frame counts are missing.
- **Don't run it with `sudo ./run.sh`**: it refuses, because it drives your desktop as you. **`--sudo`** asks for the password once, for `spindump WindowServer`, `sample VTDecoderXPCService` and `purge`
  before each first launch. Without it those are skipped (Debugging Restrictions are on, so they need root here).
- Run it more than 5 minutes after login, with other apps closed. Apps that are already running are left alone and
  reported as skipped, never quit.

## Sections (`--only state,desktop,launch,video,stats,login`)

| section | what it records |
|---|---|
| state | macOS, kext and bundle versions, binary hashes, `nvrm-gpu-profile`, boot-args, `nvrm610.conf`, displays, uptime, and NVRM's `bar1:` lines (the BAR sizes the Resizable BAR capability offers and what was placed) |
| desktop | per scenario: flips per second and gaps between flips (`framegap` polls `debug.nvaccel_iop_flips` every 250 us), WindowServer CPU % and ms per frame, `debug.nv*` counter deltas (refusals, grants, latch timeouts, ...), and a WindowServer spindump with `--sudo`. Scenarios: idle, 8 s title-bar drag of a small window, a large window, and a small window over 14 others, Dock sweep, Dock minimize/restore, Mission Control, Safari scroll |
| launch | time from launch to first on-screen window, first and second launch, for TextEdit, Calculator, Activity Monitor, System Settings, Photos, Safari; the size of every shader cache folder before and after, and whether a Mesa disk cache exists |
| video | encoders VideoToolbox lists before and after the process makes a Metal device (the plugin registers only then); hardware-only 4K60 encode of H.264, HEVC and HEVC Main10 (fps, encoder ID, counters, `PerformanceStatistics` during it); hardware-only decode of each clip as fast as it goes; 10 s of AVPlayer playback (the QuickTime path) with frames shown and dropped; the same clips for 10 s in Safari (the `VTDecoderXPCService` path), counted with `requestVideoFrameCallback` (Safari leaves `getVideoPlaybackQuality()` at 0 outside MSE): frames shown, frames short of real time, worst gap |
| stats | every `PerformanceStatistics` key IOAccelerator publishes, and whether `Device Utilization %` is among them |
| login | 240 s of WindowServer CPU, flips and refusals per second; `login-agent.sh install` runs it once at the next login |

### Reading the desktop numbers

A gap over two refresh periods (11.1 ms at 180 Hz) is the 10/10 failure. Animations come in bursts with an idle
desktop between them, so besides the raw counts the summary splits the flips at gaps over 50 ms: `burst_fps` and
`burst_gaps_over_two_periods` describe the animation itself, `pauses_over_50ms` the rest. Under continuous input (the
drags and the scroll) a pause is a stall too.

Playback that falls behind slows down rather than dropping frames, so `video.play.*.frames_short` and
`video.safari.*.frames_short` (frames short of real time) matter as much as `dropped`.

## Not covered (needs a person, or a profiling session)

- Which encoder OBS, HandBrake, FaceTime and Screen Sharing pick, and which codec YouTube serves Safari: check by hand.
- Instruments Time Profiler / System Trace: Command Line Tools only on this machine, no `xctrace`.
- Refresh-rate and window-count sweeps beyond the three drags, the `nvrm610.conf` A/B, and the login spindumps
  with a wiped shader cache: profiling work for the specs, run with `diagnosing-bugs`, using these helpers.
