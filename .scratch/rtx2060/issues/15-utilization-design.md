# Choose the utilization design

Type: grilling
Status: open
Blocked by: 14

## Question

Where does sampling run and what gets published, so Activity Monitor and iStat Menus show GPU, encoder and decoder
use (and VRAM) for this card, by name?

Candidates from [Exposing GPU utilization to macOS](08-exposing-utilization.md): a 1 Hz kernel sampler in NVRM
published by NVAccel; that plus per-command-buffer busy time for per-process % GPU; overriding `newStatistics()` to
end the dictionary-rewrite race; a device-specific match string so monitors pair NVAccel with the card; upstream
PR #380 as a ready-made alternative ([Survey community fixes](04-community-fixes-survey.md)). Settle with the results
of [Probe utilization keys and GPUMON on Tahoe](14-utilization-probe.md).
