# syntax=docker/dockerfile:1

# Sunshine for STREAM=Y (see sunshine/README.md). v2026.1028.122642
ARG SUNSHINE_REF="d7e5fe00701539a5be4a0304239730e1dfec4cf9"
# CUDA 13 can't build for Pascal GPUs (GTX 10-series, Quadro P) any more, so
# Sunshine is built with the last CUDA 12. NVIDIA's Debian 12 repository has it.
ARG CUDA_REPO="https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64"
ARG CUDA_PACKAGE_VERSION="12-9"
ARG CUDA_DIR="/usr/local/cuda-12.9"

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
    --with-pkgversion="winbox-nvidia-gpu ${VERSION_ARG}" \
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
  grep -F "refresh_rate=" /tmp/help
  /usr/bin/qemu-system-x86_64 -display help | grep -F "egl-headless"

  rm /tmp/help
EOF_VERIFY

# ---------------------------------------------------------------------------
# Stage 2: Sunshine with WinBox's QEMU capture source, so STREAM=Y can stream
# Windows to Moonlight with the video encoded on the GPU (NVENC) on the host.
# Built on Debian trixie like dockurr/windows, so the package's library
# dependencies match the image it is installed in.

# NVIDIA's repository key is bound with a SHA-1 signature, which trixie's apt
# no longer accepts. Debian 12's apt still verifies it, so it downloads the
# CUDA packages, and the trixie builder installs those files.
FROM debian:bookworm AS cuda

ARG CUDA_REPO
ARG CUDA_PACKAGE_VERSION
ARG DEBIAN_FRONTEND="noninteractive"

RUN <<'EOF_CUDA_DOWNLOAD'
  set -eu
  apt-get update
  apt-get install --no-install-recommends -y ca-certificates wget
  wget -q "$CUDA_REPO/cuda-keyring_1.1-1_all.deb" -O /tmp/cuda-keyring.deb
  dpkg -i /tmp/cuda-keyring.deb
  apt-get update
  apt-get install --download-only --no-install-recommends -y \
    "cuda-nvcc-$CUDA_PACKAGE_VERSION" \
    "cuda-cudart-dev-$CUDA_PACKAGE_VERSION" \
    "cuda-driver-dev-$CUDA_PACKAGE_VERSION"
  mkdir /cuda
  cp /var/cache/apt/archives/cuda-*.deb /cuda/
  ls /cuda
EOF_CUDA_DOWNLOAD

FROM debian:trixie AS sunshine-builder

ARG SUNSHINE_REF
ARG CUDA_DIR
ARG DEBIAN_FRONTEND="noninteractive"

RUN <<EOF_SUNSHINE_TOOLS
  set -eu
  apt-get update
  apt-get install --no-install-recommends -y ca-certificates git wget
  rm -rf /var/lib/apt/lists/*
EOF_SUNSHINE_TOOLS

WORKDIR /src

RUN <<'EOF_SUNSHINE_SOURCE'
  set -eu
  git init -q .
  git remote add origin https://github.com/LizardByte/Sunshine.git
  git fetch -q --depth=1 origin "$SUNSHINE_REF"
  git checkout -q --detach FETCH_HEAD
  git submodule -q update --init --depth=1 --recursive
  echo "Sunshine: $(git rev-parse HEAD)"
EOF_SUNSHINE_SOURCE

COPY sunshine/patches /tmp/sunshine-patches

RUN <<'EOF_SUNSHINE_PATCH'
  set -eu
  for patch in /tmp/sunshine-patches/*.patch; do
    echo "Applying ${patch##*/}..."
    git apply --check "$patch"
    git apply "$patch"
  done
EOF_SUNSHINE_PATCH

# Sunshine's own script installs the build dependencies; CUDA comes next.
RUN <<'EOF_SUNSHINE_DEPS'
  set -eu
  ./scripts/linux_build.sh --step=deps --skip-cuda --sudo-off
  rm -rf /var/lib/apt/lists/*
EOF_SUNSHINE_DEPS

COPY --from=cuda /cuda /tmp/cuda

RUN <<'EOF_SUNSHINE_CUDA'
  set -eu
  apt-get update
  apt-get install --no-install-recommends -y /tmp/cuda/*.deb
  rm -rf /var/lib/apt/lists/* /tmp/cuda

  # glibc 2.41 declares rsqrt, sinpi and cospi with noexcept; CUDA 12's
  # headers don't, and nvcc rejects the mismatch. Sunshine ships the fix.
  patch -p2 --directory="$CUDA_DIR" \
    < packaging/linux/patches/x86_64/cuda-12-math_functions.patch
  "$CUDA_DIR/bin/nvcc" --version
EOF_SUNSHINE_CUDA

RUN <<'EOF_SUNSHINE_BUILD'
  set -eu
  export CC=gcc-14 CXX=g++-14
  cmake -B build -G Ninja -S . \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DSUNSHINE_ASSETS_DIR=share/sunshine \
    -DSUNSHINE_EXECUTABLE_PATH=/usr/bin/sunshine \
    -DSUNSHINE_ENABLE_DRM=ON \
    -DSUNSHINE_ENABLE_KWIN=ON \
    -DSUNSHINE_ENABLE_PORTAL=ON \
    -DSUNSHINE_ENABLE_WAYLAND=ON \
    -DSUNSHINE_ENABLE_X11=ON \
    -DSUNSHINE_ENABLE_TRAY=OFF \
    -DSUNSHINE_ENABLE_CUDA=ON \
    -DCMAKE_CUDA_COMPILER="$CUDA_DIR/bin/nvcc" \
    -DCMAKE_CUDA_HOST_COMPILER=gcc-14 \
    -DBUILD_DOCS=OFF \
    -DBUILD_TESTS=OFF \
    -DSUNSHINE_PUBLISHER_NAME=WinBox \
    -DSUNSHINE_PUBLISHER_WEBSITE=https://github.com/botbuilt/Winbox-NVIDIA_GPU \
    -DSUNSHINE_PUBLISHER_ISSUE_URL=https://github.com/botbuilt/Winbox-NVIDIA_GPU/issues
  ninja -C build
  cpack -G DEB --config ./build/CPackConfig.cmake
  mkdir /out
  cp build/cpack_artifacts/*.deb /out/sunshine.deb
  ls -l /out
EOF_SUNSHINE_BUILD

# ---------------------------------------------------------------------------
# Stage 3: Windows in a container for Unraid, based on dockurr/windows.
# Adds a startup hook that checks shared (Nvidia/Intel/AMD) GPU setups on
# Unraid, and handles optional VFIO GPU/PCI passthrough and USB passthrough.

# Pinned by digest so a rebuild never picks up a different upstream image.
# Dependabot opens a PR when dockurr/windows publishes a new release.
FROM dockurr/windows:6.06@sha256:16fd7c39a3e48bb946d29c59dc6015942e5b900a1fa5d7e5552053bfc48ee2ea

LABEL org.opencontainers.image.title="winbox-nvidia-gpu" \
      org.opencontainers.image.description="Windows in a box for Unraid: a Windows VM in a container with DirectX 11 on a shared NVIDIA GPU (Triton) and Moonlight streaming encoded on the GPU (Sunshine, NVENC)" \
      org.opencontainers.image.source="https://github.com/botbuilt/Winbox-NVIDIA_GPU" \
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

# Sunshine with the QEMU capture source, started by STREAM=Y.
COPY --from=sunshine-builder /out/sunshine.deb /tmp/sunshine.deb
RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/sunshine.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/sunshine.deb \
 && ! ldd /usr/bin/sunshine | grep -F "not found" \
 && grep -qF "QEMU stream" /usr/bin/sunshine
