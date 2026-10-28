# Changelog

All notable changes. Versions follow [semver](https://semver.org); release
by pushing a `vX.Y.Z` tag.

## Unreleased

First public version.

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
