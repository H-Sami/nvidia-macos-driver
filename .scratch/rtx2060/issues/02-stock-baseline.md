# Capture the stock baseline

Type: task
Status: open
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
