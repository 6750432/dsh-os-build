#!/usr/bin/env bash
# 给宿主机补上 QEMU 的图形界面后端
#
# 为什么需要：之前装 qemu-system-x86 时用了 --no-install-recommends，
# 把 qemu-system-gui 漏掉了 —— 结果 -display gtk 直接报
# "Display 'gtk' is not available"，启动器开不出窗口。
set -u
echo "── 装 qemu-system-gui ──"
DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-system-gui
echo
echo "── 现在有哪些显示后端可用 ──"
qemu-system-x86_64 -display help 2>&1 | head -12
echo
echo "── gtk 还认不认 ──"
qemu-system-x86_64 -display gtk,help 2>&1 | head -6
echo
echo "✔ 完事"
