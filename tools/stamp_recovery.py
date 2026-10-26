#!/usr/bin/env python3
"""Copy the boot patch level (header os_version) of a ROM's init_boot.img (or
boot.img) into a TWRP recovery image and redo its AVB hash footer.

TWRP's override-spl.sh refuses to start KeyMint when its own header differs
from the installed init_boot ("Boot patch level mismatch"), because the
bootloader hands that value to KeyMint and the keys would need rewriting.

usage: stamp_recovery.py RECOVERY.img INIT_BOOT.img OUT.img
       stamp_recovery.py RECOVERY.img 0x1e0001a3 OUT.img
"""
import os, struct, subprocess, sys

AVBTOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'avbtool.py')
PARTITION_SIZE = 104857600  # Nord 6 recovery_a/_b


def os_version(path):
    hdr = open(path, 'rb').read(64)
    assert hdr[:8] == b'ANDROID!', '%s is not a boot image' % path
    return struct.unpack_from('<I', hdr, 16)[0]


def describe(v):
    ver, p = v >> 11, v & 0x7ff
    return '%d.%d.%d / %d-%02d' % (ver >> 14, (ver >> 7) & 0x7f, ver & 0x7f, 2000 + (p >> 4), p & 0xf)


src, ref, dst = sys.argv[1:4]
new = int(ref, 16) if ref.startswith('0x') else os_version(ref)
assert new, 'reference header has no os_version; use the ROM boot.img instead'
img = bytearray(open(src, 'rb').read())
info = subprocess.run([sys.executable, AVBTOOL, 'info_image', '--image', src],
                      capture_output=True, text=True).stdout
orig = next((int(l.split(':')[1].split()[0]) for l in info.splitlines()
             if l.startswith('Original image size')), len(img))
print('old', describe(os_version(src)), '-> new', describe(new))
struct.pack_into('<I', img, 16, new)
open(dst, 'wb').write(bytes(img[:orig]))
subprocess.run([sys.executable, AVBTOOL, 'add_hash_footer', '--image', dst,
                '--partition_size', str(PARTITION_SIZE), '--partition_name', 'recovery',
                '--algorithm', 'NONE'], check=True)
print('wrote', dst)
