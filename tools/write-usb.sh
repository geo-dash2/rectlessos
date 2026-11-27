#!/usr/bin/env bash
# Записывает RectlessOS на флешку (Linux, от root).
#
#     sudo ./write-usb.sh RectlessOS-0.1.0-desktop.iso /dev/sdX
#
# Схема флешки (подробнее в ARCHITECTURE.md):
#   sys   - система, только чтение: ядро + образ системы + загрузчик (раздел RECTLESS, FAT32)
#   root  - слой администратора: настройки и установленные программы   (раздел casper-rw, ext4)
#   user  - твои файлы: домашняя папка /home                           (раздел home-rw,   ext4)
# Грузится и в UEFI, и в старом BIOS. Размер root задаётся ROOT_GB (по умолчанию 16 ГБ),
# всё остальное место на флешке отдаётся под user.
#
# ВНИМАНИЕ: всё содержимое флешки /dev/sdX будет УДАЛЕНО. Проверь имя через `lsblk`.
# Вместо /dev/sdX можно дать путь к файлу образа диска (для проверки в виртуалке).
set -euo pipefail

ISO="${1:-}"; TARGET="${2:-}"
ROOT_GB="${ROOT_GB:-16}"
[ -f "$ISO" ] && [ -n "$TARGET" ] || { echo "Использование: sudo $0 <образ.iso> </dev/sdX>"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Запусти от root (sudo)."; exit 1; }
for c in sgdisk mkfs.vfat mkfs.ext4 grub-mkstandalone grub-mkimage mcopy mmd losetup partprobe xorriso python3; do
  command -v "$c" >/dev/null || {
    echo "Не хватает '$c'. Поставь: sudo apt install gdisk dosfstools e2fsprogs mtools grub-pc-bin grub-efi-amd64-bin grub-common parted xorriso"
    exit 1; }
done

LOOP=""
if [ -f "$TARGET" ]; then
  LOOP="$(losetup -f --show -P "$TARGET")"; DEV="$LOOP"
else
  DEV="$TARGET"
  [ -b "$DEV" ] || { echo "$DEV - не блочное устройство."; exit 1; }
  if lsblk -rno MOUNTPOINT "$DEV" | grep -qx '/'; then echo "Это системный диск! Отмена."; exit 1; fi
  echo "Диск, который будет СТЁРТ:"
  lsblk -o NAME,SIZE,TRAN,RM,MODEL "$DEV"
  echo
  read -r -p "Для подтверждения введи имя устройства ($DEV): " ans
  [ "$ans" = "$DEV" ] || { echo "Отмена."; exit 1; }
fi

WORK="$(mktemp -d -p /var/tmp)"
cleanup() {
  [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

part() {   # имя раздела N у устройства (sdb1 / nvme0n1p1 / loop0p1)
  case "$DEV" in *[0-9]) echo "${DEV}p$1" ;; *) echo "${DEV}$1" ;; esac
}
ensure_node() {  # в контейнерах без udev узла раздела может не быть - создаём из /sys
  local p="$1" i n; n="$(basename "$p")"
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -b "$p" ] && return 0; sleep 0.5; done
  if [ -r "/sys/class/block/$n/dev" ]; then mknod "$p" b $(tr ':' ' ' < "/sys/class/block/$n/dev"); fi
  [ -b "$p" ]
}

echo "Достаю файлы из образа..."
mkdir "$WORK/iso"
xorriso -osirrox on -indev "$ISO" -extract / "$WORK/iso" >/dev/null 2>&1
chmod -R u+rwX "$WORK/iso"
OS_NAME="$(cut -d' ' -f1 "$WORK/iso/.disk/info")"; OS_NAME="${OS_NAME:-RectlessOS}"
SYS="$OS_NAME/sys"            # папка sys на флешке
SQ_SIZE="$(stat -c %s "$WORK/iso/casper/filesystem.squashfs")"
if [ "$SQ_SIZE" -ge 4294967296 ]; then
  echo "Ошибка: filesystem.squashfs больше 4 ГиБ, FAT32 такое не вмещает. Пересобери с COMP=xz."; exit 1
fi

echo "Размечаю диск..."
umount "${DEV}"?* 2>/dev/null || true
wipefs -a "$DEV" >/dev/null 2>&1 || true
sgdisk -Z "$DEV" >/dev/null
SYS_MB=$(( ($(du -sb "$WORK/iso/casper" | cut -f1) / 1048576) + 600 ))
DISK_MB=$(( $(blockdev --getsize64 "$DEV" 2>/dev/null || stat -c %s "$TARGET") / 1048576 ))
FREE_MB=$(( DISK_MB - SYS_MB - 16 ))
ROOT_MB=$(( ROOT_GB * 1024 ))
[ "$ROOT_MB" -gt $(( FREE_MB / 2 )) ] && ROOT_MB=$(( FREE_MB / 2 ))   # на маленькой флешке: поровну
sgdisk -n 1:0:+8M          -t 1:ef02 -c 1:bios-boot            "$DEV" >/dev/null
sgdisk -n 2:0:+${SYS_MB}M  -t 2:0700 -c 2:"$OS_NAME-sys"       "$DEV" >/dev/null
sgdisk -n 3:0:+${ROOT_MB}M -t 3:8300 -c 3:"$OS_NAME-root"      "$DEV" >/dev/null
sgdisk -n 4:0:0            -t 4:8300 -c 4:"$OS_NAME-user"      "$DEV" >/dev/null
partprobe "$DEV" 2>/dev/null || true
P2="$(part 2)"; P3="$(part 3)"; P4="$(part 4)"
ensure_node "$P2"; ensure_node "$P3"; ensure_node "$P4"

echo "Форматирую..."
mkfs.vfat -F 32 -n RECTLESS "$P2" >/dev/null
mkfs.ext4 -q -F -L casper-rw "$P3"     # root: слой изменений системы
mkfs.ext4 -q -F -L home-rw   "$P4"     # user: /home
# меньше записей на флешку: noatime + сброс на диск раз в 20 с (читается ядром при каждом монтировании)
tune2fs -E mount_opts=noatime,commit=20 "$P3" >/dev/null 2>&1 || true
tune2fs -E mount_opts=noatime,commit=20 "$P4" >/dev/null 2>&1 || true

echo "Копирую систему (несколько минут)..."
export MTOOLS_SKIP_CHECK=1
mmd -i "$P2" ::/EFI ::/EFI/BOOT ::/"$OS_NAME" ::/"$SYS" ::/"$SYS"/boot ::/"$SYS"/boot/grub ::/"$SYS"/boot/grub/i386-pc
mcopy -Q -i "$P2" "$WORK"/iso/casper/* ::/"$SYS"/
mcopy -sQ -i "$P2" "$WORK/iso/.disk" ::/"$SYS"/.disk

# меню загрузки: система лежит не в /casper, а в <ИМЯ>/sys (параметр live-media-path)
LMP="live-media-path=/$SYS"
cat > "$WORK/grub.cfg" <<EOF
set default=0
set timeout=8
insmod all_video
insmod gfxterm
terminal_output console

menuentry "$OS_NAME - Start (saves root + user on the USB drive)" {
  linux /$SYS/vmlinuz boot=casper $LMP persistent quiet ---
  initrd /$SYS/initrd
}
menuentry "$OS_NAME - Guest mode (nothing is saved)" {
  linux /$SYS/vmlinuz boot=casper $LMP quiet ---
  initrd /$SYS/initrd
}
menuentry "$OS_NAME - Compatibility mode (simple graphics, no effects)" {
  linux /$SYS/vmlinuz boot=casper $LMP persistent rectless.gfx=1 quiet ---
  initrd /$SYS/initrd
}
menuentry "$OS_NAME - Safe graphics (nomodeset)" {
  linux /$SYS/vmlinuz boot=casper $LMP persistent nomodeset ---
  initrd /$SYS/initrd
}
menuentry "$OS_NAME - Load into RAM (you can unplug the USB drive)" {
  linux /$SYS/vmlinuz boot=casper $LMP toram quiet ---
  initrd /$SYS/initrd
}
EOF
mcopy -Q -i "$P2" "$WORK/grub.cfg" ::/"$SYS"/boot/grub/grub.cfg

# значок флешки в Windows и описание схемы
ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../assets" 2>/dev/null && pwd || true)"
if [ -n "$ASSETS" ] && [ -f "$ASSETS/$OS_NAME.ico" ]; then
  mcopy -Q -i "$P2" "$ASSETS/$OS_NAME.ico" "$ASSETS/autorun.inf" ::/ 2>/dev/null || true
fi
cat > "$WORK/README.txt" <<EOF
$OS_NAME - загрузочная флешка.

  sys   (этот раздел, папка $OS_NAME/sys) - система, только чтение
  root  (раздел $OS_NAME-root, ext4)      - настройки и установленные программы
  user  (раздел $OS_NAME-user, ext4)      - твои файлы (домашняя папка)

Загружайся с флешки (меню выбора загрузки BIOS/UEFI: F12, F11, Esc или F8).
Раздел sys не трогай: удаление или изменение файлов в нём сломает загрузку.
EOF
mcopy -Q -i "$P2" "$WORK/README.txt" ::/"$OS_NAME"/README.txt

echo "Ставлю загрузчик (UEFI и BIOS)..."
cat > "$WORK/embedded.cfg" <<EOF
search --no-floppy --file --set=root /$SYS/filesystem.squashfs
set prefix=(\$root)/$SYS/boot/grub
configfile (\$root)/$SYS/boot/grub/grub.cfg
EOF

# UEFI: один самодостаточный файл по стандартному пути EFI/BOOT/BOOTX64.EFI
grub-mkstandalone -O x86_64-efi \
  --modules="part_gpt part_msdos fat ext2 normal search search_fs_file configfile linux all_video gfxterm echo test" \
  -o "$WORK/BOOTX64.EFI" "boot/grub/grub.cfg=$WORK/embedded.cfg" >/dev/null 2>&1
mcopy -Q -i "$P2" "$WORK/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

# BIOS: маленькое ядро в BIOS-boot разделе, остальные модули грузит с FAT
mkdir "$WORK/bios"
cp /usr/lib/grub/i386-pc/boot.img "$WORK/bios/boot.img"
grub-mkimage -O i386-pc -o "$WORK/bios/core.img" -c "$WORK/embedded.cfg" -p "/$SYS/boot/grub" \
  biosdisk part_gpt fat search search_fs_file configfile normal >/dev/null 2>&1
mcopy -Q -i "$P2" /usr/lib/grub/i386-pc/*.mod /usr/lib/grub/i386-pc/*.lst ::/"$SYS"/boot/grub/i386-pc/ 2>/dev/null
BIOS_START="$(sgdisk -i 1 "$DEV" | awk '/First sector/{print $3}')"
if ! BIOSERR="$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/bios-embed.py" "$DEV" "$WORK/bios/boot.img" "$WORK/bios/core.img" "$BIOS_START" 2>&1)"; then
  echo
  echo "Не удалось поставить BIOS-загрузчик (UEFI-загрузка при этом будет работать):"
  echo "$BIOSERR" | tail -3
fi

sync
echo
echo "Готово! Флешка записана: загрузка в UEFI и BIOS."
lsblk -o NAME,SIZE,LABEL,PARTLABEL "$DEV" 2>/dev/null | sed 's/^/  /' || true
echo "При загрузке выбери первый пункт меню (с сохранением)."
