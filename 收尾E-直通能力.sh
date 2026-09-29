#!/usr/bin/env bash
# E 段：给 dsh 留好「Windows 分区直通（KVM/VFIO）」的能力
#
# 用法：  pkexec bash ~/拼装/收尾E-直通能力.sh
#
# 做四件事：
#   ① 装 QEMU / libvirt / virt-manager / OVMF / swtpm
#   ② 打开 IOMMU 启动参数：intel_iommu=on iommu=pt（写进 /etc/default/grub）
#   ③ 备好 vfio 配置（模块开机加载；显卡绑定那行**默认注释**，见文件里的说明）
#   ④ 把 dsh 加进 libvirt / kvm 组，开 libvirtd
set -u
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
R=$ROOT/构建/kernel-rootfs
MEMCAP="${MEMCAP:-4G}"; SWAPCAP="${SWAPCAP:-2G}"; CPUQUOTA="${CPUQUOTA:-250%}"
IOWEIGHT="${IOWEIGHT:-40}"; MINFREE="${MINFREE:-2500}"; INNER="${INNER:-420}"
step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

if [ "${DSH_LIMITED:-0}" != "1" ]; then
    command -v systemd-run >/dev/null || { echo "✗ 没有 systemd-run，不跑"; exit 1; }
    echo "── 套 cgroup 上限：内存 $MEMCAP｜交换 $SWAPCAP｜CPU $CPUQUOTA｜IOWeight $IOWEIGHT ──"
    exec systemd-run --scope --quiet --collect --unit="dsh-e-$$" \
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

# ══════════ ② 纯文件：grub 参数、vfio 配置（不用 chroot）══════════
step "1/3 写启动参数和 vfio 配置（纯文件）"
mkdir -p "$R/etc/default"
if [ -f "$R/etc/default/grub" ]; then
    sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"|' "$R/etc/default/grub"
else
    cat > "$R/etc/default/grub" <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="DSH OS"
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
GRUB_CMDLINE_LINUX=""
EOF
fi
echo "  /etc/default/grub → $(grep CMDLINE_LINUX_DEFAULT "$R/etc/default/grub")"

mkdir -p "$R/etc/modprobe.d" "$R/etc/modules-load.d"
cat > "$R/etc/modprobe.d/dsh-vfio.conf" <<'EOF'
# ── dsh：Windows 分区直通用 ──
#
# 这套机器上 RTX 2060 的 IOMMU 组（实测）：
#     组1  00:01.0  PCI bridge        ← 插槽自己的桥，一起给
#          01:00.0  RTX 2060         [10de:1f08]
#          01:00.1  HDMI Audio       [10de:10f7]
#          01:00.2  USB-C            [10de:1ada]
#          01:00.3  Serial bus       [10de:1adb]
# 组里没有别的东西，整组打包给虚拟机就行。
#
# 【默认不启用】下面这行一旦启用，dsh 在本机就**看不到 2060** 了
#   （桌面会退回核显 HD 530）。想真做直通时把开头的 # 去掉、重启即可。
#
# options vfio-pci ids=10de:1f08,10de:10f7,10de:1ada,10de:1adb disable_vga=1

# 让 nvidia/nouveau 排在 vfio-pci 后面（不做上面那行的话这两条也无害）
softdep nvidia  pre: vfio-pci
softdep nouveau pre: vfio-pci
EOF

cat > "$R/etc/modules-load.d/dsh-vfio.conf" <<'EOF'
# 开机就把 vfio 三件套加载好（只是加载模块，不占用任何设备）
vfio
vfio_iommu_type1
vfio_pci
EOF
echo "  /etc/modprobe.d/dsh-vfio.conf、/etc/modules-load.d/dsh-vfio.conf 写好了"

# ══════════ ③ 自报数里加上 IOMMU / cmdline 的检查 ══════════
step "2/3 给自报数加上「IOMMU 到底开没开」的检查"
cat > "$R/usr/local/bin/dsh-报数.sh" <<'EOF'
#!/bin/bash
sleep 50
{
  echo ""
  echo "===DSH-REPORT-BEGIN==="
  echo "主机名        $(hostname)"
  echo "发行版        $(. /etc/os-release; echo "$PRETTY_NAME")"
  echo "内核          $(uname -r)"
  echo "cmdline       $(cat /proc/cmdline)"
  echo "包数          $(dpkg-query -f '.\n' -W 2>/dev/null | wc -l)"
  echo "进程数        $(ps -e --no-headers 2>/dev/null | wc -l)"
  echo "内存总量_MB   $(free -m | awk '/^Mem:/{print $2}')"
  echo "内存已用_MB   $(free -m | awk '/^Mem:/{print $3}')"
  echo "内存可用_MB   $(free -m | awk '/^Mem:/{print $7}')"
  echo "swap已用_MB   $(free -m | awk '/^Swap:/{print $3}')"
  echo "开机耗时      $(systemd-analyze time 2>/dev/null | head -1)"
  echo "uptime_秒     $(cut -d. -f1 /proc/uptime)"
  echo "--- 直通能力 ---"
  echo "iommu组数     $(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)"
  echo "vfio模块      $(lsmod 2>/dev/null | grep -c '^vfio')"
  echo "qemu          $(command -v qemu-system-x86_64 || echo 缺)"
  echo "libvirtd单元  $(systemctl is-enabled libvirtd 2>/dev/null)"
  echo "dmesg_IOMMU:"
  dmesg 2>/dev/null | grep -iE "DMAR|IOMMU" | head -6 | sed 's/^/    /'
  echo "--- 桌面进程 ---"
  pgrep -a xfwm4 2>/dev/null | head -1
  pgrep -a xfce4-panel 2>/dev/null | head -1
  echo "--- 网络 ---"
  ip -4 -o addr show 2>/dev/null | awk '{print "  "$2" "$4}' | head -5
  ip route 2>/dev/null | head -2
  echo "--- systemd 失败单元 ---"
  systemctl --failed --no-legend 2>/dev/null | head -8
  echo "===DSH-REPORT-END==="
} > /dev/console 2>&1
EOF
chmod 755 "$R/usr/local/bin/dsh-报数.sh"
echo "  自报数已升级（会报 cmdline / iommu 组数 / vfio 模块 / qemu）"

# ══════════ ① ④ 进 chroot：装虚拟化那套 + 开 libvirtd ══════════
step "3/3 装 QEMU/libvirt/virt-manager/OVMF/swtpm，开 libvirtd"
mkdir -p "$R/dev" "$R/proc" "$R/sys" "$R/run"
mount -t tmpfs -o mode=755,size=64M tmpfs "$R/dev"
mkdir -p "$R/dev/pts" "$R/dev/shm"
mount -t tmpfs -o mode=1777,size=256M tmpfs "$R/dev/shm"
mknod -m 666 "$R/dev/null" c 1 3; mknod -m 666 "$R/dev/zero" c 1 5
mknod -m 666 "$R/dev/random" c 1 8; mknod -m 666 "$R/dev/urandom" c 1 9
mknod -m 666 "$R/dev/tty" c 5 0
mount -t proc proc "$R/proc"; mount -t sysfs sysfs "$R/sys"
mount -t tmpfs -o mode=755,size=32M tmpfs "$R/run"
[ -L "$R/etc/resolv.conf" ] && rm -f "$R/etc/resolv.conf"
cp -f /etc/resolv.conf "$R/etc/resolv.conf"
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"; chmod 755 "$R/usr/sbin/policy-rc.d"

timeout "$INNER" chroot "$R" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive
  dpkg --configure -a; apt-get -f install -y
  apt-get update -qq
  apt-get install -y --no-install-recommends \
     qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients \
     virt-manager virt-viewer ovmf swtpm swtpm-tools spice-client-gtk \
     gir1.2-spiceclientgtk-3.0 dnsmasq-base
  echo "--- 开服务 / 加组 ---"
  systemctl enable libvirtd 2>&1 | tail -1
  usermod -aG libvirt,kvm dsh 2>&1
  # initramfs 里带上 vfio，不然早期绑定会失败
  for m in vfio vfio_iommu_type1 vfio_pci; do
      grep -qx "$m" /etc/initramfs-tools/modules 2>/dev/null || echo "$m" >> /etc/initramfs-tools/modules
  done
  echo "  /etc/initramfs-tools/modules 末尾："
  tail -3 /etc/initramfs-tools/modules | sed "s/^/    /"
  if command -v update-grub >/dev/null 2>&1; then update-grub 2>&1 | tail -2; else echo "  （没装 grub，/etc/default/grub 先留着，装完引导再 update-grub）"; fi
  update-initramfs -u -k all 2>&1 | tail -3
  echo "  qemu: $(command -v qemu-system-x86_64)"
  echo "  ovmf: $(ls /usr/share/OVMF/OVMF_CODE*.fd 2>/dev/null | head -1)"
  apt-get clean; rm -rf /var/lib/apt/lists/*
' 2>&1 | grep -vE "^(Get|Fetched|Reading|Building|Selecting|Preparing|Unpacking|Setting up|Processing|update-alternatives)" | sed 's/^/  /'
rc=$?

cleanup
echo
echo "── 结果 (退出码 $rc) ──"
echo "  包数 $(grep -c '^Package: ' "$R/var/lib/dpkg/status")"
echo "  占用 $(du -sh --exclude=proc --exclude=sys --exclude=dev --exclude=run "$R" 2>/dev/null | cut -f1)"
# 顺手清掉之前 root 留下的截图残渣
rm -f /var/tmp/dshshot*.ppm
chown -R 1000:1000 "$R" 2>/dev/null
echo; echo "════ E 段结束 ════"; date '+  %H:%M:%S'
exit $rc
