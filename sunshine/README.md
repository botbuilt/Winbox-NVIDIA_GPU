# Sunshine for STREAM=Y

[Sunshine](https://github.com/LizardByte/Sunshine) by LizardByte, built with
one extra capture source so it can stream the Windows VM from inside the
WinBox container. Moonlight connects to Sunshine in the container instead of
a Sunshine installed in Windows. The NVIDIA card encodes the video (NVENC)
on the host, so Windows spends no CPU or GPU time on capturing and encoding.

The patch was written by an AI assistant (Claude) for WinBox. Sunshine itself,
its build scripts and packaging are LizardByte's work, unchanged apart from
the patch below. Sunshine is licensed under GPL-3.0, and so is the patch.

## How it works

QEMU's patch `qemu-triton/patches/0005-winbox-stream-socket.patch` opens a
unix socket (`WINBOX_STREAM_SOCKET`, `/run/winbox-stream.sock`). Over it QEMU
sends:

- the guest's scanout as a dmabuf, each time Windows flips to a new buffer,
- a message per guest frame,
- the mouse cursor image and position.

The other way it takes keyboard (Windows virtual-key codes), absolute and
relative mouse moves, buttons and the wheel, and feeds them to the VM's
virtual keyboard and mouse.

`patches/0001-qemu-stream-capture.patch` adds the other end to Sunshine:

- `src/platform/linux/qemugrab.cpp` connects to the socket, imports the
  dmabuf through EGL and hands it to Sunshine's CUDA/NVENC encoder, the same
  way Sunshine's own KMS capture does. It draws the cursor from QEMU's cursor
  messages.
- Keyboard and mouse from Moonlight go back over the socket instead of to
  `uinput`, which a container doesn't have. The web UI therefore doesn't ask
  for input permissions.
- `src/platform/linux/qemuaudio.cpp` takes the sound from the container's
  audio relay (`WINBOX_AUDIO_SOCKET`, which upstream starts with `AUDIO=Y`):
  QEMU's sound card output as raw 48 kHz stereo samples. There is no
  PulseAudio in the container. QEMU writes the samples in bursts of about
  21 ms, and late ones while its main loop is busy with GPU work, so the
  source plays them from a 60 ms buffer on a steady clock and sends silence
  while Windows plays nothing. Surround clients get the stereo in the front
  left and right channels.
- The web UI trusts requests from its own address. Sunshine's protection
  against cross-site requests only knows `localhost`, but WinBox's web UI is
  opened through the container's mapped port at an address Sunshine can't
  know. A request still has to come from a page on the same address it is
  sent to (Origin or Referer matches the Host header).
- The sources are picked automatically when `WINBOX_STREAM_SOCKET` is set.

Not done yet: game controllers, and changing the Windows resolution to match
the Moonlight client.

## Build

The root `Dockerfile` builds Sunshine at a pinned commit (`SUNSHINE_REF`) on
Debian trixie, the same release as the WinBox image, packages it as a `.deb`
and installs that into the image.

It uses CUDA 12.9 from NVIDIA's Debian 12 repository, not CUDA 13, because
CUDA 13 can no longer build for Pascal GPUs (GTX 10-series, Quadro P). CUDA
12's headers need a small `noexcept` fix to compile against trixie's glibc;
Sunshine applies the same fix in its own build script.

## Updating Sunshine

A new Sunshine release changes nothing until it is built. To build the newest
release with the WinBox changes, open Actions > Build > Run workflow, tick
"Build the newest Sunshine release instead of the pinned one", and run it on
`main` (publishes `edge`) or on the newest `v…` tag (republishes `latest`).
If the patch no longer applies to the new release, the build fails and the
published image stays as it was. To make it permanent, update `SUNSHINE_REF`
in the `Dockerfile`.
