#!/usr/bin/env bash
# B 的收尾：网络 + 时区 + 开机自报数（给 D 用）
#
# 用法：  pkexec bash ~/拼装/收尾.sh
#
# 一样套 cgroup 护栏、一样造私有 /dev
set -u
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
R=$ROOT/构建/kernel-rootfs
MEMCAP="${MEMCAP:-4G}"; SWAPCAP="${SWAPCAP:-2G}"; CPUQUOTA="${CPUQUOTA:-250%}"
IOWEIGHT="${IOWEIGHT:-40}"; MINFREE="${MINFREE:-2500}"; INNER="${INNER:-240}"
step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

if [ "${DSH_LIMITED:-0}" != "1" ]; then
    command -v systemd-run >/dev/null || { echo "✗ 没有 systemd-run，不跑"; exit 1; }
    echo "── 套 cgroup 上限：内存 $MEMCAP｜交换 $SWAPCAP｜CPU $CPUQUOTA｜IOWeight $IOWEIGHT ──"
    exec systemd-run --scope --quiet --collect --unit="dsh-finish-$$" \
        -p MemoryMax="$MEMCAP" -p MemorySwapMax="$SWAPCAP" \
        -p CPUQuota="$CPUQUOTA" -p IOWeight="$IOWEIGHT" -p CPUWeight="$IOWEIGHT" \
        --setenv=DSH_LIMITED=1 -- bash "$0" "$@"
fi
avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
echo "── 可用内存 ${avail} MB（门槛 ${MINFREE}）──"
[ "$avail" -ge "$MINFREE" ] || { echo "✗ 内存不够，不跑"; exit 3; }
[ -d "$R" ] || { echo "✗ 没有 $R"; exit 1; }

cleanup() { for m in $(awk -v r="$R/" 'index($2,r)==1 {print $2}' /proc/self/mounts | sort -r); do umount -l "$m" 2>/dev/null; done; }
trap cleanup EXIT
cleanup

# ══════════ 1. 时区 / 主机名 等纯文件改动（不用 chroot）══════════
step "1/4 时区、主机名、清掉上一轮的截图残渣"
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$R/etc/localtime"
echo "Asia/Shanghai" > "$R/etc/timezone"
echo "dshos" > "$R/etc/hostname"
rm -f /var/tmp/dshshot*.ppm
echo "  时区 → $(readlink "$R/etc/localtime" | sed 's|.*/zoneinfo/||')"

# ══════════ 2. 网络：systemd-networkd + resolved（不用装重型 NM）══════════
step "2/4 写网络配置（DHCP，认 en*/eth* 网卡）"
mkdir -p "$R/etc/systemd/network"
cat > "$R/etc/systemd/network/20-wired.network" <<'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes
EOF
cat > "$R/etc/systemd/resolved.conf.d-dsh.conf" 2>/dev/null <<'EOF'
EOF
rm -f "$R/etc/systemd/resolved.conf.d-dsh.conf"
mkdir -p "$R/etc/systemd/resolved.conf.d"
cat > "$R/etc/systemd/resolved.conf.d/10-dsh.conf" <<'EOF'
[Resolve]
DNS=223.5.5.5 1.1.1.1
FallbackDNS=8.8.8.8
EOF
echo "  写好了：/etc/systemd/network/20-wired.network、resolved 的 DNS"

# ══════════ 3. 开机自报数（给 D 用）══════════
step "3/4 装开机自报数单元"
cat > "$R/usr/local/bin/dsh-报数.sh" <<'EOF'
#!/bin/bash
# 开机后自己把各项数字打到串口控制台（console=ttyS0），
# 这样不用登录也能读到 —— 给「和 Mint 对比」那一步用。
sleep 50                       # 等桌面画完、系统静下来
{
  echo ""
  echo "===DSH-REPORT-BEGIN==="
  echo "主机名        $(hostname)"
  echo "发行版        $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "内核          $(uname -r)"
  echo "包数          $(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)"
  echo "进程数        $(ps -e --no-headers 2>/dev/null | wc -l)"
  echo "内存总量_MB   $(free -m | awk '/^Mem:/{print $2}')"
  echo "内存已用_MB   $(free -m | awk '/^Mem:/{print $3}')"
  echo "内存可用_MB   $(free -m | awk '/^Mem:/{print $7}')"
  echo "swap已用_MB   $(free -m | awk '/^Swap:/{print $3}')"
  echo "开机耗时      $(systemd-analyze 2>/dev/null | head -1)"
  echo "uptime_秒     $(cut -d. -f1 /proc/uptime)"
  echo "--- 桌面进程 ---"
  pgrep -a xfwm4 2>/dev/null | head -1
  pgrep -a xfdesktop 2>/dev/null | head -1
  pgrep -a xfce4-panel 2>/dev/null | head -1
  echo "--- 网络 ---"
  ip -4 -o addr show 2>/dev/null | awk '{print "  "$2" "$4}' | head -5
  ip route 2>/dev/null | head -3
  echo "--- systemd 失败单元 ---"
  systemctl --failed --no-legend 2>/dev/null | head -8
  echo "===DSH-REPORT-END==="
} > /dev/console 2>&1
EOF
chmod 755 "$R/usr/local/bin/dsh-报数.sh"
cat > "$R/etc/systemd/system/dsh-report.service" <<'EOF'
[Unit]
Description=DSH build self report
After=graphical.target
Wants=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dsh-报数.sh
TimeoutStartSec=300

[Install]
WantedBy=graphical.target
EOF
echo "  自报数脚本 + dsh-report.service 已就位"

# ══════════ 4. 进 chroot 装 resolved + 开服务 ══════════
step "4/4 装 systemd-resolved、开 networkd/resolved/自报数"
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
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 755 "$R/usr/sbin/policy-rc.d"

timeout "$INNER" chroot "$R" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a
  apt-get -f install -y
  apt-get update -qq
  apt-get install -y --no-install-recommends systemd-resolved iproute2
  echo "--- 开服务 ---"
  systemctl enable systemd-networkd 2>&1 | tail -1
  systemctl enable systemd-resolved 2>&1 | tail -1
  systemctl enable dsh-report.service 2>&1 | tail -1
  systemctl enable lightdm 2>&1 | tail -1
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  echo "  resolv.conf → $(readlink /etc/resolv.conf)"
  systemctl set-default graphical.target 2>&1 | tail -1
  apt-get clean; rm -rf /var/lib/apt/lists/*
' 2>&1 | grep -vE "^(Get|Fetched|Reading|Building|Selecting|Preparing|Unpacking|Setting up|Processing)" | sed 's/^/  /'
rc=$?

cleanup
echo
echo "── 结果 (退出码 $rc) ──"
echo "  包数 $(grep -c '^Package: ' "$R/var/lib/dpkg/status")"
echo "  占用 $(du -sh --exclude=proc --exclude=sys --exclude=dev --exclude=run "$R" 2>/dev/null | cut -f1)"
echo "  开机自启单元（enabled）："
find "$R/etc/systemd/system" -name '*.wants' -maxdepth 3 2>/dev/null | while read -r d; do
  ls "$d" 2>/dev/null | grep -E "networkd|resolved|lightdm|dsh-report" | sed "s|^|    $(basename "$(dirname "$d")")/|"
done
chown -R 1000:1000 "$R" 2>/dev/null
echo; echo "════ 收尾结束 ════"; date '+  %H:%M:%S'
exit $rc
