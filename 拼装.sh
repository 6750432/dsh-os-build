#!/usr/bin/env bash
# 「超级拼装」主脚本 —— 用 root 跑（由 pkexec 拉起来）
#
# 用法：  pkexec ~/拼装/拼装.sh                     拼一个最小系统
#         pkexec ~/拼装/拼装.sh 桌面 乙             拼「乙·爽」完整桌面
#
# 为什么最后还是要 root：
#   试过三种「假装 root」的免密路线，都被卡住了 ——
#     · chrootless：base-files / base-passwd 的 postinst 需要真 root
#     · unshare（单映射）：文件名属于 root:shadow(gid 42) 时 chown 报 EINVAL
#     · unshare（mmdebstrap 自带）：它把内层 root 映射到 subuid，
#       反而读不了宿主家目录（750），mkdir 直接 EACCES
#   所以老老实实用 root 跑，跑完把产物 chown 回普通用户，后面你自己动它就没障碍了。

set -u

UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
NAME="${1:-rootfs}"
SUITE="${2:-trixie}"
MIRROR="${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
# 组件的坑：mmdebstrap 默认只开 main，而固件包（firmware-iwlwifi 等）
# 住在 non-free-firmware 里 —— 不开这一项会直接报 "has no installation candidate"
COMPONENTS="${COMPONENTS:-main,contrib,non-free,non-free-firmware}"

# 拼装清单：每行一组，想减就整组注释掉
PKGS_BASE="ca-certificates,locales,tzdata,apt-utils,sudo,less,curl,wget,gnupg
,openssh-server,man-db,bash-completion,rsync,unzip,zip,pciutils,usbutils,inxi
,ntfs-3g,dosfstools,needrestart,zram-tools,lm-sensors,systemd-sysv,systemd
,kmod,iproute2,e2fsprogs"
PKGS_KERNEL="linux-image-amd64,linux-headers-amd64,initramfs-tools,firmware-linux
,firmware-iwlwifi,firmware-misc-nonfree"
PKGS_DISPLAY="xserver-xorg,xserver-xorg-video-nouveau,xserver-xorg-video-vesa
,xserver-xorg-input-libinput,xinit,x11-utils,x11-xserver-utils,xinput"
PKGS_DESKTOP="lightdm,lightdm-gtk-greeter,lightdm-gtk-greeter-settings,xfce4
,xfce4-whiskermenu-plugin,xfce4-pulseaudio-plugin,xfce4-notifyd,xfce4-screenshooter
,xfce4-taskmanager,xfce4-clipman-plugin,xfce4-power-manager,xfce4-genmon-plugin
,xfce4-cpugraph-plugin,xfce4-systemload-plugin,xfce4-netload-plugin,xfce4-datetime-plugin
,xfce4-sensors-plugin,thunar,thunar-volman,gvfs,gvfs-backends,tumbler
,arc-theme,papirus-icon-theme,greybird-gtk-theme"
PKGS_DESKTOP="$(echo "$PKGS_DESKTOP" | tr -d '\n')"
PKGS_TWEAK="picom,rofi,kitty,nnn,conky-all,feh,nitrogen,flameshot,scrot,xclip,xsel"
PKGS_CJK="fcitx5,fcitx5-chinese-addons,fcitx5-frontend-gtk3,fcitx5-frontend-gtk4
,fcitx5-frontend-qt5,fcitx5-config-qt,im-config,fonts-noto-cjk,fonts-noto-cjk-extra
,fonts-noto-color-emoji,fonts-wqy-microhei,fonts-hack,fonts-jetbrains-mono,fonts-powerline"
PKGS_AV="pipewire,pipewire-pulse,pipewire-alsa,wireplumber,alsa-utils,pavucontrol
,mpv,ffmpeg,audacious"
PKGS_DEV="build-essential,python3,python3-venv,python3-pip,python3-dev,python3-tk
,vim,neovim,tmux,gdb,strace,pkg-config,cmake,meson,ninja-build,shellcheck
,ripgrep,fd-find,fzf,bat,eza,zoxide,btop,htop,duf,procs,sd,delta,lazygit,tig
,jq,httpie,hyperfine,direnv,just,ncdu,tree,sqlite3,git-lfs"
PKGS_OURS="python3-gi,python3-gi-cairo,python3-cairo,python3-pil
,gir1.2-gtk-3.0,gir1.2-gdkpixbuf-2.0,gir1.2-glib-2.0,gir1.2-pango-1.0
,wmctrl,xdotool,mesa-vulkan-drivers,vulkan-tools,libvulkan1,libxtst6,libxext6"
PKGS_WINVM="qemu-system-x86,qemu-utils,libvirt-daemon-system,libvirt-clients
,virt-manager,ovmf,swtpm,swtpm-tools,virt-viewer,spice-client-gtk
,gir1.2-spiceclientgtk-3.0,bridge-utils,dnsmasq-base,libosinfo-bin"

# 要装哪几组：用环境变量 SELECT 挑，默认只装最底那层
SELECT="${SELECT:-BASE}"
INCLUDE="$PKGS_BASE"
for g in KERNEL DISPLAY DESKTOP TWEAK CJK AV DEV OURS WINVM; do
    case ",$SELECT," in *",$g,"*) eval "INCLUDE=\"\$INCLUDE,\$PKGS_$g\"" ;; esac
done
INCLUDE="$(echo "$INCLUDE" | tr -d '\n' | sed 's/,,*/,/g')"

OUT="$ROOT/构建/$NAME"
export PATH="$ROOT/工具/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "════ 拼装开始 $(date '+%F %T') ════"
echo "  套件   $SUITE"
echo "  输出   $OUT"
echo "  组     $SELECT"
echo "  包     $(echo "$INCLUDE" | tr ',' '\n' | grep -c .) 个"
echo

rm -rf "$OUT"
mmdebstrap --mode=root --variant=minbase \
    --keyring="$ROOT/工具/usr/share/keyrings/debian-archive-keyring.gpg" \
    --components="$COMPONENTS" \
    --include="$INCLUDE" \
    "$SUITE" "$OUT" "$MIRROR"
rc=$?

echo
echo "════ 结果（mmdebstrap 退出码 $rc）════"
if [ -d "$OUT" ]; then
    echo "  把产物还给普通用户 1000:1000 …"
    chown -R 1000:1000 "$OUT" 2>/dev/null
    du -sh "$OUT" | sed 's/^/  大小 /'
    echo "  包数 $(grep -c '^Package: ' "$OUT/var/lib/dpkg/status" 2>/dev/null)"
fi
echo "════ 结束 $(date '+%F %T') ════"
exit $rc
