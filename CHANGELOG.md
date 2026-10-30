# Changelog

All notable changes. Versions follow [semver](https://semver.org); release
by pushing a `vX.Y.Z` tag.

## Unreleased

First public version, as **WinBox NVIDIA GPU** (`ghcr.io/botbuilt/winbox-nvidia-gpu`).

- Moonlight streaming encoded on the GPU (`STREAM=Y`): Sunshine in the
  container takes Windows' screen straight from QEMU and encodes it with
  NVENC, with keyboard, mouse and sound. Built with CUDA 12.9 so Pascal
  cards keep working.
- QEMU reads frames back for the web console only while it is open, and the
  virtual monitor's refresh rate can be set (`refresh_rate=`).
- Smaller GPU helpers (2 shader compiler threads, `MALLOC_ARENA_MAX=2`), and
  Nvidia's shader cache kept with the Windows disk so games don't recompile
  after an update. The README explains how to size `RAM_SIZE` and the
  memory cap.

- Windows in a container for Unraid, based on dockurr/windows, with an
  Unraid startup hook, healthcheck, backup, snapshot and clean-shutdown
  scripts.
- Triton host stack (QEMU, virglrenderer, DXVK) with fixes for Nvidia
  scanouts, A8 textures and 32-bit guest apps.
- Test-signed Triton guest driver build with fixes for 32-bit programs and
  Direct3D in Remote Desktop sessions, and a fix for a blue screen when the
  driver starts on Windows 10.
- Without GPU acceleration, the container falls back to a plain virtio
  display.
- The template caps container memory (`--memory`) so a runaway Windows
  can't freeze the host.
