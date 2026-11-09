#!/usr/bin/env bash
# Builds the QEMU guest agent natively for Windows on ARM64 and packages it
# with every DLL it loads. Run inside MSYS2's CLANGARM64 shell on Windows 11
# ARM64 (our own Windows VM works):
#
#   C:\msys64\usr\bin\env.exe MSYSTEM=CLANGARM64 /usr/bin/bash -lc /c/path/build.sh
#
# Why this exists: virtio-win ships qemu-ga only for x86/x64. The x64 MSI fails
# on ARM64 (1603, its VSS COM registration goes through an x64 rundll32), and
# without VSS there is no fsfreeze. This build has both.
set -euo pipefail

QEMU_VERSION=${QEMU_VERSION:-11.1.3}
WORK=${WORK:-/c/build}
OUT=$WORK/qemu-ga-$QEMU_VERSION-windows-arm64

# binutils (msys) supplies windmc, which LLVM lacks — MSYS2's own qemu recipe does the same.
pacman -S --noconfirm --needed make diffutils tar binutils \
  mingw-w64-clang-aarch64-{clang,meson,ninja,pkgconf,glib2,tools,python,python-setuptools,python-wheel,python-pip}

mkdir -p "$WORK" && cd "$WORK"
[[ -f qemu-$QEMU_VERSION.tar.xz ]] || curl -sSLO "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz"
# Symlinks under tests/ and roms/ cannot be created on NTFS; nothing we build needs them.
[[ -d qemu-$QEMU_VERSION ]] || tar xf "qemu-$QEMU_VERSION.tar.xz" || true

mkdir -p "qemu-$QEMU_VERSION/b" && cd "qemu-$QEMU_VERSION/b"
../configure --disable-system --disable-user --disable-tools --disable-docs \
  --enable-guest-agent --enable-qga-vss --disable-werror --disable-download
ninja qga/qemu-ga.exe qga/vss-win32/qga-vss.dll

rm -rf "$OUT" && mkdir -p "$OUT"
cp qga/qemu-ga.exe qga/vss-win32/qga-vss.dll "$OUT/"
widl -I/clangarm64/include -t ../qga/vss-win32/qga-vss.idl -o "$OUT/qga-vss.tlb"

# Copy every DLL from /clangarm64/bin that anything in the package imports, until
# nothing new turns up. Read the import tables directly: ldd (an x64 msys tool)
# misses some of them, which is how libc++.dll went missing and VSS silently died.
while :; do
  added=0
  for f in "$OUT"/*.exe "$OUT"/*.dll; do
    for d in $(llvm-objdump -p "$f" | awk '/DLL Name/ {print $3}'); do
      if [[ -f /clangarm64/bin/$d && ! -f $OUT/$d ]]; then cp "/clangarm64/bin/$d" "$OUT/"; added=1; fi
    done
  done
  [[ $added == 0 ]] && break
done
# glib spawns processes through these helpers; they are executed, never imported,
# so no import table lists them. Without them guest-exec fails with
# "Failed to execute helper program".
cp /clangarm64/bin/gspawn-win64-helper*.exe "$OUT/"

cp ../COPYING "$OUT/COPYING-qemu.txt"
echo "QEMU guest agent $QEMU_VERSION, built from https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz with scripts/qemu-ga-windows-arm64/build.sh" > "$OUT/SOURCE.txt"

cd "$WORK" && rm -f "$OUT.zip"
# Windows' bsdtar writes a zip with -a; it avoids depending on a zip package.
/c/Windows/System32/tar.exe -a -c -f "$(cygpath -w "$OUT.zip")" -C "$(cygpath -w "$WORK")" "$(basename "$OUT")"
ls -la "$OUT.zip"
