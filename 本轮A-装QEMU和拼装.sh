#!/usr/bin/env bash
# 第一段：装 QEMU + 拼一个带内核的系统
# 用法：  pkexec bash ~/拼装/本轮A-装QEMU和拼装.sh
set -u
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
B=$ROOT/构建
step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

step "1/3 装 QEMU"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "  已经装了：$(qemu-system-x86_64 --version | head -1)"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        qemu-system-x86 qemu-utils || { echo "  ✘ 装失败"; exit 1; }
    echo "  $(qemu-system-x86_64 --version | head -1)"
fi

step "2/3 拼 BASE + KERNEL"
export PATH="$ROOT/工具/usr/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export SELECT=BASE,KERNEL
bash "$ROOT/拼装.sh" kernel-rootfs trixie
[ -d "$B/kernel-rootfs" ] || { echo "  ✘ 没产出"; exit 1; }

step "3/3 关键件核对"
echo "  ── /boot ──"
ls -lh "$B/kernel-rootfs/boot/" 2>/dev/null | sed 's/^/    /'
echo "  ── /sbin/init 指向谁 ──"
ls -l "$B/kernel-rootfs/sbin/init" 2>&1 | sed 's/^/    /'
echo "  ── 装了哪些关键包 ──"
chroot "$B/kernel-rootfs" dpkg-query -W -f='${Package} ${Version}\n' \
    systemd systemd-sysv kmod iproute2 e2fsprogs linux-image-amd64 2>/dev/null | sed 's/^/    /'
echo "  ── 总包数 ──"
echo "    $(grep -c '^Package: ' "$B/kernel-rootfs/var/lib/dpkg/status")"

chown -R 1000:1000 "$B" 2>/dev/null
export DISPLAY=:0 XAUTHORITY="$UH/.Xauthority"
echo
echo "════ A 段结束 ════"; date '+  %H:%M:%S'
