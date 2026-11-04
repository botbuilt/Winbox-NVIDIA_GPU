# Triton guest driver (test-signed build)

`.github/workflows/driver.yml` builds the Windows side of Triton on a
`windows-2022` runner (about 15 minutes) and test-signs it:

| Part | Upstream |
| --- | --- |
| Kernel-mode driver (`viogpu3d.sys`) | [osy/kvm-guest-drivers-windows](https://github.com/osy/kvm-guest-drivers-windows), tag `v0.4` |
| Direct3D user-mode driver (`neptune_umd.dll`, 64-bit and 32-bit) and Venus Vulkan driver | [osy/virtio-win-mesa](https://github.com/osy/virtio-win-mesa) (Mesa fork) |

The driver is the upstream authors' work. This folder only holds the build
inputs and these changes:

- [`patches/mesa/0001`](patches/mesa/0001-wow64-pointer-sized-wire-types.patch),
  **32-bit (WOW64) programs.** Handle- and pointer-sized values (`SIZE_T`,
  `HANDLE`, `HWND`, `HMODULE`, `LONG_PTR`) always use 8 bytes on the wire
  but are 4 bytes in a 32-bit process. Sending them read 4 bytes of stack
  garbage and receiving them wrote 4 bytes past the field, so 32-bit
  DirectX 11 games hung on a black screen.
- [`patches/mesa/0002`](patches/mesa/0002-find-viogpu-without-display-device.patch),
  **Direct3D in Remote Desktop.** The driver looked for the GPU only among
  connected displays. In an RDP session the only display is the RDP
  adapter, so D3D on the virtio GPU was unavailable ("D3D Status: Not
  Available" in dxdiag). It now also finds the GPU by its PCI ID
  (`1AF4:1050`).
- [`patches/mesa/0003`](patches/mesa/0003-longer-ring-idle-timeout.patch),
  **Fewer wake-ups per frame (test).** The host stopped watching an app's
  command ring 1 ms after its last command, so nearly every frame had to
  wake it again through the kernel driver. It now keeps watching for 8 ms.
  The `NPT_RING_IDLE_MS` environment variable (1 to 100) overrides that.
- [`patches/mesa/0004`](patches/mesa/0004-release-imported-textures.patch),
  **Leaked window textures (test).** When the desktop compositor (DWM)
  stopped using another program's window surface, the driver skipped
  freeing it if a sync step failed first. The surface and its texture on
  the host GPU then stayed allocated, so DWM's shared GPU memory and the
  host's video memory grew until the host ran out of RAM. The driver now
  frees it anyway and logs how many such surfaces each process holds open.
- [`patches/mesa/0005`](patches/mesa/0005-vram-accounting.patch) and
  [`patches/kmd/0006`](patches/kmd/0006-vram-accounting-allocations.patch),
  **Games see how much GPU memory they use (test).** Textures and buffers
  live only on the host GPU, so Windows counted almost none of them and
  told every game it had used nothing out of its budget. Games that size
  their texture streaming by that budget kept loading textures as you
  played until the host GPU was full and spilled into host RAM, and Unraid
  killed WinBox. Each large texture or buffer (128 KB or more) now also
  gets an empty placeholder allocation of the same size in the GPU memory
  window (`VRAM_SIZE`), so Windows' video memory usage and budget match
  what the game really has on the GPU, and the game trims itself. The
  placeholder has no memory behind it. `NPT_VRAM_ACCOUNT=0` (a Windows
  environment variable) turns it off.
- [`patches/kmd/0001`](patches/kmd/0001-win10-paging-buffer-segment.patch),
  **Windows 10.** The driver puts its paging buffers in system memory.
  Windows 11 accepts that, but Windows 10's video memory manager
  (`dxgmms2.sys`) then reads a missing allocation while setting up the GPU
  and blue-screens (stop code 0x7E) as soon as the driver starts. On
  Windows 10 the paging buffers now go in a GPU memory segment instead.
- [`patches/kmd/0002`](patches/kmd/0002-win10-idle-copy-node.patch),
  **Windows 10 freeze.** With a single GPU engine, Windows 10's scheduler
  can spin forever while holding its lock, which froze Windows as soon as a
  browser used the GPU. On Windows 10 the driver now reports a second, idle
  copy engine that completes its work at once, so the scheduler takes its
  normal path.
- [`patches/kmd/0003`](patches/kmd/0003-overlap-host-round-trips.patch),
  **More work in flight (test).** The driver ran one GPU packet at a time
  and kept that slot while it waited for the host to answer, so every
  packet from every app waited for the one before it. A packet whose last
  command is already on its way to the host (or only waits for the GPU to
  finish) now gives its slot back, and the next packet starts. Packets
  still reach the host in order and still report as finished in order.
- [`patches/kmd/0004`](patches/kmd/0004-msi-interrupts.patch),
  **MSI interrupts (test).** The GPU's three message interrupts (display
  change, commands, cursor) are now used instead of one shared interrupt.
- [`patches/kmd/0005`](patches/kmd/0005-keep-scheduler-registry-values.patch),
  **Keep the two required registry values.** The driver needs
  `GraphicsDrivers\TdrDebugMode=1` and `GraphicsDrivers\Scheduler\EnablePreemption=0`.
  The INF writes them only at install, and Windows sometimes loses them
  (the GPU then shows Code 43). The driver now writes them again every
  time it loads, so after one restart the GPU works again on its own.

## Build details

1. Fetch the pinned upstream commits (`env` in the workflow).
2. Apply `patches/mesa/*.patch` and `patches/kmd/*.patch` in name order.
3. Build the Neptune UMD for x64 and x86 and the Venus Vulkan driver (Mesa
   with Meson, no LLVM), then `viogpu3d` with the WDK.
4. Stamp the driver version `100.6.101.<58100 + run number>`, so every build
   is newer than the last one and than upstream `v0.4`.
5. Test-sign with the VirtIO test certificate that ships with the upstream
   source, and zip it with `package/install.cmd`, `package/README.txt` and
   the upstream license texts.

Every push that touches `driver/` uploads the zip as an Actions artifact. A
`v*` tag also attaches it to that GitHub Release.

## Test mode

- Windows shows a "Test Mode" watermark.
- Some anti-cheat games refuse to start while test signing is on.
- The test certificate's private key is public (it is part of the upstream
  source), so trusting it means trusting anything signed with it. Only do
  this in a VM you're comfortable treating that way.

To go back: Device Manager > Display adapters > VirtIO GPU 3D controller >
Properties > Driver > **Roll Back Driver**, then
`bcdedit -set TESTSIGNING OFF` and reboot.
