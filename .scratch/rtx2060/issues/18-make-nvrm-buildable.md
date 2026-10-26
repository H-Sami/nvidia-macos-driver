# Make NVRM buildable

Type: task
Status: open
Blocked by: a spec that needs an NVRM change

## Question

Can `NVRM.kext` be built from `rtx2060` on Tahoe, matching the 2.5.5 release, so a spec that changes NVRM can ship it?

[Build the fork from source on Tahoe](03-build-fork-on-tahoe.md) copies NVRM from the 2.5.5 release: the repo has the
RM objects' consumers but not `build-nvrm.sh`, the recipe that makes `_out/Darwin_x86_64`, in any branch or tag. One
lead: NVIDIA's Makefile already sees `TARGET_OS=Darwin` on this Mac, which may be how upstream produced that folder.

Done when the answer records a build script for NVRM committed to `rtx2060`, how its output compares with the 2.5.5
NVRM, and one boot with the local NVRM and Metal 3 reported. Not worth taking until a spec needs an NVRM change.
