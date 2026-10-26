# syntax=docker/dockerfile:1


# ---------------------------------------------------------------------------
# Stage 1: QEMU for the Triton DirectX 11 driver (see qemu-triton/README.md).
# Builds UTM's QEMU with its Neptune virtio-gpu context, the matching
# virglrenderer and the DXVK Native fork that renders the guest's D3D11 on the
# host's Vulkan. Everything but the QEMU binary lives under /opt/neptune so it
# can't clash with the virglrenderer the base image ships.

FROM registry.gitlab.com/qemu-project/qemu/qemu/debian:latest AS builder

ARG VERSION_ARG="0.0.0"
ARG QEMU_REF="ae92cdc41fb0b0dab36c6ac724e1729ffc47ef18"
ARG VIRGL_REF="451505ad0aa449290f2c0672da6877d57ee770e5"
ARG DXVK_REF="389d26b360b0080f4ffe816779960745434aef6a"

ARG DEBIAN_FRONTEND="noninteractive"

ENV PREFIX="/opt/neptune"

RUN <<EOF_BUILD_DEPS
  set -eu

  apt-get update
  apt-get install --no-install-recommends -y \
    dpkg-dev \
    g++ \
    glslang-tools \
    libvulkan-dev \
    python3-mako \
    python3-yaml

  rm -rf /var/lib/apt/lists/*
EOF_BUILD_DEPS

WORKDIR /src

# Fetch a pinned commit of a repository, with its submodules.
RUN <<'EOF_SOURCES'
  set -eu

  fetch() {
    git init -q "$1"
    git -C "$1" remote add origin "$2"
    git -C "$1" fetch -q --depth=1 origin "$3"
    git -C "$1" checkout -q --detach FETCH_HEAD
    git -C "$1" submodule -q update --init --depth=1 --recursive
    echo "$1: $(git -C "$1" rev-parse HEAD)"
  }

  fetch qemu https://github.com/utmapp/qemu.git "$QEMU_REF"
  fetch virglrenderer https://github.com/utmapp/virglrenderer.git "$VIRGL_REF"
  fetch dxvk https://github.com/osy/dxvk.git "$DXVK_REF"
EOF_SOURCES

# virglrenderer's macos-next branch (it carries the Linux Neptune work too) and
# DXVK master share directx-native's backend contract and match the protocol
# of the v0.4 guest driver.
# DXVK Native with the headless WSI: the render server has no window. The
# $ORIGIN rpath makes libdxvk_d3d11 load the libdxvk_dxgi next to it, never a
# distro copy.
COPY qemu-triton/dxvk-patches /tmp/dxvk-patches

RUN <<'EOF_DXVK'
  set -eu

  # NVIDIA offers no shareable linear layout for the guest's scanout
  # textures; dxvk-patches/ falls back to a tiled one and logs why.
  for patch in /tmp/dxvk-patches/*.patch; do
    echo "Applying ${patch##*/}..."
    git -C /src/dxvk apply --check "$patch"
    git -C /src/dxvk apply "$patch"
  done

  meson setup /build-dxvk /src/dxvk \
    --buildtype=release \
    --prefix="$PREFIX" \
    --libdir=lib \
    -Db_ndebug=true \
    -Dnative_headless=true \
    -Dnative_sdl2=disabled \
    -Dnative_sdl3=disabled \
    -Dnative_glfw=disabled \
    -Dc_args=-U_GLIBCXX_ASSERTIONS \
    -Dcpp_args=-U_GLIBCXX_ASSERTIONS \
    -Dc_link_args='-Wl,-rpath,$ORIGIN' \
    -Dcpp_link_args='-Wl,-rpath,$ORIGIN'

  meson compile -C /build-dxvk
  meson install -C /build-dxvk
  ls -l "$PREFIX/lib"
EOF_DXVK

COPY qemu-triton/virgl-patches /tmp/virgl-patches

RUN <<'EOF_VIRGL'
  set -eu

  # Neptune dlopens the DXVK libraries at run time and only needs
  # directx-native's headers, which meson fetches as a subproject.
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

  # The Neptune branches are developed with clang on macOS; these patches
  # fix what GCC rejects.
  for patch in /tmp/virgl-patches/*.patch; do
    echo "Applying ${patch##*/}..."
    git -C /src/virglrenderer apply --check "$patch"
    git -C /src/virglrenderer apply "$patch"
  done

  meson setup /build-virgl /src/virglrenderer \
    --buildtype=release \
    --prefix="$PREFIX" \
    --libdir=lib \
    --libexecdir=libexec \
    -Dplatforms=egl \
    -Dvenus=true \
    -Dneptune=true \
    -Dunstable-apis=true \
    -Dtests=false \
    -Dvideo=false \
    -Dc_args=-Wno-error=pedantic

  meson compile -C /build-virgl
  meson install -C /build-virgl
EOF_VIRGL

COPY qemu-triton/patches /tmp/winbox-patches

RUN <<'EOF_PATCHES'
  set -eu

  for patch in /tmp/winbox-patches/*.patch; do
    echo "Applying ${patch##*/}..."
    git -C /src/qemu apply --check "$patch"
    git -C /src/qemu apply "$patch"
  done

  meson subprojects download --sourcedir /src/qemu \
    keycodemapdb \
    berkeley-softfloat-3 \
    berkeley-testfloat-3
EOF_PATCHES

# Same feature set as qemu-windows, minus SPICE (WinBox shows the console over
# VNC, and UTM's SPICE GL code doesn't build against GBM).
RUN <<'EOF_BUILD'
  set -eu

  mkdir /build /out
  cd /build

  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

  multiarch="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  extra_cflags="$(dpkg-buildflags --get CFLAGS) $(dpkg-buildflags --get CPPFLAGS)"
  extra_ldflags="$(dpkg-buildflags --get LDFLAGS) -Wl,--disable-new-dtags,-rpath,$PREFIX/lib"

  /src/qemu/configure \
    --with-pkgversion="winbox-triton ${VERSION_ARG}" \
    --target-list=x86_64-softmmu \
    --prefix=/usr \
    --libdir="/usr/lib/${multiarch}" \
    --libexecdir=/usr/lib/qemu \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --mandir=/usr/share/man \
    --firmwarepath=/usr/share/qemu:/usr/share/seabios \
    --extra-cflags="$extra_cflags" \
    --extra-ldflags="$extra_ldflags" \
    --audio-drv-list=alsa,oss \
    --disable-af-xdp \
    --disable-blkio \
    --disable-brlapi \
    --disable-bzip2 \
    --disable-cocoa \
    --disable-containers \
    --disable-curl \
    --disable-docs \
    --disable-download \
    --disable-gtk \
    --disable-hvf \
    --disable-install-blobs \
    --disable-jack \
    --disable-libcbor \
    --disable-libiscsi \
    --disable-libnfs \
    --disable-libssh \
    --disable-linux-user \
    --disable-lzo \
    --disable-modules \
    --disable-pa \
    --disable-pipewire \
    --disable-rbd \
    --disable-rdma \
    --disable-relocatable \
    --disable-sdl \
    --disable-snappy \
    --disable-sndio \
    --disable-spice \
    --disable-strip \
    --disable-tools \
    --disable-user \
    --disable-vde \
    --disable-vte \
    --disable-werror \
    --disable-xen \
    --disable-xkbcommon \
    --enable-attr \
    --enable-cap-ng \
    --enable-curses \
    --enable-fdt \
    --enable-gnutls \
    --enable-kvm \
    --enable-libusb \
    --enable-libudev \
    --enable-linux-aio \
    --enable-linux-io-uring \
    --enable-nettle \
    --enable-numa \
    --enable-opengl \
    --enable-pixman \
    --enable-png \
    --enable-seccomp \
    --enable-slirp \
    --enable-system \
    --enable-tcg \
    --enable-usb-redir \
    --enable-vhost-net \
    --enable-vhost-user \
    --enable-virglrenderer \
    --enable-virtfs \
    --enable-vnc \
    --enable-vnc-jpeg \
    --enable-vnc-sasl \
    --enable-zstd

  meson configure /build | grep -iE 'virgl|opengl|gbm' || true
  grep -E 'VIRGL' /build/config-host.h || true
  grep -Eq '^#define HAVE_VIRGL_RENDERER_NEPTUNE( 1)?$' /build/config-host.h || {
    echo "FAIL: QEMU did not pick up virglrenderer's Neptune support."
    exit 1
  }

  ninja qemu-system-x86_64

  install -Dm755 /build/qemu-system-x86_64 /out/usr/bin/qemu-system-x86_64
  strip --strip-unneeded /out/usr/bin/qemu-system-x86_64

  mkdir -p /out/opt
  cp -a "$PREFIX" /out/opt/
  rm -rf /out/opt/neptune/include /out/opt/neptune/lib/pkgconfig
EOF_BUILD

# Test the result inside the qemux/qemu runtime the WinBox image is built on.
FROM qemux/qemu:latest AS verify

COPY --from=builder /out/ /

RUN <<'EOF_VERIFY'
  set -eu

  for binary in /usr/bin/qemu-system-x86_64 /opt/neptune/lib/libdxvk_d3d11.so.0 \
      /opt/neptune/lib/libdxvk_dxgi.so.0 /opt/neptune/libexec/virgl_render_server; do
    deps="$(ldd "$binary" 2>&1)"
    printf '%s:\n%s\n' "$binary" "$deps"
    if printf '%s\n' "$deps" | grep -q 'not found'; then
      echo "FAIL: missing runtime dependencies for $binary."
      exit 1
    fi
  done

  ldd /usr/bin/qemu-system-x86_64 | grep -F '/opt/neptune/lib/libvirglrenderer' || {
    echo "FAIL: QEMU does not load the Neptune virglrenderer."
    exit 1
  }

  LD_BIND_NOW=1 /usr/bin/qemu-system-x86_64 --version

  /usr/bin/qemu-system-x86_64 -device virtio-vga-gl,help > /tmp/help 2>&1
  cat /tmp/help
  grep -F "neptune=" /tmp/help
  grep -F "host3d_blob_limit=" /tmp/help
  /usr/bin/qemu-system-x86_64 -display help | grep -F "egl-headless"

  rm /tmp/help
EOF_VERIFY

# ---------------------------------------------------------------------------
# Stage 2: Windows in a container for Unraid, based on dockurr/windows.
# Adds a startup hook that checks shared (Nvidia/Intel/AMD) GPU setups on
# Unraid, and handles optional VFIO GPU/PCI passthrough and USB passthrough.

# Pinned by digest so a rebuild never picks up a different upstream image.
# Dependabot opens a PR when dockurr/windows publishes a new release.
FROM dockurr/windows:6.06@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea

LABEL org.opencontainers.image.title="winbox-triton" \
      org.opencontainers.image.description="Windows VM in a container for Unraid, with DirectX 11 on a shared GPU through Triton" \
      org.opencontainers.image.source="https://github.com/botbuilt/Winbox-triton-driver" \
      org.opencontainers.image.licenses="MIT"

# Nvidia's Vulkan driver (libGLX_nvidia.so.0, injected by the Nvidia runtime)
# links against libXext, which the base image lacks. Without it the Vulkan
# loader skips the Nvidia ICD and shared GPU acceleration fails.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libxext6 \
 && rm -rf /var/lib/apt/lists/*

# Upstream sources /run/start.sh before anything else, as a startup hook.
COPY --chmod=755 ./src/start.sh /run/start.sh
COPY --chmod=755 ./src/health.sh /run/health.sh

# graphics and display are needed for Windows rendering on a shared Nvidia GPU.
# PROTECT puts the web console behind USERNAME/PASSWORD.
ENV NVIDIA_DRIVER_CAPABILITIES="all" \
    PROTECT="Y" \
    ALLOW_WEAK_PASSWORD="N" \
    GPU_PASSTHROUGH="" \
    PCI_PASSTHROUGH="" \
    VFIO_GROUP="Y" \
    GPU_ROM="" \
    GPU_PRIMARY="N" \
    USB_PASSTHROUGH=""

# Generous start period: the first start downloads and installs Windows, and
# upstream's check already reports healthy until QEMU is running.
HEALTHCHECK --interval=60s --timeout=30s --start-period=5m --retries=3 \
  CMD ["/run/health.sh"]

# Triton: UTM's QEMU with the Neptune virtio-gpu context, and its renderer
# (virglrenderer + DXVK Native) in /opt/neptune.
COPY --from=verify /usr/bin/qemu-system-x86_64 /usr/bin/qemu-system-x86_64
COPY --from=verify /opt/neptune /opt/neptune
ENV VGA="virtio-vga-gl,neptune=true" \
    NPT_D3D11_LIBRARY_PATH="/opt/neptune/lib/libdxvk_d3d11.so.0" \
    NPT_DXGI_LIBRARY_PATH="/opt/neptune/lib/libdxvk_dxgi.so.0" \
    DXVK_WSI_DRIVER="Headless"
