# Triton guest driver (test-signed build)

`.github/workflows/driver.yml` builds the Windows side of Triton on a
`windows-2022` runner (about 15 minutes) and test-signs it:

| Part | Upstream |
| --- | --- |
| Kernel-mode driver (`viogpu3d.sys`) | [osy/kvm-guest-drivers-windows](https://github.com/osy/kvm-guest-drivers-windows), tag `v0.4` |
| Direct3D user-mode driver (`neptune_umd.dll`, 64-bit and 32-bit) and Venus Vulkan driver | [osy/virtio-win-mesa](https://github.com/osy/virtio-win-mesa) (Mesa fork) |

The driver is the upstream authors' work. This folder only holds the build
inputs and three fixes:

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
- [`patches/kmd/0001`](patches/kmd/0001-win10-paging-buffer-segment.patch),
  **Windows 10.** The driver puts its paging buffers in system memory.
  Windows 11 accepts that, but Windows 10's video memory manager
  (`dxgmms2.sys`) then reads a missing allocation while setting up the GPU
  and blue-screens (stop code 0x7E) as soon as the driver starts. On
  Windows 10 the paging buffers now go in a GPU memory segment instead.

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
