#!/usr/bin/env bash
# 启动 DSH OS —— 从 Debian 手拼的整机系统
#
# 用法：  双击桌面上的「DSH OS」图标
#         或者在终端里跑   bash ~/拼装/启动DSH-OS.sh
#
# 会开一个真正的图形窗口，里面就是 DSH OS 的 XFCE 桌面，可以自己点。
# 关机：直接关那个窗口，或者在本窗口按 Ctrl+A 再按 X。
#
# 登录信息（一般用不上，lightdm 是自动登录的）：
#     普通用户  dsh / dsh        管理员  root / root

set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
IMG="$DIR/构建/桌面版.img"
LOG="$DIR/构建/手动开机日志.txt"
BRAND="DSH OS"

[ -f "$IMG" ] || { echo "✗ 找不到镜像：$IMG"; echo "  先跑 本轮A-开机看桌面.sh 重新生成"; read -rp "按回车关闭…" _; exit 1; }

# 能不能直接用 KVM？看当前用户是否在 kvm 组里，比试读 /dev/kvm 可靠
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx kvm; then
    echo "════ 启动 $BRAND ════"
    echo "  硬件加速：直接可用"
    RUNNER=()
else
    echo "════ 启动 $BRAND ════"
    echo "  硬件加速：你现在不在 kvm 组里，会用一次提权去拿 KVM"
    echo "            屏幕上会弹密码框；不想每次输就先跑一次："
    echo "                sudo usermod -aG kvm \$USER"
    echo "            然后注销重进（组权限要重新登录才生效）"
    RUNNER=(pkexec env "DISPLAY=${DISPLAY:-:0}" "XAUTHORITY=${XAUTHORITY:-$HOME/.Xauthority}"
                    "XDG_RUNTIME_DIR=/run/user/$(id -u)")
fi

echo "  内存 2G｜2 核｜网卡 e1000（能上网）｜SSH 映射到本机 2222 端口"
echo "  想退出：关掉那个窗口就行"
echo

"${RUNNER[@]}" qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -m 2048 -smp 2 \
    -vga std \
    -display gtk,zoom-to-fit=on \
    -no-reboot \
    -kernel "$(ls "$DIR"/构建/kernel-rootfs/boot/vmlinuz-* | head -1)" \
    -initrd "$(ls "$DIR"/构建/kernel-rootfs/boot/initrd.img-* | head -1)" \
    -append "root=/dev/sda rw console=tty0 console=ttyS0,115200 intel_iommu=on iommu=pt" \
    -drive "file=$IMG,format=raw,if=ide" \
    -nic user,model=e1000,hostfwd=tcp::2222-:22 \
    -serial "file:$LOG" \
    2>&1 | tail -20

echo
echo "$BRAND 关掉了。"
