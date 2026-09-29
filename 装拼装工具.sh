#!/usr/bin/env bash
# 「超级拼装」的一次性准备（只需要跑这一次，之后拼装再也不需要 root）
#
# 为什么非得动一下 root：
#   本项目的做法是在「无特权用户命名空间」里假装 root 来拼系统，
#   这样拼装全程不用你输密码。但用户命名空间默认只映射
#   「你 → root」这**一个** uid/gid；而 Debian 的包里有些文件属于
#   root:shadow(gid 42)、root:utmp 之类，解包时 chown 到没映射的
#   gid 会直接 EINVAL —— 刚才就卡在这（tar: Cannot change ownership）：
#
#       tar: ./usr/sbin/unix_chkpwd: Cannot change ownership to uid 0, gid 42
#
#   标准解法：给这个用户分配一段「从属 uid/gid 区间」(subuid/subgid)，
#   再装上提供 newuidmap/newgidmap 的 uidmap 包 —— 这俩是小工具，
#   专门用来把那段区间映射进用户命名空间。
#
# 做完之后：mmdebstrap --mode=unshare 就能以普通用户身份跑完整拼装，
#           以后每次改清单重拼都不用再输密码。
#
# 想撤销（几乎没人会想）：
#       apt-get purge uidmap
#       usermod --del-subuids 100000-165535 --del-subgids 100000-165535 <你>

set -u

# pkexec 会把这个设成原始用户的 uid，拿它来定位用户名
U="$(id -nu "${PKEXEC_UID:-0}" 2>/dev/null)"
[ -z "$U" ] || [ "$U" = "root" ] && U="$(id -nu 1000)"
echo "目标用户：$U"
echo

if [ "$(id -u)" != "0" ]; then
    echo "✗ 这个脚本要用 root 跑（正常情况下是用 pkexec 拉起来的）"
    exit 1
fi

echo "── 1/2  装 uidmap（提供 newuidmap / newgidmap）──"
if command -v newuidmap >/dev/null 2>&1; then
    echo "  已经装了，跳过"
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y uidmap || {
        echo "  ✘ 装失败（网络？源？）"; exit 1; }
fi
echo

echo "── 2/2  给 $U 分配从属 id 区间 100000-165535 ──"
if grep -q "^$U:" /etc/subuid 2>/dev/null; then
    echo "  /etc/subuid 里已经有了：$(grep "^$U:" /etc/subuid)"
else
    usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$U" \
        && echo "  已写入" || { echo "  ✘ usermod 失败"; exit 1; }
fi
echo

echo "── 结果核对 ──"
echo "  subuid: $(grep "^$U:" /etc/subuid 2>/dev/null || echo '（空）')"
echo "  subgid: $(grep "^$U:" /etc/subgid 2>/dev/null || echo '（空）')"
echo "  newuidmap: $(command -v newuidmap || echo 缺)"
echo "  newgidmap: $(command -v newgidmap || echo 缺)"
echo
echo "✔ 一次性准备完成。回到对话里说一声，接着拼。"
