#!/usr/bin/env bash
# 第二段：把拼好的系统装进磁盘镜像，然后无头开机，存下控制台日志
# 用法：  pkexec bash ~/拼装/本轮B-做镜像和开机.sh
set -u
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
B=$ROOT/构建
SRC=$B/kernel-rootfs
IMG=$B/系统.img
LOG=$B/开机日志.txt
step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

[ -d "$SRC" ] || { echo "✘ 没有 $SRC，先跑 A 段"; exit 1; }

step "1/3 把根文件系统写进 ext4 镜像"
rm -f "$IMG"
truncate -s 4G "$IMG"
mke2fs -t ext4 -q -F -d "$SRC" "$IMG" || { echo "  ✘ mke2fs 失败"; exit 1; }
echo "  $(ls -lh "$IMG" | awk '{print $5}')  $IMG"
echo "  实际占用 $(du -h --apparent-size "$SRC" | cut -f1)"

step "2/3 无头开机（最长等 130 秒，起来后会自动被超时掐掉）"
K=$(ls "$SRC"/boot/vmlinuz-* 2>/dev/null | head -1)
I=$(ls "$SRC"/boot/initrd.img-* 2>/dev/null | head -1)
echo "  内核   $(basename "$K")"
echo "  初始盘 $(basename "$I")"
: > "$LOG"
timeout 130 qemu-system-x86_64 \
    -m 1024 -smp 2 -nographic -no-reboot \
    -kernel "$K" -initrd "$I" \
    -append "root=/dev/sda rw console=ttyS0,115200" \
    -drive "file=$IMG,format=raw,if=ide" >> "$LOG" 2>&1
echo "  QEMU 退出码 $?（124 = 被超时掐掉，说明它一直在正常运行）"

step "3/3 开机日志判读"
echo "  日志 $(wc -l < "$LOG") 行"
echo
echo "  ── 有没有走到"多用户" ──"
grep -aE "Reached target (Multi-User|Graphical)|Startup finished|Welcome to|login:" "$LOG" | tail -8 | sed 's/^/    /' || echo "    （没有）"
echo
echo "  ── 有没有内核 panic / 起不来 ──"
grep -aiE "kernel panic|Cannot open|not found|Failed to mount|VFS:|No working init" "$LOG" | head -8 | sed 's/^/    /' || echo "    ✔ 没有"
echo
echo "  ── 日志最后 30 行 ──"
tail -30 "$LOG" | sed 's/^/    /'

chown -R 1000:1000 "$B" 2>/dev/null
echo
echo "════ B 段结束 ════"; date '+  %H:%M:%S'
