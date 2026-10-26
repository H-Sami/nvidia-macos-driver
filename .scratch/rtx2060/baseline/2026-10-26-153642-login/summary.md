# 2026-10-26-153642-login

Panel 180.0 Hz; Accessibility 0; root 0. Frame gaps are judged against two refresh periods (11.1 ms).

## run

| metric | value |
|---|---|
| panel_hz | 180.0 |
| accessibility | 0 |
| root | 0 |

## login

| metric | value |
|---|---|
| windowserver_cpu_pct_max | 148.0 |
| windowserver_cpu_seconds | 6.25 |
| seconds_over_50pct_cpu | 5 |
| vm_refused | 0 |
| flips | 321 |

## end

| metric | value |
|---|---|
| nvaccel_surface_gpu_wait_max_us | 40546 |
| nvrm_kms_timer_depth | 0 |
| nvrm_kms_timer_max_depth | 4 |
| nvrmfb_flip_latch_max_us | 16437 |
| nvrmfb_flip_us_max | 17074 |
| nvrmfb_vram_budget_bytes | 236650496 |
| nvrmfb_vram_display_bytes | 15007744 |
| nvrmfb_vram_mapped_bytes | 122224640 |
| nvaccel_vm_refused | 0 |
| nvaccel_vm_alloc | 289 |

## State

**macOS**

```
ProductName:		macOS
ProductVersion:		26.7.1
BuildVersion:		25G241
```
**kexts**

```
119    0 0xffffff7f97d4e000 0x22e72    0x22e72    com.nullmoth.NVRMFB (2.5.5) 22958689-1A49-3F93-81D0-D6F2DD4E8E55 <104 7 6 3 1>
  134    0 0xffffff7f97d49000 0x2edf     0x2edf     com.nullmoth.NVRMAGDC (2.5.5) EF61483E-E558-3981-9EEF-4E26C7B14CC3 <105 7 6 3 1>
  139    0 0xffffff7f96dde000 0xe16a94   0xe16a94   com.nullmoth.NVRM (2.5.5) 4D64224B-5868-327C-A203-A25082F58AE3 <19 17 9 7 6 3 1>
  141    0 0xffffff7f96dbd000 0x14d80    0x14d80    com.nullmoth.NVAccel (2.5.5) 554D05FA-7EDB-32DF-9327-B1ED17B5AD7C <140 104 79 19 7 6 3 1>
```
**bundles**

```
/Library/GPUBundles/NVMTLDriver.bundle 0.1
/Library/GPUBundles/NVIDIAShared.bundle 1.0
/Library/Extensions/NVAccel.kext 2.5.5
/Library/Extensions/NVRM.kext 2.5.5
/Library/Extensions/NVRMAGDC.kext 2.5.5
/Library/Extensions/NVRMFB.kext 2.5.5
```
**GPU profile**

```
"nvrm-gpu-profile" = {"class-3d"=50583,"class-compute"=50624,"generation"="Turing","class-copy"=50613,"video-layout"="classic","impl"=6,"class-nvenc"=50359,"arch"=352,"chip"="TU106","scanout"="by-handle","vram-mb"=6144,"native-shaders"="none","class-nvdec"=50352,"bar1-mb"=256}
```
**boot-args**

```
boot-args	-v debug=0x100 keepsyms=1 revpatch=sbvmm nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0 gfxrst=4 nvrmsettle=10000
```
**BAR1**

```
bar1: BAR1 is 64 MB; will resize it to 256 MB
bar1: PLACED — BAR1 256 MB live at 0x7fe0000000
bar1: Resizable BAR capability @0xbb0 says BAR1 = 64 MB (sizes supported mask 0x1c0)
bar1: dropping stale aperture 0x824000000+0x2000000
bar1: host bridge 64-bit window 0x820000000-0x7fffffffff (ACPI _CRS), CPU reaches 48 bits
bar1: placing BAR1 256 MB @0x7fe0000000, BAR3 32 MB @0x7ff0000000, root port window 0x7fe0000000-0x7ff1ffffff (was 0x26012001 00000008/00000008)
bar1: resized BAR1 to 256 MB
```
**Uptime at run**: 1 min
