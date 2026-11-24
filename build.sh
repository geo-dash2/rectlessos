#!/usr/bin/env bash
# Сборка загрузочного образа RectlessOS (Ubuntu 24.04 live, BIOS + UEFI).
# Запускать от root на Ubuntu/Debian (или в WSL2 с Ubuntu):
#     sudo ./build.sh                 # полная сборка с рабочим столом XFCE
#     sudo PROFILE=minimal ./build.sh # только консоль (быстро, для проверки)
set -euo pipefail

OS_NAME="${OS_NAME:-RectlessOS}"
OS_VERSION="${OS_VERSION:-0.1.0}"
PROFILE="${PROFILE:-desktop}"            # desktop | minimal
SUITE="${SUITE:-noble}"
MIRROR="${MIRROR:-http://archive.ubuntu.com/ubuntu}"
FIRMWARE="${FIRMWARE:-1}"                # 1 = linux-firmware (Wi-Fi и т.п. на реальном железе)
COMP="${COMP:-zstd}"                     # zstd (быстро) | xz (меньше размер, дольше)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/out}"
ROOTFS="$WORK/rootfs"
ISODIR="$WORK/iso"
ISO_NAME="${OS_NAME}-${OS_VERSION}-${PROFILE}.iso"

[ "$(id -u)" -eq 0 ] || { echo "Запусти от root: sudo $0"; exit 1; }

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

cleanup_mounts() {
  for m in dev/pts dev proc sys run; do
    mountpoint -q "$ROOTFS/$m" 2>/dev/null && umount -lf "$ROOTFS/$m" || true
  done
}
trap cleanup_mounts EXIT

log "Ставлю инструменты сборки"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
  grub-common mtools dosfstools >/dev/null

log "Создаю базовую систему ($SUITE)"
cleanup_mounts
rm -rf "$WORK"
mkdir -p "$ROOTFS" "$ISODIR/casper" "$ISODIR/boot/grub" "$ISODIR/.disk" "$OUT"
debootstrap --variant=minbase --components=main,universe "$SUITE" "$ROOTFS" "$MIRROR"

log "Настраиваю chroot"
cat > "$ROOTFS/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main universe multiverse
deb $MIRROR $SUITE-updates main universe multiverse
deb http://security.ubuntu.com/ubuntu $SUITE-security main universe multiverse
EOF
echo "${OS_NAME,,}" > "$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 %s\n' "${OS_NAME,,}" > "$ROOTFS/etc/hosts"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
# не запускать службы внутри chroot
printf '#!/bin/sh\nexit 101\n' > "$ROOTFS/usr/sbin/policy-rc.d"
chmod +x "$ROOTFS/usr/sbin/policy-rc.d"

mount --bind /dev  "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sys "$ROOTFS/sys"
mount -t tmpfs tmpfs "$ROOTFS/run"

PKGS="$(grep -hv '^\s*#' "$HERE/config/packages-base.txt" | tr '\n' ' ')"
if [ "$PROFILE" = "desktop" ]; then
  PKGS="$PKGS $(grep -hv '^\s*#' "$HERE/config/packages-desktop.txt" | tr '\n' ' ')"
fi
[ "$FIRMWARE" = "1" ] && PKGS="$PKGS linux-firmware"

log "Ставлю пакеты (это самый долгий этап)"
chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C bash -e <<EOF
apt-get update
apt-get install -y --no-install-recommends $PKGS
EOF

log "Накладываю свои файлы и настройки"
cp -a "$HERE/overlay/." "$ROOTFS/"
cat > "$ROOTFS/etc/casper.conf" <<EOF
export USERNAME="user"
export USERFULLNAME="Live user"
export HOST="${OS_NAME,,}"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="$OS_NAME"
EOF
cat > "$ROOTFS/etc/os-release" <<EOF
NAME="$OS_NAME"
PRETTY_NAME="$OS_NAME $OS_VERSION (Ubuntu 24.04 base)"
ID=${OS_NAME,,}
ID_LIKE="ubuntu debian"
VERSION_ID="$OS_VERSION"
VERSION="$OS_VERSION"
EOF
printf '%s %s\n' "$OS_NAME" "$OS_VERSION" > "$ROOTFS/etc/issue.net"
printf '%s %s \\n \\l\n\n' "$OS_NAME" "$OS_VERSION" > "$ROOTFS/etc/issue"

chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C bash -e <<'EOF'
locale-gen ru_RU.UTF-8 en_US.UTF-8
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf.target
systemctl enable NetworkManager systemd-resolved 2>/dev/null || true
command -v lightdm >/dev/null && systemctl enable lightdm 2>/dev/null || true
chmod +x /usr/local/sbin/rectlessos-grow
systemctl enable rectlessos-grow.service 2>/dev/null || true
update-initramfs -u -k all
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
: > /etc/machine-id
rm -f /usr/sbin/policy-rc.d
EOF
rm -f "$ROOTFS/etc/resolv.conf"
ln -s ../run/systemd/resolve/stub-resolv.conf "$ROOTFS/etc/resolv.conf"
rm -f "$ROOTFS/etc/resolv.conf.target"

cleanup_mounts

log "Копирую ядро и initrd"
KERNEL="$(ls "$ROOTFS"/boot/vmlinuz-* | sort -V | tail -1)"
INITRD="$(ls "$ROOTFS"/boot/initrd.img-* | sort -V | tail -1)"
cp "$KERNEL" "$ISODIR/casper/vmlinuz"
cp "$INITRD" "$ISODIR/casper/initrd"

log "Упаковываю систему в squashfs ($COMP)"
SQ_OPTS=(-comp "$COMP" -noappend -no-progress)
[ "$COMP" = "zstd" ] && SQ_OPTS+=(-Xcompression-level 15)
mksquashfs "$ROOTFS" "$ISODIR/casper/filesystem.squashfs" "${SQ_OPTS[@]}" \
  -e boot/vmlinuz-* -e boot/initrd.img-* >/dev/null
du -sx --block-size=1 "$ROOTFS" | cut -f1 > "$ISODIR/casper/filesystem.size"

log "Пишу меню загрузки и собираю ISO (BIOS + UEFI)"
echo "$OS_NAME $OS_VERSION" > "$ISODIR/.disk/info"
cat > "$ISODIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=8
insmod all_video
insmod gfxterm
terminal_output console

menuentry "$OS_NAME - Live (changes are not saved)" {
  linux /casper/vmlinuz boot=casper quiet ---
  initrd /casper/initrd
}
menuentry "$OS_NAME - Live with persistence (needs a casper-rw partition)" {
  linux /casper/vmlinuz boot=casper persistent quiet ---
  initrd /casper/initrd
}
menuentry "$OS_NAME - Safe graphics (nomodeset)" {
  linux /casper/vmlinuz boot=casper nomodeset ---
  initrd /casper/initrd
}
menuentry "$OS_NAME - Load into RAM (you can unplug the USB drive)" {
  linux /casper/vmlinuz boot=casper toram quiet ---
  initrd /casper/initrd
}
EOF
grub-mkrescue -o "$OUT/$ISO_NAME" "$ISODIR" -- -volid "${OS_NAME^^}" >/dev/null 2>&1
( cd "$OUT" && sha256sum "$ISO_NAME" > "$ISO_NAME.sha256" )

log "Готово: $OUT/$ISO_NAME ($(du -h "$OUT/$ISO_NAME" | cut -f1))"
