#!/usr/bin/env bash
# 往已经拼好的 rootfs 里「再加一组包」—— 安全版
#
# 用法：  pkexec bash ~/拼装/加包.sh <组名> [组名...]
#
# ═══ 三条硬护栏（2026-09-25 把宿主机搞 OOM 之后立的）═══
#   ① 【隔离】绝不把宿主的 /dev /run rbind 进 chroot。改成造**私有的**
#      最小 /dev（只 mknod 必要节点）+ 私有且有大小上限的 /dev/shm、/run。
#      上次的错就在这儿：宿主的 /dev/shm 是内存盘、/run/user/1000 是会话
#      总线，全被一个 root 进程任意写 —— 一出事就连带把桌面干碎。
#   ② 【限额】整个构建跑在 systemd 的临时 cgroup 里，带内存/交换/CPU/IO
#      硬上限。真出事 OOM 只杀构建这个 scope，**碰不到桌面**。
#      再加个 policy-rc.d 挡住 postinst 启动服务，免得往宿主机伸手。
#   ③ 【体检】开跑前先看空闲内存，不够直接拒绝跑，不商量。
#   另外：内层 timeout 硬自杀 + trap 清理，保证是「干净退出」而不是被砍死。
set -u

UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
R=$ROOT/构建/kernel-rootfs

MEMCAP="${MEMCAP:-4G}"       # 构建这个 scope 的内存硬上限
SWAPCAP="${SWAPCAP:-2G}"     # 交换也限住 —— 防 zram 震荡把整机拖死
CPUQUOTA="${CPUQUOTA:-250%}"
IOWEIGHT="${IOWEIGHT:-40}"   # 机械盘上压低 IO 权重，保桌面响应
MINFREE="${MINFREE:-2500}"   # 低于这个可用内存（MB）就不跑
INNER="${INNER:-300}"        # 内层限时（秒）

# ── ② 先把自己套进 cgroup ──
if [ "${DSH_LIMITED:-0}" != "1" ]; then
    if command -v systemd-run >/dev/null 2>&1; then
        echo "── 套 cgroup 上限：内存 $MEMCAP｜交换 $SWAPCAP｜CPU $CPUQUOTA｜IOWeight $IOWEIGHT ──"
        exec systemd-run --scope --quiet --collect \
            --unit="dsh-build-$$" \
            -p MemoryMax="$MEMCAP" -p MemorySwapMax="$SWAPCAP" \
            -p CPUQuota="$CPUQUOTA" -p IOWeight="$IOWEIGHT" -p CPUWeight="$IOWEIGHT" \
            --setenv=DSH_LIMITED=1 \
            -- bash "$0" "$@"
    else
        echo "✗ 没有 systemd-run，没法设内存上限 —— 为了你宿主机的安全，不跑"
        exit 1
    fi
fi

[ -d "$R" ] || { echo "✗ 没有 $R，先跑 A 段"; exit 1; }
[ $# -ge 1 ] || { echo "用法：加包.sh <组名...>"; exit 1; }

PKGS=""
for G in "$@"; do
    case "$G" in
    X)      P="xserver-xorg xserver-xorg-video-vesa xserver-xorg-video-fbdev xserver-xorg-input-libinput xinit xauth x11-utils x11-xserver-utils xinput dbus dbus-x11" ;;
    XFCE)   P="xfce4 xfce4-session xfwm4 xfdesktop4 xfce4-panel xfce4-settings xfconf xfce4-appfinder xfce4-whiskermenu-plugin xfce4-pulseaudio-plugin xfce4-notifyd xfce4-screenshooter xfce4-taskmanager xfce4-clipman-plugin xfce4-power-manager xfce4-terminal thunar thunar-volman gvfs gvfs-backends tumbler tumbler-plugins-extra exo-utils desktop-base lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings adwaita-icon-theme hicolor-icon-theme" ;;
    PANEL)  P="xfce4-genmon-plugin xfce4-cpugraph-plugin xfce4-systemload-plugin xfce4-netload-plugin xfce4-datetime-plugin xfce4-sensors-plugin" ;;
    THEME)  P="arc-theme papirus-icon-theme greybird-gtk-theme" ;;
    TWEAK)  P="picom rofi kitty nnn conky-all feh nitrogen flameshot scrot xclip xsel" ;;
    CJK)    P="fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 fcitx5-config-qt im-config fonts-noto-cjk fonts-noto-cjk-extra fonts-noto-color-emoji fonts-wqy-microhei fonts-hack fonts-jetbrains-mono fonts-powerline" ;;
    AV)     P="pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils pavucontrol mpv ffmpeg audacious" ;;
    NET)    P="network-manager network-manager-gnome wpasupplicant firmware-iwlwifi firmware-misc-nonfree" ;;
    DEV)    P="build-essential python3 python3-venv python3-pip python3-dev python3-tk vim neovim tmux gdb strace pkg-config cmake meson ninja-build ripgrep fd-find fzf bat eza zoxide btop htop duf procs sd delta lazygit tig jq httpie hyperfine direnv just ncdu tree sqlite3 git-lfs" ;;
    OURS)   P="python3-gi python3-gi-cairo python3-cairo python3-pil gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 gir1.2-glib-2.0 gir1.2-pango-1.0 wmctrl xdotool mesa-vulkan-drivers vulkan-tools libvulkan1 libxtst6 libxext6 lm-sensors" ;;
    VIRT)   P="qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virt-manager ovmf swtpm swtpm-tools" ;;
    *)      echo "✗ 不认识的组：$G"; exit 1 ;;
    esac
    echo "  组 $G → $(echo "$P" | wc -w) 个包"
    PKGS="$PKGS $P"
done
echo

# ── ③ 内存体检 ──
avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
echo "── 开跑前：可用内存 ${avail} MB（门槛 ${MINFREE} MB）──"
if [ "$avail" -lt "$MINFREE" ]; then
    echo "✗ 可用内存不够，不跑。等你腾出内存、或者把门槛调低（MINFREE=xxx）再说。"
    exit 3
fi

cleanup() {
    for m in $(awk -v r="$R/" 'index($2, r)==1 {print $2}' /proc/self/mounts | sort -r); do
        umount -l "$m" 2>/dev/null
    done
}
trap cleanup EXIT

# 清掉上一轮可能残留的挂载
cleanup

# ── ① 私有 /dev /run —— 绝不 rbind 宿主的 ──
echo "── 造私有 /dev、/run（跟宿主隔离）──"
rm -rf "$R/dev" "$R/run" ; mkdir -p "$R/dev" "$R/run" "$R/proc" "$R/sys"
mount -t tmpfs -o mode=755,size=64M tmpfs "$R/dev"
mkdir -p "$R/dev/pts" "$R/dev/shm"
mount -t devpts devpts "$R/dev/pts" -o gid=5,mode=620 2>/dev/null
mount -t tmpfs -o mode=1777,size=512M tmpfs "$R/dev/shm"      # 私有 + 限大小
mknod -m 666 "$R/dev/null"    c 1 3
mknod -m 666 "$R/dev/zero"    c 1 5
mknod -m 666 "$R/dev/full"    c 1 7
mknod -m 666 "$R/dev/random"  c 1 8
mknod -m 666 "$R/dev/urandom" c 1 9
mknod -m 666 "$R/dev/tty"     c 5 0
ln -sf /proc/self/fd "$R/dev/fd"
mount -t tmpfs -o mode=755,size=32M tmpfs "$R/run"
mount -t proc  proc  "$R/proc"
mount -t sysfs sysfs "$R/sys"
cp -f /etc/resolv.conf "$R/etc/resolv.conf"

# 挡住 postinst 启动/停止服务 —— 免得 chroot 里的脚本往宿主机伸手
printf '#!/bin/sh\nexit 101\n' > "$R/usr/sbin/policy-rc.d"
chmod 755 "$R/usr/sbin/policy-rc.d"

# 顺手把主机名设上
echo "dshos" > "$R/etc/hostname"
grep -q '^127.0.1.1' "$R/etc/hosts" 2>/dev/null || echo "127.0.1.1  dshos" >> "$R/etc/hosts"

echo "── 开始装（$(date +%H:%M:%S)，内层限时 ${INNER}s）──"
timeout "$INNER" chroot "$R" /bin/bash -c "
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8
  apt-get update -qq || exit 1
  echo '  ── 先给上一轮中断的 dpkg 收尾 ──'
  dpkg --configure -a
  apt-get -f install -y
  echo '  ── 正式装这一组（--no-install-recommends，少拖东西）──'
  apt-get install -y --no-install-recommends $PKGS
  rc=\$?
  if [ \"\$rc\" = 0 ]; then apt-get clean; rm -rf /var/lib/apt/lists/*; fi
  exit \$rc
"
rc=$?
[ "$rc" = 124 ] && echo "  ⏱ 内层超时了 —— 这一轮做到哪算哪，再跑一次接着做（脚本会先补 dpkg）"

cleanup
echo "── 装完（$(date +%H:%M:%S)）退出码 $rc ──"
echo "  包数：$(grep -c '^Package: ' "$R/var/lib/dpkg/status")"
echo "  半装/半配：$(awk '/^Status:/ && $0 !~ /installed|not-installed|config-files|triggers/{c++} END{print c+0}' "$R/var/lib/dpkg/status")"
echo "  占用：$(du -sh --exclude=proc --exclude=sys --exclude=dev --exclude=run "$R" 2>/dev/null | cut -f1)"
echo "  本轮内存实际峰值：$(systemctl show "dsh-build-$$" -p MemoryPeak --value 2>/dev/null || echo n/a)"

chown -R 1000:1000 "$R" 2>/dev/null
echo "✔ 这一组落盘了，断了也不怕"
exit $rc
