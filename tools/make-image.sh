#!/usr/bin/env bash
# Делает из ISO готовый образ флешки (.img), который записывается обычной программой
# (balenaEtcher, Rufus и т.п.) на любой компьютер, в том числе с Windows.
# На флешке схема sys / root / user; раздел user сам растягивается на всё место при первом запуске.
#
#     sudo tools/make-image.sh out/RectlessOS-0.1.0-desktop.iso [размер_образа_ГБ]
set -euo pipefail
ISO="${1:-}"; SIZE_GB="${2:-14}"
[ -f "$ISO" ] || { echo "Использование: sudo $0 <образ.iso> [размер_ГБ, по умолчанию 14]"; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${ISO%.iso}"; IMG="${IMG%-desktop}.img"
rm -f "$IMG"
truncate -s "${SIZE_GB}G" "$IMG"
ROOT_GB="${ROOT_GB:-6}" bash "$HERE/write-usb.sh" "$ISO" "$IMG"
echo "Образ флешки: $IMG ($(du -h --apparent-size "$IMG" | cut -f1))."
echo "Сожми для передачи: xz -T0 \"$IMG\" (получится .img.xz, Etcher открывает его напрямую)."
