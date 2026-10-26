# Capture the stock baseline

Type: task
Status: open
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
