#!/usr/bin/env bash
# Build a bootable CBAP OS live ISO from a DSH/CBAP rootfs.
#
# This is intentionally rootless: the rootfs is copied to a workspace, the
# CBAP runtime layer is installed there, and squashfs/grub-mkrescue run as the
# normal user. No host mounts are touched.
#
# Usage:
#   bash cbap-os/iso/build-iso.sh \
#     --rootfs ~/拼装/构建/kernel-rootfs \
#     --cbap-src ~/cyberdyne-bridge \
#     --output ~/拼装/构建/CBAP-OS.iso
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOTFS="${HOME}/拼装/构建/kernel-rootfs"
OUTPUT="${HOME}/拼装/构建/CBAP-OS.iso"
WORK="${HOME}/拼装/构建/cbap-iso"
CBAP_SRC=""
CBAP_VERSION="v1.4.0"
SKIP_INSTALL=0
KEEP_WORK=0

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --rootfs) ROOTFS="${2:?}"; shift 2 ;;
        --output) OUTPUT="${2:?}"; shift 2 ;;
        --work) WORK="${2:?}"; shift 2 ;;
        --cbap-src) CBAP_SRC="${2:?}"; shift 2 ;;
        --cbap-version) CBAP_VERSION="${2:?}"; shift 2 ;;
        --skip-install) SKIP_INSTALL=1; shift ;;
        --keep-work) KEEP_WORK=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

for c in cpio gzip mksquashfs grub-mkrescue xorriso mformat mcopy; do
    command -v "$c" >/dev/null || {
        echo "missing tool: $c" >&2
        echo "required: mtools, grub-pc-bin, grub-efi-amd64-bin, xorriso, squashfs-tools, cpio, busybox-static" >&2
        exit 1
    }
done
[ -d "$ROOTFS" ] || { echo "rootfs not found: $ROOTFS" >&2; exit 1; }
[ -x /usr/bin/busybox ] || { echo "host busybox-static is required" >&2; exit 1; }

say() { printf '\n▶ %s\n' "$*"; }
say "workspace: $WORK"
rm -rf "$WORK"
mkdir -p "$WORK"/{root,initrd,iso/boot/grub,iso/casper}

say "copying rootfs (this can take a while)"
cp -a --reflink=auto "$ROOTFS"/. "$WORK/root"/

if [ "$SKIP_INSTALL" -eq 0 ]; then
    say "installing CBAP OS runtime layer"
    SRC_ARGS=()
    [ -n "$CBAP_SRC" ] && SRC_ARGS=(--cbap-src "$CBAP_SRC")
    bash "$HERE/../install.sh" --root "$WORK/root" \
        --cbap-version "$CBAP_VERSION" "${SRC_ARGS[@]}"
fi

# The ISO is built without root. The installer may not be able to chown the
# runtime state directory to uid 997; make it writable for the live session.
chmod 0777 "$WORK/root/var/lib/cbap" 2>/dev/null || true

say "setting live identity"
echo cbapos > "$WORK/root/etc/hostname"
if grep -q '^127.0.1.1' "$WORK/root/etc/hosts" 2>/dev/null; then
    sed -i 's/^127.0.1.1.*/127.0.1.1  cbapos/' "$WORK/root/etc/hosts"
else
    echo '127.0.1.1  cbapos' >> "$WORK/root/etc/hosts"
fi
cat > "$WORK/root/etc/os-release" <<'EOF'
PRETTY_NAME="CBAP OS 0.1 (live)"
NAME="CBAP OS"
VERSION_ID="0.1"
VERSION="0.1 (trixie, live)"
ID=cbapos
ID_LIKE=debian
HOME_URL="https://github.com/6750432/dsh-os-build"
EOF
printf 'CBAP OS 0.1 (live) \\n \\l\n\n' > "$WORK/root/etc/issue"

KERNEL="$(ls "$WORK/root"/boot/vmlinuz-* | head -1)"
KVER="$(basename "$KERNEL" | sed 's/^vmlinuz-//')"
[ -n "$KVER" ] || { echo "no kernel modules" >&2; exit 1; }
[ -r "$KERNEL" ] || { echo "no kernel" >&2; exit 1; }
say "kernel: $KVER"

say "building a minimal live initramfs"
I="$WORK/initrd"
mkdir -p "$I"/{bin,sbin,proc,sys,dev,run,tmp,lib/modules}
cp /usr/bin/busybox "$I/bin/busybox"
for applet in sh mount umount mkdir sleep cat echo ls modprobe switch_root; do
    ln -sf busybox "$I/bin/$applet"
done
cp "$HERE/init" "$I/init"
chmod 0755 "$I/init"
cp -a "$WORK/root/lib/modules/$KVER" "$I/lib/modules/"
(cd "$I" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$WORK/initrd.img")
ls -lh "$WORK/initrd.img"

say "copying boot files and making squashfs"
cp "$KERNEL" "$WORK/iso/boot/vmlinuz"
cp "$WORK/initrd.img" "$WORK/iso/boot/initrd.img"
mksquashfs "$WORK/root" "$WORK/iso/casper/filesystem.squashfs" \
    -noappend -comp zstd -Xcompression-level 3 -processors 2

# Build one GRUB entry per installed CBAP slot. The ISO boot selector is
# GRUB itself, so the systemd tty1 menu is suppressed with cbap.nomenu.
PYV="$(find "$WORK/root/opt/cbap-os/versions/python" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -V | tail -1)"
CBAP_VERS="$(find "$WORK/root/opt/cbap-os/versions/cbap" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -rV)"
{
    echo 'set timeout=10'
    echo 'set default=0'
    echo 'insmod all_video'
    echo
    for v in $CBAP_VERS; do
        echo "menuentry \"CBAP OS 0.1 — CBAP $v / Python $PYV\" {"
        echo "    linux /boot/vmlinuz root=/dev/ram0 rw console=tty0 console=ttyS0,115200 cbap.cbap=$v cbap.python=$PYV cbap.nomenu"
        echo '    initrd /boot/initrd.img'
        echo '}'
        echo
    done
} > "$WORK/iso/boot/grub/grub.cfg"

say "creating ISO with grub-mkrescue"
rm -f "$OUTPUT"
grub-mkrescue -o "$OUTPUT" "$WORK/iso" \
    -- -volid CBAP_OS 2>&1 | tail -20

[ -f "$OUTPUT" ] || { echo "ISO was not created" >&2; exit 1; }
ls -lh "$OUTPUT"
sha256sum "$OUTPUT"
if [ "$KEEP_WORK" -eq 0 ]; then
    rm -rf "$WORK"
fi
say "done: $OUTPUT"
