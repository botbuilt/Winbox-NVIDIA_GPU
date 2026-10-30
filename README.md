# WinBox NVIDIA GPU

**Windows in a box with an NVIDIA GPU.** Windows 10/11 (or Server) in a
Docker container on Unraid, with persistent storage on your shares and an
NVIDIA card that **stays shared** with Unraid and your other containers
(Plex, Jellyfin, AI apps, ...). No GPU passthrough, no VFIO binding.

- **DirectX 11 in Windows on the GPU**, through the Triton driver.
- **Moonlight streaming encoded on the GPU.** Sunshine runs in the
  container and encodes Windows' screen with NVENC (built with CUDA 12), so
  Windows spends no CPU time on capturing and encoding the stream.
- Installs Windows by itself, with Remote Desktop, a browser console, an
  Unraid share as drive Z:, backups and snapshots.

> **Built with AI.** The code, scripts, patches and docs in this repository
> were written by an AI coding assistant, directed and tested by the
> repository owner on their own server. The heavy lifting is other people's
> work: see [Credits](#credits).

> **Experimental.** Triton itself is described by its authors as very
> unstable. Expect crashes, GPU resets and games that don't work. Keep
> backups of anything important inside Windows.

## What's in here

| Part | What it does |
|---|---|
| Container (`Dockerfile`, `src/`) | [dockurr/windows](https://github.com/dockur/windows) (runs Windows in QEMU/KVM inside the container and installs it automatically) plus an Unraid startup hook that checks the shared GPU setup and explains any missing setting |
| Host GPU stack (`qemu-triton/`) | QEMU, virglrenderer and DXVK with [Triton](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/) support, built from pinned upstream commits with a few fixes for Nvidia and Linux |
| Streaming (`sunshine/`) | [Sunshine](https://github.com/LizardByte/Sunshine) with a capture source that takes Windows' screen straight from QEMU and encodes it with NVENC, for [Moonlight](https://moonlight-stream.org/) |
| Windows driver (`driver/`) | A GitHub Actions build of the Triton guest driver, test-signed, with fixes for 32-bit games and Remote Desktop |
| Unraid extras (`unraid/`, `scripts/`) | Community Applications template, backup, snapshot and clean-shutdown User Scripts |

## How it works

The GPU is **not** bound to the container or to VFIO. Unraid's Nvidia driver
keeps owning it, and the container gets access the same way Plex does
(`--runtime=nvidia`). Windows sees a virtio GPU. Its Triton driver sends
Direct3D 11 calls to the host, where DXVK runs them on your card through
Vulkan.

With streaming on (`STREAM=Y`), QEMU hands each finished Windows frame to
Sunshine in the container as a GPU buffer, without a copy through RAM.
Sunshine encodes it on the same card with NVENC and sends it to Moonlight,
and Moonlight's keyboard and mouse go straight back into the VM. Nothing
needs to be installed in Windows for it.

What to expect:

- DirectX 11 (feature level 11_1) for games and apps, a GPU-accelerated
  desktop, browsers and video. 64-bit and 32-bit games.
- **No DirectX 12** (Triton's DirectX 12 support is still early), no Nvidia
  driver inside Windows (no CUDA, NVENC or DLSS for Windows programs), and
  the driver needs Windows test mode, which some anti-cheat games refuse.
  CUDA and NVENC are used by the container, for streaming.
- The desktop feels less snappy than on real hardware, and every program
  that uses the GPU gets its own helper process on the host. Plan memory
  for that (see [Memory](#memory)).
- Tested on a Pascal-generation NVIDIA Quadro card. Newer NVIDIA cards
  should work. Intel and AMD may work for DirectX but are untested, and
  streaming needs NVIDIA.

## Requirements

| What | Why |
|---|---|
| Intel VT-x / AMD-V on in the BIOS | KVM |
| Unraid **7.3+** (Linux 6.13+) | virtio-gpu host memory blobs |
| **Nvidia Driver** plugin, driver **570.86+**, `nvidia_drm` modesetting on | Vulkan, GBM and dma-buf sharing on the host |
| A cache/SSD pool for the vdisk | Performance |
| An NVIDIA GPU, GTX 900 / Quadro M series or newer | DirectX 11 on the GPU and NVENC streaming (see [NVIDIA GPUs and CUDA](#nvidia-gpus-and-cuda)) |
| A valid Windows license | WinBox downloads Windows from Microsoft; it contains no Windows code |

## Setup on Unraid

### 1. Prepare the Nvidia driver (one time)

1. **Apps** → install **Nvidia Driver** (by ich777). Pick the latest production
   driver; RTX 50-series cards need the open-source driver.
2. Turn on modesetting. In the Unraid terminal:
   ```bash
   echo "options nvidia_drm modeset=1" > /boot/config/modprobe.d/nvidia-drm.conf
   ```
3. Reboot Unraid, then check:
   ```bash
   cat /sys/module/nvidia_drm/parameters/modeset   # should print Y
   ls /dev/dri                                     # should list renderD128 (or 129, ...)
   nvidia-smi                                      # driver 570.86 or newer
   ```
4. Copy the GPU UUID (`GPU-…`) from **Plugins → Nvidia Driver**. Your other
   containers keep using the same UUID; nothing changes for them.

### 2. Install the template

In the Unraid terminal:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/my-WinBox.xml \
  https://raw.githubusercontent.com/botbuilt/Winbox-NVIDIA_GPU/main/unraid/winbox.xml
```

Then **Docker → Add Container → Template: WinBox**.

### 3. Fill in the template

| Field | Set to |
|---|---|
| Windows version | `11` (or `10`, `11l` LTSC, `2025` Server, ...) |
| Username / Password | Your choice. The password is required and also protects the web console. |
| RAM / CPU cores / System disk size | e.g. `8G` / `4` / `128G` (see [Memory](#memory)) |
| Windows storage | `/mnt/cache/domains/windows`: the pool path, not `/mnt/user/...` (see Storage) |
| Shared folder (Z:) | Any share, e.g. `/mnt/user/windows-share` |
| GPU acceleration | `Y` |
| Nvidia GPU UUID | The `GPU-…` value from step 1 |
| Moonlight streaming | `Y` to stream with Moonlight (see [Streaming with Moonlight](#streaming-with-moonlight)), else `N` |

**Extra Parameters** (Advanced view) is already
`--runtime=nvidia --device=/dev/dri --cap-add=NET_ADMIN --stop-timeout=120 --memory=16g --memory-swap=16g`
plus two read-only mounts of the host's Nvidia GBM driver
(`/usr/lib64/libnvidia-allocator.so.1` and `/usr/lib64/libnvidia-egl-gbm.so.1`).
Unraid's Nvidia runtime doesn't add those to containers, and QEMU needs them
to render on the card. If you made the container from an older template, add:

```
-v /usr/lib64/libnvidia-allocator.so.1:/run/nvidia-host/libnvidia-allocator.so.1:ro -v /usr/lib64/libnvidia-egl-gbm.so.1:/run/nvidia-host/libnvidia-egl-gbm.so.1:ro
```

Click **Apply**.

### 4. First boot

Open the WebUI (`http://<unraid-ip>:8006`). The container downloads Windows
from Microsoft and installs it unattended, which takes about 15–40 minutes. When
you see the desktop it's done. After that, use **Remote Desktop** to
`<unraid-ip>:3389` for a much better experience, with clipboard and sound.

To confirm the GPU is in use, look at the container log: it should show
`Hardware rendering enabled` followed by your Nvidia card and driver version.
`nvidia-smi` on Unraid will list the QEMU process while Windows is running.

Windows starts with only a basic display. Install the Triton driver next.

### 5. Install the Triton driver in Windows

Two choices:

- **This repo's build (recommended).** Download the newest
  `triton-driver-*.zip` from [Releases](../../releases). It adds the fixes
  listed in [driver/README.md](driver/README.md) (32-bit games, Direct3D in
  Remote Desktop) but is test-signed:
  1. In an admin Command Prompt in Windows: `bcdedit -set TESTSIGNING ON`,
     then reboot. Secure Boot must be off.
  2. Unzip the package, run `install.cmd` as administrator, and reboot.
- **The upstream signed driver.** `viogpu3d-x64-signed.zip` from
  [osy/kvm-guest-drivers-windows v0.4](https://github.com/osy/kvm-guest-drivers-windows/releases/tag/v0.4).
  No test mode needed, but without the fixes above.

Check with `dxdiag`: the *VirtIO GPU 3D controller* should list feature
level `11_1`.

### 6. Make shutdown safe (important)

When a container stops, WinBox asks Windows to shut down and waits up to
105 seconds. But **Unraid stops containers with its own timeout, 10 seconds by
default**, ignoring `--stop-timeout`. That kills Windows mid-shutdown, which
can corrupt the disk. Do both:

1. **Settings → Docker** (Advanced view; stop the Docker service to edit) →
   **Docker Stop Timeout** = `120`.
2. Install the **User Scripts** plugin, add a script with the contents of
   [`scripts/winbox-array-stop.sh`](scripts/winbox-array-stop.sh), and set it
   to run **At Stopping of Array**.

WinBox reads Unraid's Docker settings (the read-only "Unraid Docker settings"
path in the template) and warns in the log on every start while the timeout is
too short. It stays quiet once it's long enough.

## Security

- **Password:** WinBox refuses to start with an empty or default password
  (`admin`, `change-me`, ...). The same password protects the web console
  (`PROTECT=Y`).
- **Don't expose ports 3389, 8006 or Sunshine's ports (47984-48010) to the
  internet.** RDP is a top target for
  brute-force attacks. For remote access use Tailscale, WireGuard (built into
  Unraid under Settings → VPN Manager), or a reverse proxy with SSO in front of
  the web console.
- **Keep Windows updated** like any PC; Windows Update works normally inside.
- **Images are signed.** Each published image is signed with Sigstore cosign
  and ships an SBOM and build provenance. To verify:
  ```bash
  cosign verify ghcr.io/botbuilt/winbox-nvidia-gpu:latest \
    --certificate-identity-regexp 'https://github.com/botbuilt/Winbox-NVIDIA_GPU/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
  ```
  Vulnerability scan results (Trivy) are in the repo's Security tab.

## Memory

Three things use host RAM, and only the first is `RAM_SIZE`:

1. Windows itself (`RAM_SIZE`).
2. The GPU memory window (`VRAM_SIZE`, 4G by default).
3. One helper process (`virgl-<n>-…`, started by `virgl_render_server`) for
   every Windows program that uses the GPU. Windows 11 has 15-25 of those on a normal desktop
   (Explorer, Start, Search, Edge and every WebView app), and a Remote
   Desktop session adds its own set.

Windows only grows into `RAM_SIZE` as it runs, and a helper is added for
every program that starts using the GPU (often 300-500 MB each), so a setup
that is too big works for a while and then fails. If everything adds up to more than the
server has, Linux kills the biggest process, which is Windows (`dmesg` shows
`Out of memory: Killed process … (windows)`), or Unraid itself can freeze.
The template therefore caps the whole container with
`--memory=16g --memory-swap=16g`. If the cap is hit, only WinBox is killed
(the log shows `Killed` / "QEMU exited unexpectedly") and Unraid stays up.

To size it, stop WinBox and look at the `available` column of `free -h`:
that is what the server can spare. Keep the cap a little below it, and
`RAM_SIZE` about 8G below the cap. On a 32 GB server with a dozen other
containers, that is typically `RAM_SIZE=8G` with a `16g` cap.

To see what the helpers use (proportional memory, so libraries they share
are counted once):

```bash
for p in $(pgrep virgl); do awk '/^Pss:/ {print $2}' /proc/$p/smaps_rollup; done | awk '{s+=$1} END {print NR " helpers, " int(s/1024) " MB"}'
```

Fewer helpers: turn off Widgets, Edge "Startup boost" and "Continue running
background apps", unneeded startup apps, and sign out of Remote Desktop
instead of only disconnecting.

## Streaming with Moonlight

With **Moonlight streaming** (`STREAM=Y`), Sunshine starts in the container
next to Windows. Moonlight on a PC, phone, TV or tablet then streams the
Windows desktop and games, with the video encoded by the NVIDIA card.

1. In the template set **GPU acceleration** = `Y`, **Moonlight streaming** =
   `Y`, and leave **Sound** at `Y` (that carries the sound to Moonlight).
   The Sunshine ports (TCP 47984, 47989, 47990, 48010 and UDP 47998-48000)
   are in the template's Advanced view; keep them mapped to the same numbers.
2. Open Sunshine's web UI at `https://<unraid-ip>:47990` (accept the
   self-signed certificate). Its login starts out as the template's
   username and password.
3. In Moonlight, add the host by `<unraid-ip>`, pick it, and enter the PIN it
   shows on Sunshine's **PIN** page. Then start **Desktop**.

Good to know:

- Sunshine's settings, pairings and login live in `<storage>/sunshine`, so
  they survive container updates. Its log is `/var/log/sunshine.log` in the
  container (`docker exec WinBox tail -50 /var/log/sunshine.log`).
- Don't also run Sunshine inside Windows: with `STREAM=Y` the container
  takes its ports.
- For games that turn the camera with the mouse, Moonlight sends relative
  mouse moves; on the desktop it sends absolute ones. If a game's mouse
  feels slow, raise the in-game sensitivity.
- Windows' screen size isn't changed to match the Moonlight client yet. Set
  it in Windows' display settings. For 120 fps streams, give Windows a 120 Hz
  monitor with `VGA=virtio-vga-gl,neptune=true,refresh_rate=120`.
- Moonlight has no clipboard sharing. Use Remote Desktop when you need it.
- With user-mode networking (`NETWORK=user`, for example behind a VPN
  container), Sunshine's ports are removed from `USER_PORTS` automatically
  so they reach Sunshine and not Windows.
- Each stream uses one NVENC session on the card. GeForce cards allow a
  limited number of sessions at once, shared with Plex or Jellyfin
  transcodes; Quadro and RTX professional cards don't have that limit.

## NVIDIA GPUs and CUDA

| | |
|---|---|
| Host driver | **570.86 or newer** (Nvidia Driver plugin), for Vulkan, GBM and dma-buf sharing |
| Pascal (GTX 10-series, Quadro P), Maxwell, Volta | Stay on the **R580** driver branch: NVIDIA's newer drivers drop these cards |
| Turing (RTX 20 / GTX 16) and newer | Any current production driver |
| RTX 50-series | The open-source driver flavour in the Nvidia Driver plugin |

**CUDA 12, not 13.** Windows itself gets no CUDA (it has no NVIDIA driver,
only the Triton virtual GPU). CUDA is used inside the container, where
Sunshine converts and hands frames to the NVENC encoder. It is built with
CUDA 12.9 because CUDA 13 dropped Maxwell, Pascal and Volta cards, so a
CUDA 13 build would not stream on a GTX 10-series or Quadro P card. CUDA 12
code runs on newer cards and drivers too, so nothing is lost on an RTX card.
The CUDA version on the host doesn't matter; only the driver version does.

## Remote Desktop

- With this repo's driver, programs in an RDP session can use the GPU when
  the policy **Use hardware graphics adapters for all Remote Desktop
  Services sessions** is enabled (`gpedit.msc` > Computer Configuration >
  Administrative Templates > Windows Components > Remote Desktop Services >
  Remote Desktop Session Host > Remote Session Environment). Set it to
  Disabled for a lighter, software-rendered RDP desktop when you don't need
  the GPU there.
- With the upstream driver, RDP can't use the GPU. Also turn off automatic
  sign-in and sign out of the web console before connecting, or the RDP
  session can end up with a dead taskbar.
- For game streaming, use [Moonlight](#streaming-with-moonlight). Sunshine
  installed inside Windows works too (with `STREAM=N`), but then Windows
  captures and encodes the stream on its own CPU cores.

## Backups

[`scripts/winbox-backup.sh`](scripts/winbox-backup.sh) is a User Scripts
script that shuts Windows down cleanly, copies the storage folder (disk image,
UEFI and TPM state) to `/mnt/user/backups/winbox/<date>`, starts Windows again,
and keeps the newest 3 backups. Downtime is only the copy. Copies are sparse,
so only the used part of the disk takes space. Edit the settings at the top
and schedule it weekly.

To restore, stop the container, copy the files from one backup folder into
the storage folder, and start it.

## Snapshots

[`scripts/winbox-snapshot.sh`](scripts/winbox-snapshot.sh) takes restore
points, for example before a Windows feature update or installing something
risky. Run it from the Unraid terminal, or add it to User Scripts and use
**Run Script** with arguments:

```bash
winbox-snapshot.sh create before-update   # shut down, snapshot, start again
winbox-snapshot.sh list
winbox-snapshot.sh restore 20261022-071200-before-update
winbox-snapshot.sh delete 20261022-071200-before-update
```

- Snapshots live in `<storage>/snapshots`. On a **btrfs, xfs or zfs** pool
  they are copy-on-write, so they are instant and only take space as Windows
  changes afterwards. On other filesystems they are full (sparse) copies.
- Windows is shut down for a moment while a snapshot is taken, so every
  snapshot is consistent. A running Windows can't be snapshotted with its
  memory, because the shared GPU can't be saved.
- **Restore** first saves the current state as a `…-before-restore` snapshot,
  so a restore can be undone too.
- Snapshots sit on the same pool as Windows, so they don't protect against a
  failed drive. Use [backups](#backups) for that. Backups skip snapshots.
- `KEEP=10` at the top of the script keeps only the newest 10.

## Updates and versions

| Tag | What |
|---|---|
| `latest` | Newest release. Use this in Unraid. |
| `1`, `1.2`, `1.2.3` | Pin a major, minor or exact release |
| `edge` | Every commit to `main`. Not for daily use. |

The `dockurr/windows` base is pinned by digest. Dependabot opens a PR for each
new upstream release; CI then runs the tests and a real KVM boot before
anything is published. Releases are cut by pushing a `vX.Y.Z` git tag. Changes
are listed in [CHANGELOG.md](CHANGELOG.md).

Updating the container never touches your Windows disk: the image only holds
QEMU, Sunshine and scripts, and Windows lives in `/storage`.

Sunshine is pinned to one release too. To build the newest Sunshine release
with WinBox's capture source, open **Actions > Build > Run workflow**, tick
"Build the newest Sunshine release instead of the pinned one", and run it on
`main` (publishes `edge`) or on the newest `v…` tag (republishes `latest`).
If the patch no longer fits the new release, the build fails and the
published image stays as it was.

## Storage

| Container path | Purpose |
|---|---|
| `/storage` | System disk image (`data.img`), firmware vars, and the ISO during install. Keep it on an SSD pool. |
| `/shared` | Shows up in Windows as the **Shared** desktop folder and drive **Z:** (Samba). Point it at any Unraid share. |
| `/storage2` + `DISK2_SIZE` | Optional second virtual disk (Advanced view). Up to `/storage6`. |
| `/custom.iso` | Optional: your own ISO; `VERSION` is ignored. |
| `/oem` | Optional: folder copied to `C:\OEM`; an `install.bat` inside runs at the end of setup. |

**Use the pool path for `/storage`**, e.g. `/mnt/cache/domains/windows`, not
`/mnt/user/domains/windows`. Both show the same files, but `/mnt/user` goes
through Unraid's FUSE share layer, which slows every disk access in Windows
(the log warns about this). Set the `domains` share to stay on the pool
(Primary storage: cache, Secondary: none) so the mover never moves the disk
image to the array.

To grow the system disk, raise `DISK_SIZE` and restart, then extend `C:` in
Disk Management.

A whole physical disk can be given to Windows by adding
`--device=/dev/disk/by-id/<disk>:/disk2` to Extra Parameters. Use an unassigned
disk only, never an array or pool member.

## USB devices

Find IDs with `lsusb` on the Unraid terminal, set **USB passthrough** to e.g.
`046d:c52b,1234:5678`, and add `--device=/dev/bus/usb` to Extra Parameters.
Plug USB *drives* in only after Windows is installed, or setup may format them.

## Alternative: dedicated GPU passthrough

Use this only if you need native Nvidia features in Windows. The card is then
**exclusive to Windows**: Plex and other containers lose it, and it can't
return to the host driver until reboot.

1. **Tools → System Devices**: tick the GPU and its audio device, click
   **Bind selected to VFIO at boot**, and reboot. Note the IOMMU group number.
2. In the template: **GPU acceleration** = `N`, **GPU passthrough** = the
   PCI address (e.g. `01:00.0`). The audio function is added automatically.
3. Replace Extra Parameters with:
   ```
   --device=/dev/vfio/vfio --device=/dev/vfio/<group> --cap-add=NET_ADMIN --cap-add=IPC_LOCK --ulimit memlock=-1:-1 --stop-timeout=120
   ```
4. Optional: **GPU is primary display** = `Y` if a monitor or dummy plug is
   attached (the web console turns off; use RDP, Parsec or Sunshine). Install
   the Nvidia driver inside Windows.

`PCI passthrough` takes other vfio-bound devices the same way (USB
controllers, NVMe). Memory ballooning is turned off automatically, since VFIO
pins all guest RAM.

## Troubleshooting

The startup hook stops with a clear message when something is missing:

| Message mentions | Fix |
|---|---|
| `needs Linux 6.13 or newer` | Update to Unraid 7.3+ |
| `no /dev/dri render node` | Add `--device=/dev/dri`; install the Nvidia Driver plugin |
| `Nvidia runtime is not set up` | Add `--runtime=nvidia` and set the GPU UUID |
| `NVIDIA_DRIVER_CAPABILITIES` | Set it to `all` |
| `Nvidia GBM driver is missing` / `gbm_create_device failed` | Add the two `/usr/lib64` mounts from step 3 |
| `modesetting is off` | Step 1.2 above, then reboot |
| `older than the 570.86 minimum` | Update the driver in the Nvidia Driver plugin |
| `STREAM=Y needs GPU=Y` | Streaming needs **GPU acceleration** = `Y` |
| Moonlight finds the host but can't connect | Map all Sunshine ports, TCP and UDP, to the same numbers; check `/var/log/sunshine.log` |
| No sound in Moonlight | Set **Sound** (`AUDIO`) to `Y` |
| Game says "software rendering" | Device Manager must show **VirtIO GPU 3D controller** with the Triton driver, and over RDP the GPU policy above must be on |
| `no completion in 30s, retiring as device-lost` | The GPU stopped answering and Windows reset it. Often memory: see [Memory](#memory) |
| `Memory allocation failed` / `Failed to import ... dmabuf` (Nvidia) | Don't pass `/dev/udmabuf` into the container; Nvidia can't import it. The warning `open /dev/udmabuf: No such file or directory` is expected and harmless |
| `Killed` / `QEMU exited unexpectedly` | The container hit its `--memory` cap; see [Memory](#memory) |
| Container stops after a while; `dmesg` shows `Out of memory: Killed process … (windows)` | Unraid ran out of RAM. Lower `RAM_SIZE` and the cap; see [Memory](#memory) |
| `KVM acceleration is not available` | Turn on VT-x/AMD-V in the BIOS |
| `PASSWORD is empty or a well-known default` | Set a real password in the template |
| Container shows **unhealthy** | QEMU stopped or the web console is down; check the log |
| `bound to '…', not vfio-pci` | Dedicated mode only: bind it under Tools → System Devices |

Everything else from upstream is available too. See the
[environment variables](https://github.com/dockur/windows/blob/master/docs/environment.md)
list and set them as template variables.

## Files

| Path | What |
|---|---|
| `Dockerfile` | Builds the Triton QEMU stack and Sunshine, then `dockurr/windows` (pinned by digest) + the hook, healthcheck, that QEMU and Sunshine |
| `qemu-triton/` | Patches for QEMU, virglrenderer and DXVK, see its [README](qemu-triton/README.md) |
| `sunshine/` | Sunshine patch for streaming from QEMU, see its [README](sunshine/README.md) |
| `driver/` | Windows guest driver patches and package files, see its [README](driver/README.md) |
| `src/start.sh` | Unraid startup hook (upstream sources `/run/start.sh` first) |
| `src/health.sh` | Container healthcheck |
| `scripts/` | Unraid User Scripts: backup, clean shutdown at array stop |
| `unraid/winbox.xml` | Community Applications template |
| `docker-compose.yml` | Same setup for Compose Manager |
| `tests/` | Hook, healthcheck and script tests (fake `/sys`, `/dev`, docker) |
| `.github/workflows/build.yml` | Tests, KVM boot test, then publishes a signed image with SBOM and a Trivy scan |
| `.github/workflows/driver.yml` | Builds and test-signs the Windows driver on a Windows runner |
| `.github/dependabot.yml` | Update PRs for the base image and actions |

## Credits

Almost everything that makes this work was written by others. This repo
packages it for Unraid and carries small fixes.

- [dockur/windows](https://github.com/dockur/windows) and
  [qemus/qemu](https://github.com/qemus/qemu): Windows in a container.
- [Triton / Neptune](https://blog.getutm.app/2026/introducing-triton-directx-11-driver-for-qemu/)
  by [osy](https://github.com/osy) and the [UTM](https://github.com/utmapp)
  team: the DirectX 11 driver design, guest driver and host side
  ([utmapp/qemu](https://github.com/utmapp/qemu),
  [utmapp/virglrenderer](https://github.com/utmapp/virglrenderer),
  [osy/dxvk](https://github.com/osy/dxvk),
  [osy/virtio-win-mesa](https://github.com/osy/virtio-win-mesa),
  [osy/kvm-guest-drivers-windows](https://github.com/osy/kvm-guest-drivers-windows)).
- [Sunshine](https://github.com/LizardByte/Sunshine) by LizardByte and
  [Moonlight](https://moonlight-stream.org/): game streaming. The
  container's streaming is Sunshine with one added capture source.
- [QEMU](https://www.qemu.org/), [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer),
  [DXVK](https://github.com/doitsujin/dxvk) and [Mesa](https://www.mesa3d.org/).
- The [virtio-win](https://github.com/virtio-win/kvm-guest-drivers-windows)
  drivers by Red Hat and contributors.

Please report bugs in Triton itself upstream, and bugs in this packaging or
these patches here.

## Legal

- This repository's own files are under the [MIT license](LICENSE), except
  the patches to other projects, which are under those projects' licenses
  (the Sunshine patch in `sunshine/patches` is GPL-3.0, like Sunshine). The
  image and the driver package also contain upstream software under its own
  licenses, among them QEMU (GPL-2.0), Sunshine (GPL-3.0), virglrenderer
  (MIT), DXVK (zlib), Mesa (MIT and others) and the virtio-win drivers
  (BSD-3-Clause). Their sources are the pinned upstream commits named in the
  `Dockerfile` and in `.github/workflows/driver.yml`, plus the patches in
  this repository.
- Sunshine is compiled with NVIDIA's CUDA 12.9 toolkit, as LizardByte's own
  Linux packages are. The image holds only the compiled Sunshine; the
  NVIDIA driver, CUDA driver library and NVENC come from the host's driver
  through the NVIDIA container runtime.
- The image contains no Windows code; it downloads Windows from Microsoft.
  You need a valid Windows license.
- Not affiliated with or endorsed by Microsoft, NVIDIA, Red Hat, Unraid
  (Lime Technology), LizardByte or the upstream projects. NVIDIA, CUDA and
  NVENC are trademarks of NVIDIA Corporation, used here only to say what
  hardware and software this works with. Provided as is, without
  warranty.
