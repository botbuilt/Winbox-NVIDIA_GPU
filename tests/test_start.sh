#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# Tests the Unraid startup hook against a fake /sys and /dev.
# Usage: bash tests/test_start.sh
set -uo pipefail

HOOK="$(cd "$(dirname "$0")/.." && pwd)/src/start.sh"
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

PASS=0
FAIL=0

# addDevice <address> <iommu group> <driver or ""> <class>
addDevice() {
  local dir="$FAKE/sys/bus/pci/devices/$1"
  mkdir -p "$dir" "$FAKE/sys/kernel/iommu_groups/$2/devices" "$FAKE/sys/bus/pci/drivers"
  ln -s "../../../../kernel/iommu_groups/$2" "$dir/iommu_group"
  ln -s "$dir" "$FAKE/sys/kernel/iommu_groups/$2/devices/$1"
  printf '%s\n' "$4" > "$dir/class"
  if [ -n "$3" ]; then
    mkdir -p "$FAKE/sys/bus/pci/drivers/$3"
    ln -s "$FAKE/sys/bus/pci/drivers/$3" "$dir/driver"
  fi
}

# Character devices are faked with symlinks to /dev/null.
addDev() {
  mkdir -p "$(dirname "$FAKE/dev/$1")"
  ln -s /dev/null "$FAKE/dev/$1"
}

addDevice 0000:00:01.0 12 pcieport   0x060400   # bridge, must be skipped
addDevice 0000:01:00.0 12 vfio-pci   0x030000   # GPU
addDevice 0000:01:00.1 12 vfio-pci   0x040300   # GPU audio
addDevice 0000:02:00.0 13 xhci_hcd   0x0c0330   # USB controller, not bound
addDevice 0000:03:00.0 14 vfio-pci   0x010802   # NVMe
addDev vfio/vfio
addDev vfio/12
addDev vfio/14
mkdir -p "$FAKE/dev/bus/usb"

# runHook <env assignments...>: prints ARGUMENTS/VGA/DISPLAY/BALLOONING, or the error
runHook() {
  env -i PATH="$PATH" VFIO_SYSFS="$FAKE/sys" VFIO_DEVFS="$FAKE/dev" HOOK_KERNEL=6.18.38-Unraid HOOK_LIBROOT="$FAKE/root" HOOK_HOSTLIBS="$FAKE/host" HOOK_DOCKER_CFG="$FAKE/docker.cfg" PASSWORD=s3cret-Pass "$@" \
    bash -c 'ulimit -l unlimited 2>/dev/null; source "$0" || exit $?
             printf "ARGS=%s\nVGA=%s\nDISPLAY=%s\nBALLOONING=%s\n" \
               "$ARGUMENTS" "${VGA:-}" "${DISPLAY:-}" "${BALLOONING:-}"
             printf "RENDERNODE=%s\n" "${RENDERNODE:-}"' "$HOOK" 2>&1
}

expect() {
  local name="$1" output="$2" pattern="$3"
  if grep -qF -- "$pattern" <<< "$output"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: %s\n  output:\n%s\n' "$name" "$pattern" "$output"
  fi
}

expectNot() {
  local name="$1" output="$2" pattern="$3"
  if grep -qF -- "$pattern" <<< "$output"; then
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  did not expect: %s\n  output:\n%s\n' "$name" "$pattern" "$output"
  else
    PASS=$((PASS + 1))
  fi
}

out=$(runHook)
expect "no settings leaves ARGUMENTS empty" "$out" "ARGS="$'\n'
expect "no settings leaves ARGUMENTS empty" "$out" "VGA="$'\n'

# The image defaults to Triton's virtio-vga-gl, which needs the shared GPU.
out=$(runHook GPU=N VGA=virtio-vga-gl,neptune=true)
expect "no shared GPU falls back to plain virtio" "$out" "VGA=virtio"$'\n'
out=$(runHook GPU=N VGA=vmware)
expect "other VGA types are kept without a GPU" "$out" "VGA=vmware"

out=$(runHook GPU_PASSTHROUGH=01:00.0)
expect "gpu gets a root port" "$out" "-device pcie-root-port,id=vfioport0,bus=pcie.0,chassis=100,slot=100"
expect "gpu function 0 is multifunction" "$out" "-device vfio-pci,host=0000:01:00.0,id=vfio000001000,bus=vfioport0,addr=00.0,multifunction=on"
expect "audio function joins the same port" "$out" "-device vfio-pci,host=0000:01:00.1,id=vfio000001001,bus=vfioport0,addr=00.1"
expectNot "bridge is skipped" "$out" "host=0000:00:01.0"
expectNot "only one root port for one card" "$out" "vfioport1"
expect "ballooning forced off" "$out" "BALLOONING=N"
expect "console stays on by default" "$out" "VGA="$'\n'

out=$(runHook GPU_PASSTHROUGH=01:00.0 VFIO_GROUP=N)
expectNot "VFIO_GROUP=N skips group members" "$out" "host=0000:01:00.1"

out=$(runHook GPU_PASSTHROUGH="0000:01:00.0, 0000:01:00.1" PCI_PASSTHROUGH=3:0.0 ARGUMENTS="-foo bar")
expect "existing ARGUMENTS kept first" "$out" "ARGS=-foo bar -device pcie-root-port"
expect "second card gets its own port" "$out" "-device vfio-pci,host=0000:03:00.0,id=vfio000003000,bus=vfioport1,addr=00.0,multifunction=on"
expect "short addresses are normalized" "$out" "id=vfioport1,bus=pcie.0,chassis=101,slot=101"

out=$(runHook GPU_PASSTHROUGH=01:00.0 GPU_PRIMARY=Y)
expect "GPU_PRIMARY disables VGA" "$out" "VGA=none"
expect "GPU_PRIMARY disables console" "$out" "DISPLAY=none"

rom="$FAKE/gpu.rom"
echo rom > "$rom"
out=$(runHook GPU_PASSTHROUGH=01:00.0 GPU_ROM="$rom")
expect "ROM goes on the GPU" "$out" "addr=00.0,multifunction=on,romfile=$rom"
expectNot "ROM not on audio" "$out" "addr=00.1,romfile"

out=$(runHook GPU_PASSTHROUGH=01:00.0 GPU_ROM=/missing.rom); rc=$?
expect "missing ROM is an error" "$out" "GPU_ROM is set to '/missing.rom'"

out=$(runHook PCI_PASSTHROUGH=02:00.0); rc=$?
expect "unbound device is an error" "$out" "bound to 'xhci_hcd', not vfio-pci"
[[ $rc -eq 88 ]] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: exit code $rc, wanted 88"; }

out=$(runHook GPU_PASSTHROUGH=09:00.0)
expect "unknown device is an error" "$out" "PCI device 0000:09:00.0 was not found"

out=$(runHook GPU_PASSTHROUGH=banana)
expect "garbage address is an error" "$out" "Invalid PCI address 'banana'"

rm "$FAKE/dev/vfio/12"
out=$(runHook GPU_PASSTHROUGH=01:00.0)
expect "missing group device is an error" "$out" "/dev/vfio/12 (IOMMU group 12) is not available"
addDev vfio/12

out=$(runHook USB_PASSTHROUGH="046d:c52b,0x1234:0xABCD")
expect "usb device 1" "$out" "-device usb-host,vendorid=0x046d,productid=0xc52b"
expect "usb device 2" "$out" "-device usb-host,vendorid=0x1234,productid=0xabcd"

out=$(runHook USB_PASSTHROUGH="046d")
expect "bad usb id is an error" "$out" "Invalid USB device '046d'"

rmdir "$FAKE/dev/bus/usb"
out=$(runHook USB_PASSTHROUGH="046d:c52b")
expect "usb without /dev/bus/usb is an error" "$out" "/dev/bus/usb is not available"


# --- Shared GPU -------------------------------------------------------------

# addRender <node> <vendor>
addRender() {
  mkdir -p "$FAKE/sys/class/drm/$1/device" "$FAKE/dev/dri"
  echo "$2" > "$FAKE/sys/class/drm/$1/device/vendor"
  ln -s /dev/null "$FAKE/dev/dri/$1"
}

NV=(NVIDIA_VISIBLE_DEVICES=GPU-1234 NVIDIA_DRIVER_CAPABILITIES=all)

out=$(runHook GPU=Y "${NV[@]}")
expect "no render node is an error" "$out" "Add '--device=/dev/dri' to Extra Parameters"

addRender renderD128 0x8086
out=$(runHook GPU=Y)
expect "intel only passes through to upstream" "$out" "RENDERNODE="$'\n'
expectNot "intel only needs no nvidia runtime" "$out" "ERROR"

addRender renderD129 0x10de
mkdir -p "$FAKE/sys/module/nvidia_drm/parameters"
echo N > "$FAKE/sys/module/nvidia_drm/parameters/modeset"

out=$(runHook GPU=Y NVIDIA_VISIBLE_DEVICES=GPU-1234)
expect "nvidia without runtime is an error" "$out" "Add '--runtime=nvidia' to Extra Parameters"

# The runtime injects /dev/nvidiactl and the driver libraries.
addDev nvidiactl
out=$(runHook GPU=Y "${NV[@]}")
expect "runtime without graphics libs is an error" "$out" "did not add the graphics libraries"

mkdir -p "$FAKE/root/usr/lib/x86_64-linux-gnu"
touch "$FAKE/root/usr/lib/x86_64-linux-gnu/libEGL_nvidia.so.580.95.05"
out=$(runHook GPU=Y "${NV[@]}")
expect "missing GBM driver is an error" "$out" "-v /usr/lib64/libnvidia-allocator.so.1:"

# The template mounts the host's GBM files; the hook links them in.
mkdir -p "$FAKE/host"
touch "$FAKE/host/libnvidia-allocator.so.1" "$FAKE/host/libnvidia-egl-gbm.so.1"
out=$(runHook GPU=Y "${NV[@]}")
GBMLIB="$FAKE/root/usr/lib/x86_64-linux-gnu"
expect "GBM backend linked" "$(readlink "$GBMLIB/gbm/nvidia-drm_gbm.so")" "../libnvidia-allocator.so.1"
expect "allocator linked" "$(readlink "$GBMLIB/libnvidia-allocator.so.1")" "$FAKE/host/libnvidia-allocator.so.1"
expect "egl-gbm linked" "$(readlink "$GBMLIB/libnvidia-egl-gbm.so.1")" "$FAKE/host/libnvidia-egl-gbm.so.1"
expect "modeset off is an error" "$out" "options nvidia_drm modeset=1"

echo Y > "$FAKE/sys/module/nvidia_drm/parameters/modeset"
out=$(runHook GPU=Y "${NV[@]}")
expect "nvidia node picked over the iGPU" "$out" "RENDERNODE=/dev/dri/renderD129"
expectNot "nvidia setup passes" "$out" "ERROR"

# A failing vulkaninfo is shown, since upstream hides its output.
mkdir -p "$FAKE/bin"
printf '#!/bin/sh\necho "ERROR_INITIALIZATION_FAILED: fake driver"\nexit 1\n' > "$FAKE/bin/vulkaninfo"
chmod +x "$FAKE/bin/vulkaninfo"
out=$(PATH="$FAKE/bin:$PATH" runHook GPU=Y "${NV[@]}")
expect "vulkaninfo failure is shown" "$out" "ERROR_INITIALIZATION_FAILED: fake driver"
rm "$FAKE/bin/vulkaninfo"

# CDI mode: the toolkit rewrites NVIDIA_VISIBLE_DEVICES to void in the container.
out=$(runHook GPU=Y NVIDIA_VISIBLE_DEVICES=void NVIDIA_DRIVER_CAPABILITIES=all)
expectNot "CDI mode (void) is accepted" "$out" "ERROR"
out=$(runHook GPU=Y)
expectNot "no env vars but runtime injected is accepted" "$out" "ERROR"

out=$(runHook GPU=Y RENDERNODE=/dev/dri/renderD128)
expect "explicit intel node is kept" "$out" "RENDERNODE=/dev/dri/renderD128"
expectNot "explicit intel node needs no nvidia runtime" "$out" "ERROR"

out=$(runHook GPU=Y "${NV[@]}" HOOK_KERNEL=6.12.98-Unraid)
expect "old Unraid kernel is an error" "$out" "update to Unraid 7.3 or newer"

# VGA=vmware needs only Vulkan: no blob kernel, GBM or modesetting.
echo N > "$FAKE/sys/module/nvidia_drm/parameters/modeset"
mv "$FAKE/host" "$FAKE/host.off"
rm -f "$FAKE/root/usr/lib/x86_64-linux-gnu/gbm/nvidia-drm_gbm.so"
out=$(runHook GPU=Y "${NV[@]}" VGA=vmware HOOK_KERNEL=6.12.98-Unraid)
expectNot "vmware mode skips the virtio-only checks" "$out" "ERROR"
expect "vmware mode still picks the Nvidia node" "$out" "RENDERNODE=/dev/dri/renderD129"
mkdir -p "$FAKE/sys/module/kvm/parameters"
echo N > "$FAKE/sys/module/kvm/parameters/enable_vmware_backdoor"
out=$(runHook GPU=Y "${NV[@]}" VGA=vmware)
expect "vmware mode warns when the KVM backdoor is off" "$out" "kvm.enable_vmware_backdoor=1"
out=$(runHook GPU=Y "${NV[@]}")
expectNot "virtio mode ignores the KVM backdoor" "$out" "backdoor"
echo Y > "$FAKE/sys/module/kvm/parameters/enable_vmware_backdoor"
out=$(runHook GPU=Y "${NV[@]}" VGA=vmware)
expectNot "vmware mode is quiet when the KVM backdoor is on" "$out" "backdoor"
out=$(runHook GPU=Y "${NV[@]}" HOOK_KERNEL=6.12.98-Unraid)
expect "virtio mode on an old kernel suggests vmware" "$out" "Use VGA=vmware"
mv "$FAKE/host.off" "$FAKE/host"
echo Y > "$FAKE/sys/module/nvidia_drm/parameters/modeset"

out=$(runHook GPU=Y "${NV[@]}" GPU_PASSTHROUGH=01:00.0)
expect "shared and dedicated together is an error" "$out" "cannot be used together"

out=$(runHook GPU=N)
expectNot "GPU=N skips the checks" "$out" "ERROR"

# --- Password and Unraid notices ---------------------------------------------

for weak in "" admin Admin change-me password; do
  out=$(runHook PASSWORD="$weak")
  expect "weak password '$weak' is refused" "$out" "PASSWORD is empty or a well-known default"
done

out=$(runHook PASSWORD=admin ALLOW_WEAK_PASSWORD=Y)
expectNot "ALLOW_WEAK_PASSWORD=Y accepts it" "$out" "ERROR"

out=$(runHook HOST_OS=Unraid)
expect "Unraid gets the stop timeout notice" "$out" "Docker Stop Timeout to 120"

out=$(runHook)
expectNot "no notice outside Unraid" "$out" "Docker Stop Timeout"

# With Unraid's docker.cfg mounted, check the real value.
printf 'DOCKER_ENABLED="yes"\nDOCKER_TIMEOUT="10"\n' > "$FAKE/docker.cfg"
out=$(runHook HOST_OS=Unraid)
expect "short Unraid stop timeout is a warning" "$out" "Docker Stop Timeout is 10s"
expect "warning names the needed value" "$out" "to 120 or more"
printf 'DOCKER_ENABLED="yes"\n' > "$FAKE/docker.cfg"
out=$(runHook HOST_OS=Unraid)
expect "missing setting means Unraid's default of 10" "$out" "Docker Stop Timeout is 10s"
printf 'DOCKER_TIMEOUT="150"\n' > "$FAKE/docker.cfg"
out=$(runHook HOST_OS=Unraid)
expectNot "long enough stop timeout is quiet" "$out" "Docker Stop Timeout"
out=$(runHook HOST_OS=Unraid TIMEOUT=200)
expect "a longer TIMEOUT raises the need" "$out" "to 215 or more"
rm -f "$FAKE/docker.cfg"


# --- Streaming ----------------------------------------------------------------

out=$(runHook STREAM=Y GPU=Y "${NV[@]}")
expect "STREAM=Y needs Sunshine" "$out" "STREAM=Y needs Sunshine"

out=$(env -i PATH="$PATH" UNRAID_HOOK_TEST=Y bash -c 'source "$0"
  USER_PORTS="3389,47984,47989/tcp,47990,48010,47998/udp,47999/UDP,48000/udp,8080,47998"
  streamPorts; printf "PORTS=%s\n" "$USER_PORTS"' "$HOOK" 2>&1)
expect "Sunshine's ports leave USER_PORTS" "$out" "PORTS=3389,8080,47998"$'\n'

out=$(env -i PATH="$PATH" UNRAID_HOOK_TEST=Y bash -c 'source "$0"
  HOST_PORTS="8080"; streamPorts; printf "HOST=%s\n" "$HOST_PORTS"' "$HOOK" 2>&1)
expect "NAT keeps Sunshine's TCP ports in the container" "$out" "HOST=8080,47984,47989,47990,48010"$'\n'
out=$(env -i PATH="$PATH" UNRAID_HOOK_TEST=Y NETWORK=user bash -c 'source "$0"
  streamPorts; printf "HOST=%s\n" "$HOST_PORTS"' "$HOOK" 2>&1)
expect "user-mode networking leaves HOST_PORTS alone" "$out" "HOST="$'\n'
out=$(env -i PATH="$PATH" UNRAID_HOOK_TEST=Y DHCP=Y bash -c 'source "$0"
  streamPorts; printf "HOST=%s\n" "$HOST_PORTS"' "$HOOK" 2>&1)
expect "DHCP networking leaves HOST_PORTS alone" "$out" "HOST="$'\n'

# A fake iptables: the NAT chain exists, and every change is recorded.
mkdir -p "$FAKE/ipt"
cat > "$FAKE/ipt/iptables" <<'EOF_IPTABLES'
#!/usr/bin/env bash
case "$*" in
  "-t nat -S QEMU_DNAT") exit 0 ;;
  "-t nat -S "*) exit 1 ;;
  *" -C "*) exit 1 ;;
esac
printf 'iptables %s\n' "$*" >> "$FAKE_IPTABLES_LOG"
EOF_IPTABLES
chmod +x "$FAKE/ipt/iptables"
out=$(env -i PATH="$FAKE/ipt:$PATH" FAKE_IPTABLES_LOG="$FAKE/iptables.calls" UNRAID_HOOK_TEST=Y bash -c 'source "$0"
  streamUdp' "$HOOK" 2>&1)
expect "NAT returns Sunshine's UDP ports to the container" "$(cat "$FAKE/iptables.calls")" \
  "iptables -t nat -I QEMU_DNAT 1 -p udp --dport 47998:48000 -j RETURN"
out=$(env -i PATH="$FAKE/ipt:$PATH" FAKE_IPTABLES_LOG="$FAKE/iptables.calls" UNRAID_HOOK_TEST=Y \
  HOOK_STREAM_NAT_CHAIN=MISSING HOOK_STREAM_NAT_WAIT=1 bash -c 'source "$0"
  streamUdp; echo done' "$HOOK" 2>&1)
expect "no NAT chain, no UDP rule" "$out" "done"
expect "only one UDP rule was added" "$(grep -c . "$FAKE/iptables.calls")" "1"

# A fake Sunshine that records how it was called.
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/sunshine" <<'EOF_SUNSHINE'
#!/usr/bin/env bash
printf 'sunshine %s XDG=%s SOCKET=%s AUDIO=%s\n' "$*" "$XDG_CONFIG_HOME" "$WINBOX_STREAM_SOCKET" "$WINBOX_AUDIO_SOCKET" >> "$FAKE_SUNSHINE_LOG"
EOF_SUNSHINE
chmod +x "$FAKE/bin/sunshine"
STREAMENV=(PATH="$FAKE/bin:$PATH" FAKE_SUNSHINE_LOG="$FAKE/sunshine.calls" HOOK_STREAM_CONFIG="$FAKE/storage"
           HOOK_STREAM_LOG="$FAKE/sunshine.log" HOOK_STREAM_RESTART=0 HOOK_STREAM_SOCKET=/run/test.sock
           HOOK_STREAM_NAT_WAIT=0)

out=$(runHook "${STREAMENV[@]}" STREAM=Y)
expect "STREAM=Y needs GPU=Y" "$out" "STREAM=Y needs GPU=Y"

out=$(runHook "${STREAMENV[@]}" STREAM=Y GPU=Y "${NV[@]}" USERNAME=winuser USER_PORTS=47989,3390)
expect "STREAM=Y starts Sunshine" "$out" "Streaming with Sunshine on the GPU"
wait_for() { for _ in $(seq 50); do [ -s "$1" ] && grep -q "$2" "$1" && return 0; sleep 0.1; done; return 1; }
wait_for "$FAKE/sunshine.calls" "sunshine.conf"
calls=$(cat "$FAKE/sunshine.calls")
expect "login comes from the web console" "$calls" "sunshine --creds winuser s3cret-Pass XDG=$FAKE/storage"
expect "Sunshine runs on its config" "$calls" "sunshine $FAKE/storage/sunshine/sunshine.conf XDG=$FAKE/storage SOCKET=/run/test.sock AUDIO=/run/shm/audio.sock"
expect "first start writes a config" "$(cat "$FAKE/storage/sunshine/sunshine.conf")" "encoder = nvenc"
expect "first start writes the apps" "$(cat "$FAKE/storage/sunshine/apps.json")" '"name": "Desktop"'

audio=$(env -i PATH="$FAKE/bin:$PATH" UNRAID_HOOK_TEST=Y "${STREAMENV[@]}" GPU=Y bash -c 'source "$0"
  startStream >/dev/null 2>&1; printf "AUDIO=%s\n" "$AUDIO"' "$HOOK" 2>&1)
expect "STREAM=Y turns sound on" "$audio" "AUDIO=Y"
out=$(runHook "${STREAMENV[@]}" STREAM=Y GPU=Y "${NV[@]}" AUDIO=N)
expect "STREAM=Y with AUDIO=N says how to get sound" "$out" "(AUDIO) to Y for sound in Moonlight"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
