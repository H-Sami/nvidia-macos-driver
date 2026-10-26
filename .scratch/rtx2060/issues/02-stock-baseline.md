# Capture the stock baseline

Type: task
Status: resolved
Assignee: H-Sami
Blocked by: 01

## Question

What are this RTX 2060's numbers on stock NullMoth 2.5.5 across the 10/10 list, and which of the owner's symptoms
(hitches, sluggishness, slow app launches and Settings icons, imperfect window drag, Dock, Mission Control, Safari
scrolling, video) show up in them?

HITL, run by the owner on Tahoe:

1. Update the stock driver to 2.5.5 with 1401, so the baseline matches the fork's base (`v2.5.5`). Reboot.
2. Do the one-time setup in `tools/rtx2060/README.md` (Accessibility, Safari's "Allow JavaScript from Apple Events").
   Then run the harness from [Write the measurement harness](01-measurement-harness.md) twice: once right after login
   (cold; `login-agent.sh install` also records the login itself), once after 30 minutes of normal use (warm), each
   with `run.sh --label stock-cold|stock-warm --sudo`.
3. Commit the result folders to `rtx2060` under `.scratch/rtx2060/baseline/`, and record here the headline numbers
   and anything that failed to measure.

## Progress

2026-10-26, claimed. Step 1 is done: NVRM, NVRMFB, NVRMAGDC and NVAccel load as 2.5.5 on macOS 26.7.1 (25G241).
Step 2's setup is done too: Accessibility is granted, and Safari counted frames in `152648-stock-video`. The runs in
`~/rtx2060-runs/` from today are harness try-outs, not the baseline: no labelled cold run, no warm run, no login.
`150712-stock` is the only full run (`--sudo`).

Seen so far, to confirm in the real runs:

- **Hardware H.264 encode stopped working partway through the day.** It ran at 158 fps in `150712-stock`. Every run
  after that got `no hardware encoder (-12908)`. HEVC and Main10 kept encoding. The cold run after a reboot shows
  whether a reboot clears it (a leaked NVENC session, #206?) or whether it stays broken.
- **4K H.264 is the slow codec.** It decodes at 45 fps and AVPlayer shows 40 fps; HEVC plays at 58.7. In Safari, all
  three clips presented about 600 frames in 10 s with no gaps over two periods (`152648`).
- **Every animation misses the target.** Dock minimize bursts reach 73 fps, the 15-window drag 62 fps (427 gaps over
  11 ms, 19.9 ms of WindowServer CPU per frame), and the Dock sweep 55 fps (84 pauses over 50 ms).
- **A full run is 110 MB**, almost all of it desktop spindumps. Step 3 should commit `summary.*`, `run.log`,
  `raw/state` and the spindumps gzipped, not the raw folder as it stands.

## Answer

The baseline is three runs on stock 2.5.5 (macOS 26.7.1), in `.scratch/rtx2060/baseline/`: `154330-stock-cold`
(right after login), `162100-stock-warm` (about 30 minutes of normal use later) and `153642-login`. Each folder holds
the full run, with files over 200 KB gzipped (the WindowServer spindumps). Compare a later run with
`tools/rtx2060/compare.py`. `154248-stock-cold` stopped after its idle step and was not kept.

Headline numbers, cold / warm (target in brackets):

- **Desktop, fps within the animation burst** [180, zero gaps over 11 ms]: small-window drag 120 / 117, large-window
  drag 91 / 90, 15-window drag 64 / 63 (434 / 423 gaps; **19.7 ms of WindowServer CPU per frame**), Dock minimize
  88 / 80, Dock sweep 85 / 65, Mission Control 92 / 93, Safari scroll 110 / 114. Every scenario misses. The burst p99
  gap sits at about 16.8 ms, so frames land on every third refresh. The Dock gets worse warm: the sweep goes from 2 to
  88 pauses over 50 ms, and its p99 gap from 17 to 33 ms.
- **Surface refusals** [zero in normal use]: none during the scripted scenarios, but **87,892 had piled up during the
  30 minutes of normal use** before the warm run (`debug.nvaccel_vm_refused`, 0 at the end of the cold run). The
  NVRMFB budget is 226 MiB; about 150 MiB of it is mapped at any time.
- **Login**: 6.3 s of WindowServer CPU in 240 s, with a peak of 148% and 5 s over 50%. No refusals.
- **App launch, first window, then second launch**: Safari 3.8 / 1.2 s, System Settings 3.4 / 1.4 s, Calculator
  3.2 / 1.0 s, TextEdit 2.8 / 0.8 s, Photos 2.7 / 0.8 s, Activity Monitor 2.6 / 0.8 s, the same cold and warm. The
  shader cache was already 900 MB and did not grow, so first launches are slow even with a warm disk cache.
- **Video decode** [4K60, no drops]: all hardware. Raw decode: H.264 **45 fps**, HEVC 345, HEVC Main10 263. AVPlayer
  shows H.264 at **41 fps** (190 frames late), HEVC at 58.9 and Main10 at 58. Safari plays all three at 60 with no
  gaps over two frames. VTDecoder reports no VP9 (and no AV1, out of scope).
- **Video encode** [hardware H.264 and HEVC]: 4K60 hardware encode at 158 fps for H.264, 110 for HEVC and 78 for
  Main10. Both runs list two encoders.
- **Stats** [utilization shown]: no `Device Utilization %`; 77 `PerformanceStatistics` keys.
- **Metal**: not measured by the harness. It's in the fog.

Symptoms against the numbers:

- **Imperfect window drag, Dock, Mission Control, Safari scrolling**: confirmed. Nothing gets above 120 fps, and most
  scenarios hit about 60 to 90.
- **Hitches and sluggishness**: confirmed by the gaps, by the Dock getting worse warm, and by the refusals that pile up
  during normal use (0 → 87,892).
- **Slow app launches and Settings icons**: confirmed, 2.6 to 3.8 s to a first window.
- **Video**: H.264 is the slow codec, below 60 in AVPlayer while Safari keeps up. HEVC is fine.
- **The H.264 encoder that stopped during the day** (seen before these runs) works in both runs after a reboot, so it
  is lost state that a reboot clears (a leaked session?). The encode plan should cover it.

Didn't measure: Metal app correctness; whether the login run had Accessibility or root (it ran from the login agent
without them, which login measuring doesn't need).
