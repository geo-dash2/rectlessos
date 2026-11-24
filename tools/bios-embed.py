#!/usr/bin/env python3
"""Ставит загрузчик GRUB для старого BIOS на GPT-диск без grub-install.

Делает то же, что grub-bios-setup, но без угадывания диска:
  * core.img записывается в начало раздела bios-boot (раздел 1, тип EF02);
  * boot.img (первые 440 байт MBR) указывает на этот сектор;
  * таблица разделов (байты 440..511) не трогается.

Использование: bios-embed.py <устройство> <boot.img> <core.img> <первый_сектор_раздела_bios-boot>
"""
import struct
import sys

dev, boot_path, core_path, start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

boot = bytearray(open(boot_path, "rb").read())
core = bytearray(open(core_path, "rb").read())
assert len(boot) == 512, "boot.img должен быть 512 байт"
if len(core) % 512:
    core += b"\0" * (512 - len(core) % 512)
nsec = len(core) // 512
if nsec > 8 * 2048 - 2:
    sys.exit("core.img не помещается в раздел bios-boot")

# boot.img: номер сектора, с которого начинается core.img (смещение 0x5c)
boot[0x5C:0x64] = struct.pack("<Q", start)
# последние 12 байт первого сектора core.img: список блоков остальной части
# (старт, число секторов, сегмент загрузки 0x820)
core[500:512] = struct.pack("<QHH", start + 1, nsec - 1, 0x820)

with open(dev, "r+b") as f:
    f.seek(start * 512)
    f.write(core)
    f.seek(0)
    mbr = bytearray(f.read(512))
    mbr[0:440] = boot[0:440]
    mbr[446] |= 0x80          # активный флаг у защитной записи: часть BIOS без него не грузится
    f.seek(0)
    f.write(mbr)
    f.flush()
print(f"BIOS-загрузчик записан: core.img = {nsec} секторов с LBA {start}")
