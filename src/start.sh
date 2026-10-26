#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317  # variables are read by the sourcing entrypoint
set -Eeuo pipefail

# Unraid startup hook.
#
# The dockurr/windows entrypoint sources /run/start.sh before anything else,
# so this file replaces the empty upstream hook. It turns a few Unraid-friendly
# settings into QEMU arguments and checks the host before QEMU starts.
#
# Shared GPU (the GPU stays with Unraid and other containers):
#
#   GPU               Y = virtio-gpu 3D acceleration through /dev/dri (upstream)
#   RENDERNODE        Render node to use; picked automatically when empty
#
# Dedicated passthrough (the GPU is taken away from Unraid):
#
#   GPU_PASSTHROUGH   PCI addresses of a GPU bound to vfio-pci, e.g. "01:00.0"
#   PCI_PASSTHROUGH   Any other vfio-pci devices (USB controllers, NVMe, ...)
#   VFIO_GROUP        Y = also pass the other devices in the same IOMMU group
#   GPU_ROM           Path (inside the container) of a vBIOS ROM for the GPU
#   GPU_PRIMARY       Y = GPU is the only display, turns the web console off
#   USB_PASSTHROUGH   USB devices as "vendor:product", e.g. "046d:c52b"
#
# Safety:
#
#   ALLOW_WEAK_PASSWORD  Y = allow an empty or default PASSWORD (not recommended)
#
# Everything ends up appended to ARGUMENTS, which upstream passes to QEMU.

: "${GPU_PASSTHROUGH:=""}"
: "${PCI_PASSTHROUGH:=""}"
: "${VFIO_GROUP:="Y"}"
: "${GPU_ROM:=""}"
: "${GPU_PRIMARY:="N"}"
: "${USB_PASSTHROUGH:=""}"
: "${ARGUMENTS:=""}"
: "${GPU:="N"}"
: "${RENDERNODE:=""}"
: "${ALLOW_WEAK_PASSWORD:="N"}"

# Overridable so the hook can be tested against a fake /sys and /dev.
SYSFS="${VFIO_SYSFS:-/sys}"
DEVFS="${VFIO_DEVFS:-/dev}"
HOST_KERNEL="${HOOK_KERNEL:-$(uname -r)}"
LIBROOT="${HOOK_LIBROOT:-}"
HOSTLIBS="${HOOK_HOSTLIBS:-/run/nvidia-host}"
DOCKER_CFG="${HOOK_DOCKER_CFG:-/run/unraid/docker.cfg}"

hookInfo () { printf "%b%s%b" "\E[1;34m❯ \E[1;36m" "${1:-}" "\E[0m\n"; }
hookWarn () { printf "%b%s%b" "\E[1;31m❯ " "Warning: ${1:-}" "\E[0m\n" >&2; }
hookError () { printf "%b%s%b" "\E[1;31m❯ " "ERROR: ${1:-}" "\E[0m\n" >&2; exit 88; }

hookEnabled() {
  [[ "${1,,}" =~ ^(y|yes|true|1|on)$ ]]
}

# Accepts "1:00.0", "01:00.0" or "0000:01:00.0" and prints the full form.
normalizePci() {

  local addr="${1,,}"
  addr="${addr// /}"

  if [[ "$addr" =~ ^[0-9a-f]{1,2}:[0-9a-f]{1,2}\.[0-7]$ ]]; then
    addr="0000:$addr"
  fi

  if [[ ! "$addr" =~ ^([0-9a-f]{4}):([0-9a-f]{1,2}):([0-9a-f]{1,2})\.([0-7])$ ]]; then
    hookError "Invalid PCI address '$1', expected a format like 01:00.0 (see Tools > System Devices)."
  fi

  printf '%s:%02x:%02x.%s\n' "${BASH_REMATCH[1]}" \
    "$((16#${BASH_REMATCH[2]}))" "$((16#${BASH_REMATCH[3]}))" "${BASH_REMATCH[4]}"
}

pciGroup() {

  local link="$SYSFS/bus/pci/devices/$1/iommu_group"

  if [ ! -e "$link" ]; then
    hookError "PCI device $1 has no IOMMU group. Enable VT-d/AMD-Vi (IOMMU) in the BIOS and check Tools > System Devices."
  fi

  basename "$(readlink -f "$link")"
}

pciDriver() {

  local link="$SYSFS/bus/pci/devices/$1/driver"
  [ -e "$link" ] && basename "$(readlink -f "$link")" || echo ""
}

# PCI bridges share groups with endpoints but must stay with the host.
pciIsBridge() {

  local class
  class=$(cat "$SYSFS/bus/pci/devices/$1/class" 2>/dev/null) || return 1
  [[ "${class,,}" == 0x0604* ]]
}

# Builds the final, ordered list of devices to pass through.
collectDevices() {

  local raw addr dev group member
  local -a requested=()
  DEVICES=()
  GROUPS_USED=()

  for raw in ${GPU_PASSTHROUGH//,/ } ${PCI_PASSTHROUGH//,/ }; do
    requested+=("$(normalizePci "$raw")")
  done

  for addr in "${requested[@]}"; do

    if [ ! -e "$SYSFS/bus/pci/devices/$addr" ]; then
      hookError "PCI device $addr was not found on this host."
    fi

    group=$(pciGroup "$addr")
    [[ " ${GROUPS_USED[*]} " == *" $group "* ]] || GROUPS_USED+=("$group")
    [[ " ${DEVICES[*]} " == *" $addr "* ]] || DEVICES+=("$addr")

    hookEnabled "$VFIO_GROUP" || continue

    for member in "$SYSFS/kernel/iommu_groups/$group/devices/"*; do
      dev=$(basename "$member")
      [ -e "$member" ] || continue
      pciIsBridge "$dev" && continue
      [[ " ${DEVICES[*]} " == *" $dev "* ]] && continue
      hookInfo "Adding $dev, it shares IOMMU group $group with $addr."
      DEVICES+=("$dev")
    done

  done
}

checkVfio() {

  local dev driver group

  for dev in "${DEVICES[@]}"; do
    driver=$(pciDriver "$dev")
    if [[ "$driver" != "vfio-pci" ]]; then
      hookError "PCI device $dev is bound to '${driver:-no driver}', not vfio-pci. In Unraid go to Tools > System Devices, tick the device (and every device in its IOMMU group), click 'Bind selected to VFIO at boot' and reboot."
    fi
  done

  if [ ! -c "$DEVFS/vfio/vfio" ]; then
    hookError "/dev/vfio/vfio is not available in the container. Add it as a Device in the template (or enable Privileged)."
  fi

  for group in "${GROUPS_USED[@]}"; do
    if [ ! -c "$DEVFS/vfio/$group" ]; then
      hookError "/dev/vfio/$group (IOMMU group $group) is not available in the container. Add it as a Device in the template (or enable Privileged)."
    fi
  done

  # VFIO pins all guest memory, so the locked-memory limit has to cover it.
  local limit
  limit=$(ulimit -l)
  if [[ "$limit" != "unlimited" ]]; then
    hookWarn "The locked memory limit is ${limit} KB. If QEMU fails with 'VFIO_MAP_DMA' or 'cannot allocate memory', add '--ulimit memlock=-1:-1' to Extra Parameters."
  fi

  if hookEnabled "${BALLOONING:-N}"; then
    hookWarn "Memory ballooning does not work with PCI passthrough, disabling it."
  fi
  BALLOONING="N"
}

# Functions of one physical card (01:00.0, 01:00.1, ...) are placed behind a
# single PCIe root port with the same function numbers they have on the host,
# which is what the Nvidia and AMD Windows drivers expect.
buildPciArgs() {

  local dev slot func port id opts
  local -A ports=()
  local next=0
  local args=""
  local first_gpu=""

  [ -n "$GPU_PASSTHROUGH" ] && first_gpu=$(normalizePci "${GPU_PASSTHROUGH%%,*}")

  for dev in "${DEVICES[@]}"; do

    slot="${dev%.*}"
    func="${dev##*.}"

    if [ -z "${ports[$slot]:-}" ]; then
      port="vfioport$next"
      ports[$slot]="$port"
      args+=" -device pcie-root-port,id=$port,bus=pcie.0,chassis=$((100 + next)),slot=$((100 + next))"
      next=$((next + 1))
    fi

    port="${ports[$slot]}"
    id="vfio${dev//[:.]/}"
    opts="host=$dev,id=$id,bus=$port,addr=00.$func"

    [[ "$func" == "0" ]] && opts+=",multifunction=on"

    if [[ "$dev" == "$first_gpu" ]] && [ -n "$GPU_ROM" ]; then
      [ -r "$GPU_ROM" ] || hookError "GPU_ROM is set to '$GPU_ROM' but that file is not readable in the container."
      opts+=",romfile=$GPU_ROM"
    fi

    args+=" -device vfio-pci,$opts"
  done

  printf '%s' "${args# }"
}

buildUsbArgs() {

  local raw vendor product args=""

  for raw in ${USB_PASSTHROUGH//,/ }; do

    if [[ ! "${raw,,}" =~ ^(0x)?([0-9a-f]{4}):(0x)?([0-9a-f]{4})$ ]]; then
      hookError "Invalid USB device '$raw', expected vendor:product such as 046d:c52b (see 'lsusb' on the Unraid console)."
    fi

    vendor="${BASH_REMATCH[2]}"
    product="${BASH_REMATCH[4]}"
    args+=" -device usb-host,vendorid=0x$vendor,productid=0x$product"
  done

  if [ -n "$args" ] && [ ! -d "$DEVFS/bus/usb" ]; then
    hookError "USB_PASSTHROUGH is set but /dev/bus/usb is not available. Add /dev/bus/usb as a Device in the template."
  fi

  printf '%s' "${args# }"
}

# Windows needs virtio-gpu host blobs for Venus (Vulkan), added in Linux 6.13.
# Unraid 7.2 ships 6.12, Unraid 7.3 ships 6.18.
kernelSupportsBlobs() {

  local major minor
  [[ "$HOST_KERNEL" =~ ^([0-9]+)\.([0-9]+) ]] || return 0
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  (( major > 6 || (major == 6 && minor >= 13) ))
}

renderVendor() {
  cat "$SYSFS/class/drm/${1##*/}/device/vendor" 2>/dev/null || echo ""
}

# Prints the first Nvidia render node, if any.
nvidiaRenderNode() {

  local node
  for node in "$DEVFS"/dri/renderD*; do
    [ -e "$node" ] || continue
    [[ "$(renderVendor "$node")" == "0x10de" ]] || continue
    printf '%s\n' "$node"
    return 0
  done
  return 1
}

# The Nvidia runtime injects the driver's device nodes and libraries. Check
# for those rather than NVIDIA_VISIBLE_DEVICES: in CDI mode the toolkit sets
# that variable to "void" inside the container even when it worked.
nvidiaRuntimeInjected() {
  [ -c "$DEVFS/nvidiactl" ]
}

nvidiaGraphicsLibs() {
  compgen -G "$LIBROOT/usr/lib/*/libEGL_nvidia.so.*" >/dev/null \
    || compgen -G "$LIBROOT/usr/lib/libEGL_nvidia.so.*" >/dev/null \
    || compgen -G "$LIBROOT/usr/lib64/libEGL_nvidia.so.*" >/dev/null
}

# Unraid's Nvidia runtime adds the EGL libraries but not the GBM backend that
# QEMU's egl-headless display opens the render node with ("gbm_create_device
# failed"). The template mounts those two host files read-only at HOSTLIBS;
# link them where Mesa's libgbm and the EGL loader look.
nvidiaGbmLink() {

  local lib="$LIBROOT/usr/lib/x86_64-linux-gnu" name

  [ -e "$lib/gbm/nvidia-drm_gbm.so" ] && return 0
  [ -f "$HOSTLIBS/libnvidia-allocator.so.1" ] || return 1

  mkdir -p "$lib/gbm" || return 1
  for name in libnvidia-allocator.so.1 libnvidia-egl-gbm.so.1; do
    if [ -f "$HOSTLIBS/$name" ] && [ ! -e "$lib/$name" ]; then
      ln -sf "$HOSTLIBS/$name" "$lib/$name" || return 1
    fi
  done
  ln -sf ../libnvidia-allocator.so.1 "$lib/gbm/nvidia-drm_gbm.so" || return 1

  [ -z "$LIBROOT" ] && ldconfig 2>/dev/null
  return 0
}

# VGA=vmware gives Windows a VMware SVGA 3D adapter whose DirectX the host
# renders through DXVK on Vulkan. Unlike the virtio-gpu (Venus) path it
# needs no host blobs, GBM or modesetting, only Vulkan on the card.
vmwareMode() {
  [[ "${VGA:-}" =~ ^([Vv][Mm][Vv][Gg][Aa]|[Vv][Mm][Ww][Aa][Rr][Ee](-[Ss][Vv][Gg][Aa])?)(,|$) ]]
}

# Checks what upstream would otherwise report with less Unraid-specific advice.
sharedGpuCheck() {

  local node="" modeset=""

  if [ -n "${GPU_PASSTHROUGH// /}" ]; then
    hookError "GPU=Y (shared GPU) and GPU_PASSTHROUGH (dedicated GPU) cannot be used together. Clear one of them."
  fi

  if ! vmwareMode && ! kernelSupportsBlobs; then
    hookError "Shared GPU acceleration for Windows needs Linux 6.13 or newer, but this Unraid runs $HOST_KERNEL. Use VGA=vmware (works on older Unraid), update to Unraid 7.3 or newer, or set GPU=N."
  fi

  if ! compgen -G "$DEVFS/dri/renderD*" >/dev/null; then
    hookError "GPU=Y but no /dev/dri render node is in the container. Add '--device=/dev/dri' to Extra Parameters, and for Nvidia install the 'Nvidia Driver' plugin."
  fi

  # The Windows VMware driver probes the VMware backdoor port before it offers
  # DirectX 10/11. KVM refuses that port by default, and the driver then
  # silently stays at DirectX 9 (dxdiag shows feature levels 9_3).
  if vmwareMode && [[ "$(cat "$SYSFS/module/kvm/parameters/enable_vmware_backdoor" 2>/dev/null)" == "N" ]]; then
    hookWarn "KVM's VMware backdoor is off on the Unraid host, so Windows only gets DirectX 9. For DirectX 10/11 add 'kvm.enable_vmware_backdoor=1' to the append line in Main > Flash > Syslinux Configuration, then reboot Unraid."
  fi

  if [ -n "$RENDERNODE" ]; then
    [[ "$(renderVendor "$RENDERNODE")" == "0x10de" ]] && node="$RENDERNODE"
  else
    node=$(nvidiaRenderNode) || node=""
  fi

  # Not an Nvidia card: Intel and AMD work with Mesa inside the image.
  [ -z "$node" ] && return 0

  if ! nvidiaRuntimeInjected; then
    hookError "An Nvidia GPU was found at $node but the Nvidia runtime is not set up. Add '--runtime=nvidia' to Extra Parameters and set NVIDIA_VISIBLE_DEVICES to the GPU UUID from Plugins > Nvidia Driver."
  fi

  if ! nvidiaGraphicsLibs; then
    hookError "The Nvidia runtime is active but did not add the graphics libraries Windows rendering needs. Set NVIDIA_DRIVER_CAPABILITIES to 'all' (currently '${NVIDIA_DRIVER_CAPABILITIES:-}')."
  fi

  if ! vmwareMode && ! nvidiaGbmLink; then
    hookError "The Nvidia GBM driver is missing in the container (Unraid's Nvidia runtime does not add it). Add to Extra Parameters: -v /usr/lib64/libnvidia-allocator.so.1:$HOSTLIBS/libnvidia-allocator.so.1:ro -v /usr/lib64/libnvidia-egl-gbm.so.1:$HOSTLIBS/libnvidia-egl-gbm.so.1:ro"
  fi

  modeset=$(cat "$SYSFS/module/nvidia_drm/parameters/modeset" 2>/dev/null || echo "")
  if ! vmwareMode && [[ "${modeset^^}" != "Y" && "$modeset" != "1" ]]; then
    hookError "nvidia-drm modesetting is off on the Unraid host. Run: echo 'options nvidia_drm modeset=1' > /boot/config/modprobe.d/nvidia-drm.conf  then reboot Unraid."
  fi

  # Upstream only says "Vulkan device enumeration failed" and drops the
  # details, so show what the Vulkan loader and Nvidia driver reported.
  local vk=""
  if command -v vulkaninfo >/dev/null && ! vk=$(vulkaninfo --summary 2>&1); then
    hookWarn "vulkaninfo could not use the Nvidia GPU. Its last lines were:"
    printf '%s\n' "$vk" | tail -n 15 >&2
  fi

  # When the host also has an iGPU, make sure upstream picks the Nvidia card.
  if [ -z "$RENDERNODE" ]; then
    RENDERNODE="/dev/dri/${node##*/}"
    hookInfo "Using the Nvidia GPU at $RENDERNODE for shared acceleration."
  fi
}

# PASSWORD is the Windows account and, with PROTECT=Y, the web console
# password. Refuse the well-known defaults so a fresh install is never
# reachable over RDP or the web with admin/admin.
passwordCheck() {

  local pass="${PASSWORD:-}"

  hookEnabled "$ALLOW_WEAK_PASSWORD" && return 0

  case "${pass,,}" in
    "" | "admin" | "change-me" | "changeme" | "password" | "docker" )
      hookError "PASSWORD is empty or a well-known default. Set a real password in the template (it becomes the Windows and web console password), or set ALLOW_WEAK_PASSWORD=Y to accept the risk." ;;
  esac

  return 0
}

# Unraid stops containers with its own timeout (Settings > Docker > Docker
# Stop Timeout, default 10 seconds), which ignores --stop-timeout and kills
# Windows before it can shut down cleanly. The template mounts Unraid's
# docker.cfg so the actual value can be checked; otherwise just remind.
stopTimeoutNotice() {

  local need=$(( ${TIMEOUT:-105} + 15 )) cur=""

  if [ -f "$DOCKER_CFG" ]; then
    cur=$(sed -n 's/^DOCKER_TIMEOUT="\{0,1\}\([0-9]*\)"\{0,1\}[[:space:]]*$/\1/p' "$DOCKER_CFG" | tail -n 1)
    cur="${cur:-10}"
    if (( cur < need )); then
      hookWarn "Unraid's Docker Stop Timeout is ${cur}s, so stopping or updating this container kills Windows ${cur}s into its shutdown, which can corrupt it. Set Settings > Docker > Docker Stop Timeout to $need or more."
    fi
    return 0
  fi

  [[ "${HOST_OS:-}" == "Unraid" ]] || return 0
  hookInfo "Unraid: set Settings > Docker > Docker Stop Timeout to $need or more so Windows can shut down cleanly (see README)."
}

unraidHook() {

  local extra=""

  passwordCheck
  stopTimeoutNotice

  if hookEnabled "$GPU"; then
    sharedGpuCheck
  elif [[ "${VGA:-}" == *gl* ]]; then
    # The image defaults to Triton's virtio-vga-gl, which needs the shared
    # GPU. Without it, fall back to a plain virtio display.
    VGA="virtio"
    hookInfo "GPU acceleration is off, so Windows gets a plain virtio display (no DirectX on the GPU)."
  fi

  if [ -n "${GPU_PASSTHROUGH// /}${PCI_PASSTHROUGH// /}" ]; then

    collectDevices
    checkVfio
    extra+=" $(buildPciArgs)"

    hookInfo "Passing through PCI devices: ${DEVICES[*]}"

    if hookEnabled "$GPU_PRIMARY"; then
      # The passed-through GPU drives a physical monitor. Without an emulated
      # adapter Windows has nothing else to fall back to, so use RDP or a
      # streaming app (Parsec, Sunshine) for remote access.
      VGA="none"
      DISPLAY="none"
      hookInfo "GPU_PRIMARY is enabled, the web console is turned off."
    fi
  fi

  if [ -n "${USB_PASSTHROUGH// /}" ]; then
    extra+=" $(buildUsbArgs)"
    hookInfo "Passing through USB devices: ${USB_PASSTHROUGH}"
  fi

  extra="${extra# }"
  if [ -n "$extra" ]; then
    ARGUMENTS="${ARGUMENTS:+$ARGUMENTS }$extra"
  fi

  return 0
}

# Only run when sourced by the entrypoint, so tests can load the functions.
if [[ "${UNRAID_HOOK_TEST:-N}" != "Y" ]]; then
  unraidHook
fi

return 0 2>/dev/null || exit 0
