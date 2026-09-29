#!/usr/bin/env bash
# A 段：把装了 XFCE 的 rootfs 做成镜像 → 开 KVM 起 QEMU → 截一张桌面的图
#
# 用法：  pkexec bash ~/拼装/本轮A-开机看桌面.sh
#
# 安全设计（跟 加包.sh 同一套护栏）：
#   · 整个流程套进 systemd cgroup：内存 4G / 交换 2G / CPU 250% / IOWeight 40
#   · 开跑前查 MemAvailable，不够就拒绝
#   · QEMU 自己再限 -m 1024
set -u

UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
B=$ROOT/构建
R=$B/kernel-rootfs
IMG=$B/桌面版.img
LOG=$B/桌面开机日志.txt
SHOT=$B/桌面截图.ppm
MON=$B/qemu-mon.sock
MEMCAP="${MEMCAP:-4G}"; SWAPCAP="${SWAPCAP:-2G}"
CPUQUOTA="${CPUQUOTA:-250%}"; IOWEIGHT="${IOWEIGHT:-40}"
MINFREE="${MINFREE:-2500}"

step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

# ── 护栏②：套 cgroup ──
if [ "${DSH_LIMITED:-0}" != "1" ]; then
    if command -v systemd-run >/dev/null 2>&1; then
        echo "── 套 cgroup 上限：内存 $MEMCAP｜交换 $SWAPCAP｜CPU $CPUQUOTA｜IOWeight $IOWEIGHT ──"
        exec systemd-run --scope --quiet --collect --unit="dsh-desktop-$$" \
            -p MemoryMax="$MEMCAP" -p MemorySwapMax="$SWAPCAP" \
            -p CPUQuota="$CPUQUOTA" -p IOWeight="$IOWEIGHT" -p CPUWeight="$IOWEIGHT" \
            --setenv=DSH_LIMITED=1 -- bash "$0" "$@"
    else
        echo "✗ 没有 systemd-run，不跑"; exit 1
    fi
fi

# ── 护栏③：内存体检 ──
avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
echo "── 可用内存 ${avail} MB（门槛 ${MINFREE}）──"
[ "$avail" -ge "$MINFREE" ] || { echo "✗ 内存不够，不跑"; exit 3; }

[ -d "$R" ] || { echo "✗ 没有 $R"; exit 1; }

# ══════════ 1. 让系统有个能登录的用户 + lightdm 自动登进去 ══════════
step "1/6 造用户 dsh、打开 lightdm 自动登录"
cleanup_mnt() { for m in $(awk -v r="$R/" 'index($2,r)==1 {print $2}' /proc/self/mounts | sort -r); do umount -l "$m" 2>/dev/null; done; }
trap cleanup_mnt EXIT
cleanup_mnt
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/run"
mount -t tmpfs -o mode=755,size=64M tmpfs "$R/dev"
mkdir -p "$R/dev/pts" "$R/dev/shm"
mount -t tmpfs -o mode=1777,size=256M tmpfs "$R/dev/shm"
mknod -m 666 "$R/dev/null" c 1 3; mknod -m 666 "$R/dev/zero" c 1 5
mknod -m 666 "$R/dev/random" c 1 8; mknod -m 666 "$R/dev/urandom" c 1 9
mknod -m 666 "$R/dev/tty" c 5 0
mount -t proc proc "$R/proc"; mount -t sysfs sysfs "$R/sys"
mount -t tmpfs -o mode=755,size=32M tmpfs "$R/run"
cp -f /etc/resolv.conf "$R/etc/resolv.conf"

chroot "$R" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  id dsh >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,audio,video,plugdev,netdev dsh
  echo "dsh:dsh" | chpasswd
  echo "root:root"  | chpasswd
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<EOF
[Seat:*]
autologin-user=dsh
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
EOF
  groupadd -f autologin; usermod -aG autologin dsh
  echo "exec startxfce4" > /home/dsh/.xinitrc; chown dsh:dsh /home/dsh/.xinitrc
  systemctl enable lightdm 2>&1 | tail -2
  systemctl set-default graphical.target 2>&1 | tail -1
  echo "  lightdm 服务链接：$(ls -l /etc/systemd/system/display-manager.service 2>/dev/null | sed "s/.*-> //")"
  echo "  xfce4-session 在不在：$(command -v startxfce4 || echo 缺)"
' 2>&1 | sed 's/^/  /'

cleanup_mnt

# ══════════ 2. 做镜像 ══════════
step "2/6 把根文件系统装进 ext4 镜像"
rm -f "$IMG"; truncate -s 8G "$IMG"
mke2fs -t ext4 -q -F -d "$R" "$IMG" || { echo "✗ mke2fs 失败"; exit 1; }
echo "  镜像 $(ls -lh "$IMG" | awk '{print $5}')（实占 $(du -h "$IMG" | cut -f1)）"

# ══════════ 3. 起 QEMU（KVM + 无显示 + 监控口）══════════
step "3/6 起 QEMU（KVM 加速，无图形窗口，用监控口截图）"
K=$(ls "$R"/boot/vmlinuz-* | head -1); I=$(ls "$R"/boot/initrd.img-* | head -1)
rm -f "$MON" "$SHOT" "$LOG"
qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
    -vga std -vnc 127.0.0.1:1 -no-reboot \
    -kernel "$K" -initrd "$I" \
    -append "root=/dev/sda rw console=ttyS0,115200 intel_iommu=on iommu=pt" \
    -drive "file=$IMG,format=raw,if=ide" \
    -serial "file:$LOG" \
    -nic user,model=e1000 \
    -qmp "unix:$MON,server,nowait" &
QPID=$!
echo "  QEMU pid=$QPID（内存上限 1024M，VNC 只监听 127.0.0.1:5901，监控走 QMP）"
sleep 5
if ! kill -0 $QPID 2>/dev/null; then echo "✗ QEMU 秒退了，看日志："; tail -15 "$LOG" | sed 's/^/    /'; exit 1; fi

# ══════════ 4. 等它开机 + 进桌面 ══════════
step "4/6 等它开机进 XFCE + 等自报数（固定等 115 秒）"
sleep 115
echo "  ── 串口日志要点 ──"
grep -aE "Welcome to|Reached target (Multi-User|Graphical)|Starting lightdm|DSH-REPORT" "$LOG" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | tail -8 | sed 's/^/    /'
echo
echo "  ── ★ 系统自报数（guest 自己打到串口的）──"
sed -n '/===DSH-REPORT-BEGIN===/,/===DSH-REPORT-END===/p' "$LOG" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'

# ══════════ 5. 截图（两张，隔 25 秒，免得第一张太早）═════════
step "5/6 截图（QMP + screendump；存到 ASCII 路径，避开中文路径被 QEMU 吃掉）"
shoot() {
    python3 - "$MON" "$1" <<'PY'
import json, socket, sys, time
mon, out = sys.argv[1], sys.argv[2]
buf = b""
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(20)
    s.connect(mon)
except Exception as e:
    print("    连不上 QMP：", e); sys.exit(0)
def line():
    global buf
    while b"\n" not in buf:
        buf += s.recv(65536)
    a, _, b = buf.partition(b"\n"); buf = b
    return a.decode(errors="replace")
try:
    line()                                                   # greeting
    s.sendall(b'{"execute":"qmp_capabilities"}\n'); line()    # 握手
    s.sendall(json.dumps({"execute": "screendump",
                          "arguments": {"filename": out}}).encode() + b"\n")
    print("    QMP 回话：", line()[:110])
    time.sleep(3)
except Exception as e:
    print("    出错：", e)
PY
}
rm -f /var/tmp/dshshot1.ppm /var/tmp/dshshot2.ppm
shoot /var/tmp/dshshot1.ppm
sleep 25
shoot /var/tmp/dshshot2.ppm
for n in 1 2; do
    [ -s "/var/tmp/dshshot$n.ppm" ] && cp -f "/var/tmp/dshshot$n.ppm" "$B/桌面截图-$n.ppm"
done
rm -f /var/tmp/dshshot*.ppm          # 顺手清掉 root 留下的临时截图（反正已拷走）
ls -lh "$B"/桌面截图-*.ppm 2>/dev/null | awk '{print "    "$5"  "$9}'
[ -s "$B/桌面截图-2.ppm" ] || echo "    ✗ 还是没截到"

# ══════════ 6. 收拾 ══════════
step "6/6 关掉 QEMU"
kill $QPID 2>/dev/null; sleep 3; kill -9 $QPID 2>/dev/null
rm -f "$MON"
echo "  ── 开机日志最后 12 行 ──"
tail -12 "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/    /'

chown -R 1000:1000 "$B" 2>/dev/null
echo; echo "════ A 段结束 ════"; date '+  %H:%M:%S'
