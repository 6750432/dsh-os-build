#!/usr/bin/env bash
# 一步到位：装 QEMU → 拼一个带内核的系统 → 做成磁盘镜像 → 无头开机 → 存控制台日志
# 用法：  pkexec bash ~/拼装/本轮-开机.sh
#
# 输出全部写进 ~/拼装/构建/本轮.log（外面用 tail -f 看）

set -u
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
B=$ROOT/构建

step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

step "0/5 环境"
echo "  uid=$(id -u)  谁在跑=$(id -un)"

step "1/5 装 QEMU（宿主上就要用，以后 Windows 直通也靠它）"
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    echo "  已经装了：$(qemu-system-x86_64 --version | head -1)"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        qemu-system-x86 qemu-utils || { echo "  ✘ 装失败"; exit 1; }
    echo "  $(qemu-system-x86_64 --version | head -1)"
fi

step "2/5 拼一个带内核的系统（BASE + KERNEL）"
export PATH="$ROOT/工具/usr/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin"
export SELECT=BASE,KERNEL
bash "$ROOT/拼装.sh" kernel-rootfs trixie
if [ ! -d "$B/kernel-rootfs" ]; then echo "  ✘ 没产出，停"; exit 1; fi
echo "  ── /boot 里有什么 ──"
ls -lh "$B/kernel-rootfs/boot/" | sed 's/^/    /'

step "3/5 /sbin/init 是谁（决定能不能真开机）"
ls -l "$B/kernel-rootfs/sbin/init" 2>&1 | sed 's/^/    /'
chroot "$B/kernel-rootfs" bash -c 'dpkg -l systemd systemd-sysv init 2>/dev/null | grep ^ii | awk "{print \$2, \$3}"' 2>&1 | sed 's/^/    /'

step "4/5 把根文件系统装进一块 ext4 磁盘镜像"
IMG=$B/系统.img
rm -f "$IMG"
truncate -s 4G "$IMG"
mke2fs -t ext4 -q -F -d "$B/kernel-rootfs" "$IMG" || { echo "  ✘ mke2fs 失败"; exit 1; }
ls -lh "$IMG" | sed 's/^/    /'

step "5/5 无头开机（最多等 180 秒）"
K=$(ls "$B/kernel-rootfs/boot/vmlinuz-"* 2>/dev/null | head -1)
I=$(ls "$B/kernel-rootfs/boot/initrd.img-"* 2>/dev/null | head -1)
echo "  内核  $K"
echo "  初始盘 $I"
if [ -z "$K" ] || [ -z "$I" ]; then
    echo "  ✘ 缺内核或 initrd，开不了机"
else
    timeout 200 qemu-system-x86_64 -m 1024 -smp 2 -nographic -no-reboot \
        -kernel "$K" -initrd "$I" \
        # 注：下面 append 里的那个根设备是**客机内部**的（-drive if=ide 的第一块盘），
        #     与宿主的分区无关；宿主用哪个盘由 QEMU 的 -drive 决定。
        -append "root=/dev/sda rw console=ttyS0,115200" \
        -drive "file=$IMG,format=raw,if=ide" \
        > "$B/开机日志.txt" 2>&1
    echo "  QEMU 退出（$?）"
    echo "  ── 控制台日志最后 45 行 ──"
    tail -45 "$B/开机日志.txt" | sed 's/^/    /'
fi

step "收尾：把产物还给普通用户"
chown -R 1000:1000 "$B" 2>/dev/null
echo "════ 全流程结束 ════"
date '+  %H:%M:%S'
