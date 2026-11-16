#!/bin/bash
set -e

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

echo ">>> 1. Установка зависимостей сборки, ядра, Mesa (Panfrost/PanVK) и прошивок..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    build-essential git ca-certificates curl gpg pkg-config meson ninja-build yasm nasm \
    python3-jinja2 python3-mako \
    linux-libc-dev libdrm-dev libudev-dev libgbm-dev libegl-dev libgles-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev \
    libass-dev libfreetype-dev libfribidi-dev libharfbuzz-dev \
    libvulkan-dev mesa-vulkan-drivers libgl1-mesa-dri \
    glslang-tools spirv-tools libshaderc-dev liblcms2-dev libdovi-dev \
    libpulse-dev libpipewire-0.3-dev libasound2-dev \
    libgnutls28-dev libdav1d-dev libx264-dev libx265-dev libvpx-dev libopus-dev \
    linux-firmware v4l-utils mesa-utils

echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local.conf
ldconfig

echo ">>> 2. Получение официального FFmpeg и актуального PR #20847..."
mkdir -p /tmp/ffmpeg-v4l2
cd /tmp/ffmpeg-v4l2
git init
git remote add origin https://ffmpeg.org
git fetch --depth=1 origin pull/20847/head
git checkout FETCH_HEAD

echo ">>> 3. Сборка FFmpeg с поддержкой V4L2 Request API..."
./configure \
    --prefix=/usr/local \
    --enable-gpl \
    --enable-version3 \
    --enable-shared \
    --disable-static \
    --disable-doc \
    --enable-libdrm \
    --enable-libudev \
    --enable-v4l2-request \
    --enable-gnutls \
    --enable-libdav1d \
    --enable-libx264 \
    --enable-libx265 \
    --enable-libvpx \
    --enable-libopus

make -j2
make install
ldconfig

echo ">>> 4. Сборка mpv (со встроенным subproject libplacebo) поверх собранных libav*..."
cd /tmp
git clone --depth=1 https://github.com/mpv-player/mpv.git mpv-src
mkdir -p /tmp/mpv-src/subprojects
git clone --depth=1 --recursive --shallow-submodules https://videolan.org /tmp/mpv-src/subprojects/libplacebo

cd /tmp/mpv-src
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig meson setup build \
    --prefix=/usr/local \
    --sysconfdir=/etc \
    -Ddefault_library=static \
    -Dlibplacebo:default_library=static \
    -Dlibplacebo:vulkan=enabled \
    -Dlibplacebo:opengl=enabled \
    -Dlibplacebo:shaderc=enabled \
    -Dlibplacebo:lcms=enabled \
    -Dwayland=enabled \
    -Degl-wayland=enabled \
    -Dvulkan=enabled \
    -Ddrm=enabled \
    -Dgbm=enabled \
    -Dpipewire=enabled

ninja -C build -j2
ninja -C build install
ldconfig

echo ">>> 5. Установка системной конфигурации mpv для GNOME 51 (Wayland)..."
mkdir -p /etc/mpv /usr/local/etc/mpv
if [ -f /tmp/overlay/mpv.conf ]; then
    cp /tmp/overlay/mpv.conf /etc/mpv/mpv.conf
    cp /tmp/overlay/mpv.conf /usr/local/etc/mpv/mpv.conf
elif [ -f /root/overlay/mpv.conf ]; then
    cp /root/overlay/mpv.conf /etc/mpv/mpv.conf
    cp /root/overlay/mpv.conf /usr/local/etc/mpv/mpv.conf
else
    echo "WARNING: mpv.conf не найден в overlay!"
fi

echo ">>> 6. Установка deb-версии Chromium (без Snap) и настройка V4L2/GPU..."
apt-get install -y --no-install-recommends software-properties-common
add-apt-repository -y ppa:xtradeb/apps || true
sed -i 's/stonking/resolute/g' /etc/apt/sources.list.d/*xtradeb* 2>/dev/null || true
apt-get update
apt-get install -y --no-install-recommends chromium || echo "WARNING: Пакет chromium недоступен"

mkdir -p /etc/chromium.d
cat << 'EOF' > /etc/chromium.d/rk3588-hwdec
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS \
  --ozone-platform=wayland \
  --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL \
  --ignore-gpu-blocklist \
  --enable-gpu-rasterization"
EOF

mkdir -p /etc/skel/.config
cat << 'EOF' > /etc/skel/.config/chromium-flags.conf
--ozone-platform=wayland
--enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL
--ignore-gpu-blocklist
--enable-gpu-rasterization
EOF

grep -q "^ADD_EXTRA_GROUPS=1" /etc/adduser.conf || echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
grep -q "^EXTRA_GROUPS=" /etc/adduser.conf || echo 'EXTRA_GROUPS="video render"' >> /etc/adduser.conf

echo ">>> 7. Удаление остаточных пакетов U-Boot и настройка GRUB2 EFI..."
apt-get purge -y 'linux-u-boot-*' u-boot-tools || true
apt-get autoremove -y

DTB_FILE=$(find /boot/dtb* -name "rk3588-nanopc-t6.dtb" 2>/dev/null | head -n 1 | sed 's|^/boot||')
if [ -n "$DTB_FILE" ]; then
    mkdir -p /etc/default
    grep -q "GRUB_DEFAULT_DTB" /etc/default/grub 2>/dev/null || echo "GRUB_DEFAULT_DTB=\"$DTB_FILE\"" >> /etc/default/grub
fi

echo ">>> 8. Очистка временных файлов сборки..."
cd /
rm -rf /tmp/ffmpeg-v4l2 /tmp/mpv-src
apt-get clean
