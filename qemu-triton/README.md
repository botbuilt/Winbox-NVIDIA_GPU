# Triton host stack

The QEMU that WinBox ships, built in the first stages of the root
`Dockerfile`. It runs [Triton](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/),
the DirectX 11 driver for Windows guests on a virtio GPU, from:

| Part | Source |
|---|---|
| QEMU 10.0 with the Neptune virtio-gpu context | `utmapp/qemu`, branch `utm-edition` |
| virglrenderer with the Neptune host module | `utmapp/virglrenderer`, branch `macos-next` |
| DXVK Native (renders the guest's D3D11 on host Vulkan) | `osy/dxvk`, `master` |

The commits are pinned in the `Dockerfile`. virglrenderer, its render server
and DXVK go to `/opt/neptune`. QEMU finds them through its rpath, and the
Neptune module through `NPT_D3D11_LIBRARY_PATH` / `NPT_DXGI_LIBRARY_PATH`.

## Patches

`patches/` (QEMU):

- `0001-accept-host3d-blob-limit.patch`: accept the `host3d_blob_limit`
  option that dockurr/windows passes to its own QEMU build. The value is
  ignored.
- `0002-scanout-dmabuf-modifier.patch`: pass a scanout's DRM format
  modifier to the display. Without it, tiled scanouts (always the case on
  Nvidia) show a black screen.
- `0003-egl-headless-copy-only-while-watched.patch`: stop reading every
  guest frame back into RAM. The egl-headless display copies the newest
  frame once per refresh tick (30 ms), and only while a VNC client (the web
  console on port 8006) is connected. Before, each frame stalled QEMU's main
  thread on a full-screen `glReadPixels`, even with nobody watching.
- `0004-virtio-gpu-refresh-rate.patch`: a `refresh_rate` option for the
  virtio GPU, in Hz (or mHz from 1000 up). Headless displays never report a
  rate, so the guest's monitor defaulted to 75 Hz. For example
  `VGA=virtio-vga-gl,neptune=true,refresh_rate=120` gives Windows a 120 Hz
  monitor, which matters when streaming at 120 fps. Higher rates also mean
  more frames for the host to render.
- `0005-winbox-stream-socket.patch`: a unix socket for a streamer on the host
  (`WINBOX_STREAM_SOCKET`, set by `STREAM=Y`). The egl-headless display
  sends the guest's scanout over it as a dmabuf, plus a message per frame
  and the cursor, and takes keyboard and mouse input back. Sunshine in
  [`sunshine/`](../sunshine/README.md) is the other end. Nothing changes
  when the variable is unset.

`virgl-patches/` (virglrenderer):

- `0001`: small fixes for code GCC rejects. The Neptune branch is developed
  with clang on macOS.
- `0002`: carry each Neptune blob's DRM format modifier to QEMU
  (`virgl_renderer_resource_get_modifier`).
- `0003`: log why a `CreateInputLayout` call fails to decode.
- `0004`: accept shader bytecode lengths from 32-bit (WOW64) guest apps,
  whose driver leaves junk in the upper half of the 64-bit size. Without
  it, 32-bit DirectX 11 games hang on a black screen. The guest driver in
  `driver/` fixes the cause; this keeps the stock driver working too.

`dxvk-patches/` (DXVK):

- `0001`: fall back to a tiled layout when the driver has no shareable
  linear one for a scanout texture, and log the linear modifier's
  features.
- `0002`: store A8 textures as R8, since A8 has no DRM format to share.
