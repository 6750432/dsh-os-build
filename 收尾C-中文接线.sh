#!/usr/bin/env bash
# 补最后一条：让「能打中文」真的成立
#
# 装了 fcitx5 和字体，不等于能用 —— 还得：
#   · im-config 告诉系统「用 fcitx5」
#   · 设好 GTK_IM_MODULE / QT_IM_MODULE / XMODIFIERS
#   · 会话启动时把 fcitx5 拉起来
#   · 有个能验证的自检
# 用法： pkexec bash ~/拼装/收尾C-中文接线.sh
set -u
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"   # pkexec 下 HOME 会是 /root，所以按 UID 反查宿主家目录
ROOT=$UH/拼装
R=$ROOT/构建/kernel-rootfs
MEMCAP="${MEMCAP:-4G}"; SWAPCAP="${SWAPCAP:-2G}"; CPUQUOTA="${CPUQUOTA:-250%}"
IOWEIGHT="${IOWEIGHT:-40}"; MINFREE="${MINFREE:-2500}"; INNER="${INNER:-180}"
step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

if [ "${DSH_LIMITED:-0}" != "1" ]; then
    command -v systemd-run >/dev/null || { echo "✗ 没有 systemd-run，不跑"; exit 1; }
    echo "── 套 cgroup 上限：内存 $MEMCAP｜交换 $SWAPCAP｜CPU $CPUQUOTA｜IOWeight $IOWEIGHT ──"
    exec systemd-run --scope --quiet --collect --unit="dsh-cjk-$$" \
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

step "1/3 环境变量 + 会话自启（纯文件）"
# PAM 会话级别（GTK/Qt 程序靠这些找输入法）
for kv in "GTK_IM_MODULE=fcitx5" "QT_IM_MODULE=fcitx5" "XMODIFIERS=@im=fcitx5" \
          "SDL_IM_MODULE=fcitx" "GLFW_IM_MODULE=ibus"; do
    grep -qxF "$kv" "$R/etc/environment" 2>/dev/null || echo "$kv" >> "$R/etc/environment"
done
echo "  /etc/environment:"; grep -E "IM_MODULE|XMODIFIERS" "$R/etc/environment" | sed 's/^/    /'

# shell 级别（终端里也一致）
cat > "$R/etc/profile.d/dsh-ime.sh" <<'EOF'
export GTK_IM_MODULE=fcitx5
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5
EOF
chmod 644 "$R/etc/profile.d/dsh-ime.sh"

# dsh 的 xprofile：会话一起来就把 fcitx5 拉起来
cat > "$R/home/dsh/.xprofile" <<'EOF'
export GTK_IM_MODULE=fcitx5
export QT_IM_MODULE=fcitx5
export XMODIFIERS=@im=fcitx5
export LANG=zh_CN.UTF-8
fcitx5 -d --replace >/dev/null 2>&1 &
EOF
ln -sf /home/dsh/.xprofile "$R/home/dsh/.xinputrc" 2>/dev/null || true
chown -h dsh:dsh "$R/home/dsh/.xprofile" 2>/dev/null

# 兜底：桌面标准的 autostart（fcitx5 自带的那份如果不在就自己写一份）
if [ ! -f "$R/etc/xdg/autostart/fcitx5.desktop" ]; then
    cat > "$R/etc/xdg/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
GenericName=Input Method
Comment=Start Input Method
Exec=fcitx5 -d --replace
Icon=fcitx
Terminal=false
Categories=System;Utility;
AutostartCondition=unless-exists fcitx5.running
X-GNOME-Autostart-Phase=Applications
X-GNOME-Autostart-Notify=true
EOF
    echo "  自己写了一份 /etc/xdg/autostart/fcitx5.desktop"
else
    echo "  fcitx5 自带的 autostart 已在"
fi

step "2/3 会话里的中文自检（结果写到 /var/log/dsh-中文自检.txt）"
cat > "$R/usr/local/bin/dsh-中文自检.sh" <<'EOF'
#!/bin/bash
sleep 45
{
  echo "=== 中文可用性自检 $(date) ==="
  echo "DISPLAY=$DISPLAY"
  echo "环境: GTK_IM_MODULE=$GTK_IM_MODULE QT_IM_MODULE=$QT_IM_MODULE XMODIFIERS=$XMODIFIERS"
  echo "LANG=$LANG"
  echo "fcitx5 进程: $(pgrep -a fcitx5 | head -2)"
  echo "fcitx5-remote: $(fcitx5-remote 2>&1)   (2=已激活)"
  echo "中文字体数(fc-list :lang=zh): $(fc-list :lang=zh 2>/dev/null | wc -l)"
  echo "字体样例: $(fc-list :lang=zh family 2>/dev/null | sort -u | head -5 | tr '\n' '; ')"
  echo "拼音引擎文件: $(ls /usr/lib/x86_64-linux-gnu/fcitx5/ 2>/dev/null | grep -iE 'pinyin|chinese' | tr '\n' ' ')"
  echo "GTK 输入法模块: $(ls /usr/lib/x86_64-linux-gnu/gtk-3.0/3.0.0/immodules/ 2>/dev/null | grep -i fcitx | tr '\n' ' ')"
  echo "=== 完 ==="
} > /var/log/dsh-中文自检.txt 2>&1
chmod 644 /var/log/dsh-中文自检.txt
EOF
chmod 755 "$R/usr/local/bin/dsh-中文自检.sh"
cat > "$R/etc/xdg/autostart/dsh-中文自检.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=DSH CJK self check
Exec=/usr/local/bin/dsh-中文自检.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
echo "  自检脚本 + autostart 已就位"

step "3/3 进 chroot：im-config / locale / 收个尾"
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
  echo "--- 设 locale ---"
  sed -i "s/^# *zh_CN.UTF-8 UTF-8/zh_CN.UTF-8 UTF-8/" /etc/locale.gen
  grep -q "^zh_CN.UTF-8" /etc/locale.gen || echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen
  grep -q "^en_US.UTF-8" /etc/locale.gen || echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
  locale-gen 2>&1 | tail -2
  echo "--- im-config 指向 fcitx5 ---"
  if command -v im-config >/dev/null 2>&1; then
      im-config -n fcitx5 2>&1 | tail -3
      echo "  /etc/X11/xinit/xinputrc → $(cat /etc/X11/xinit/xinputrc 2>/dev/null)"
  else
      echo "  （没装 im-config，跳过）"
  fi
  echo "--- 校验件 ---"
  echo "  fcitx5: $(command -v fcitx5)"
  echo "  pinyin 引擎: $(ls /usr/lib/x86_64-linux-gnu/fcitx5/ 2>/dev/null | grep -c -iE "pinyin|chinese") 个"
  echo "  中文字体包: $(dpkg-query -W -f="\${Package} " fonts-noto-cjk fonts-wqy-microhei 2>/dev/null)"
  apt-get clean; rm -rf /var/lib/apt/lists/*
' 2>&1 | grep -vE "^(Get|Fetched|Reading|Building|Selecting|Preparing|Unpacking|Setting up|Processing)" | sed 's/^/  /'
rc=$?

cleanup
echo
echo "── 结果 (退出码 $rc) ──"
echo "  包数 $(grep -c '^Package: ' "$R/var/lib/dpkg/status")"
chown -R 1000:1000 "$R" 2>/dev/null
echo; echo "════ 中文接线结束 ════"; date '+  %H:%M:%S'
exit $rc
