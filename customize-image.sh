#!/bin/bash
set -e

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4

echo ">>> 1. Установка зависимостей сборки, ядра и прошивок..."
apt-get update
apt-get install -y --no-install-recommends \
    build-essential git ca-certificates curl gpg pkg-config meson ninja-build yasm nasm \
    linux-libc-dev libdrm-dev libudev-dev libgbm-dev libegl-dev libgles-dev \
    libwayland-dev wayland-protocols libxkbcommon-dev \
    libplacebo-dev libass-dev libfreetype-dev libfribidi-dev libharfbuzz-dev \
    libpulse-dev libpipewire-0.3-dev libasound2-dev \
    libgnutls28-dev libdav1d-dev libx264-dev libx265-dev libvpx-dev libopus-dev \
    linux-firmware v4l-utils mesa-utils

echo ">>> 2. Получение официального FFmpeg и актуального PR #20847..."
mkdir -p /tmp/ffmpeg-v4l2
cd /tmp/ffmpeg-v4l2
git init
git remote add origin https://code.ffmpeg.org/FFmpeg/FFmpeg.git
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

make -j$(nproc)
make install
ldconfig

echo ">>> 4. Сборка mpv поверх собранных библиотек libav*..."
cd /tmp
git clone --depth=1 https://github.com/mpv-player/mpv.git mpv-src
cd mpv-src
PKG_CONFIG_PATH=/usr/local/lib/pkgconfig meson setup build \
    --prefix=/usr/local \
    -Dwayland=enabled \
    -Degl-wayland=enabled \
    -Ddrm=enabled \
    -Dgbm=enabled \
    -Dpipewire=enabled \
    -Dlibplacebo=enabled

ninja -C build
ninja -C build install
ldconfig

echo ">>> 5. Установка системной конфигурации mpv для GNOME 51 (Wayland)..."
mkdir -p /etc/mpv
if [ -f /tmp/overlay/mpv.conf ]; then
    cp /tmp/overlay/mpv.conf /etc/mpv/mpv.conf
else
    echo "WARNING: /tmp/overlay/mpv.conf не найден!"
fi

echo ">>> 6. Установка deb-версии Chromium (без Snap) и настройка V4L2/GPU..."
apt-get install -y software-properties-common
add-apt-repository -y ppa:xtradeb/apps || true
apt-get update
apt-get install -y chromium || apt-get install -y chromium-browser

mkdir -p /etc/chromium.d /etc/chromium-browser
cat << 'EOF' > /etc/chromium.d/rk3588-hwdec
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS \
  --ozone-platform-hint=auto \
  --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL \
  --ignore-gpu-blocklist \
  --enable-gpu-rasterization \
  --enable-zero-copy"
EOF
cp /etc/chromium.d/rk3588-hwdec /etc/chromium-browser/default

mkdir -p /etc/skel/.config
cat << 'EOF' > /etc/skel/.config/chromium-flags.conf
--ozone-platform-hint=auto
--enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL
--ignore-gpu-blocklist
--enable-gpu-rasterization
--enable-zero-copy
EOF

echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
echo 'EXTRA_GROUPS="video render"' >> /etc/adduser.conf

echo ">>> 7. Удаление остаточных пакетов U-Boot и настройка GRUB2 EFI..."
apt-get purge -y 'linux-u-boot-*' u-boot-tools || true
apt-get autoremove -y
apt-get install -y --no-install-recommends grub-efi-arm64 efibootmgr

DTB_FILE=$(find /boot/dtb* -name "rk3588-nanopc-t6.dtb" 2>/dev/null | head -n 1 | sed 's|^/boot||')
if [ -n "$DTB_FILE" ]; then
    grep -q "GRUB_DEFAULT_DTB" /etc/default/grub || echo "GRUB_DEFAULT_DTB=\"$DTB_FILE\"" >> /etc/default/grub
fi
update-grub || true

echo ">>> 8. Очистка временных файлов сборки..."
rm -rf /tmp/ffmpeg-v4l2 /tmp/mpv-src
apt-get clean
