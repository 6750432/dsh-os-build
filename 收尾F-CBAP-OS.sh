#!/usr/bin/env bash
# F 段：把 DSH rootfs 变成 CBAP OS
#
# 用法：
#   pkexec bash ~/拼装/收尾F-CBAP-OS.sh
#   CBAP_VERSIONS="v1.0.0 v1.4.0" CBAP_SRC=/path/to/cbap pkexec bash ...
#
# 做四件事：
#   ① 建立 /opt/cbap-os/versions 的 CBAP/Python 版本槽
#   ② 安装 cbap-os 选择器、cbap 命令和 systemd 单元
#   ③ 默认安装 v1.4.0；可额外安装旧版本做回滚/实验
#   ④ 不启动服务，不碰宿主；只改 rootfs
set -eu
UH="$(getent passwd "${PKEXEC_UID:-$(id -u)}" | cut -d: -f6)"
ROOT="${DSH_BUILD_ROOT:-$UH/拼装}"
R=$ROOT/构建/kernel-rootfs
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MEMCAP="${MEMCAP:-4G}"; SWAPCAP="${SWAPCAP:-2G}"; CPUQUOTA="${CPUQUOTA:-250%}"
IOWEIGHT="${IOWEIGHT:-40}"; MINFREE="${MINFREE:-2500}"; INNER="${INNER:-420}"
CBAP_VERSION="${CBAP_VERSION:-v1.4.0}"
CBAP_VERSIONS="${CBAP_VERSIONS:-v1.0.0 v1.4.0}"
CBAP_SRC="${CBAP_SRC:-}"
PYTHON_PREFIX="${PYTHON_PREFIX:-}"
step() { echo; echo "════ $* ════"; date '+  %H:%M:%S'; }

if [ "${DSH_LIMITED:-0}" != "1" ]; then
    command -v systemd-run >/dev/null || { echo "✗ 没有 systemd-run，不跑"; exit 1; }
    echo "── 套 cgroup 上限：内存 $MEMCAP｜交换 $SWAPCAP｜CPU $CPUQUOTA｜IOWeight $IOWEIGHT ──"
    exec systemd-run --scope --quiet --collect --unit="dsh-f-$$" \
        -p MemoryMax="$MEMCAP" -p MemorySwapMax="$SWAPCAP" \
        -p CPUQuota="$CPUQUOTA" -p IOWeight="$IOWEIGHT" -p CPUWeight="$IOWEIGHT" \
        --setenv=DSH_LIMITED=1 \
        --setenv=CBAP_VERSION="$CBAP_VERSION" \
        --setenv=CBAP_VERSIONS="$CBAP_VERSIONS" \
        --setenv=CBAP_SRC="$CBAP_SRC" \
        --setenv=PYTHON_PREFIX="$PYTHON_PREFIX" \
        -- bash "$0" "$@"
fi
avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
echo "── 可用内存 ${avail} MB（门槛 ${MINFREE}）──"
[ "$avail" -ge "$MINFREE" ] || { echo "✗ 内存不够，不跑"; exit 3; }
[ -d "$R" ] || { echo "✗ 没有 $R；先跑 拼装/本轮A"; exit 1; }
[ -x "$HERE/cbap-os/install.sh" ] || { echo "✗ 缺 cbap-os/install.sh"; exit 1; }

step "1/3 安装 CBAP OS runtime layer"
# v1.0 first, v1.4 last: last install wins the initial selection.
for ver in $CBAP_VERSIONS; do
    src_args=()
    if [ -n "$CBAP_SRC" ] && [ "$ver" = "$CBAP_VERSION" ]; then
        src_args=(--cbap-src "$CBAP_SRC")
    fi
    py_args=()
    if [ -n "$PYTHON_PREFIX" ]; then
        py_args=(--python-prefix "$PYTHON_PREFIX")
    fi
    echo "  ── $ver ──"
    bash "$HERE/cbap-os/install.sh" --root "$R" \
        --cbap-version "$ver" "${src_args[@]}" "${py_args[@]}" \
        2>&1 | sed 's/^/    /'
done

step "2/3 设置 CBAP OS 身份并生成初始选择摘要"
echo "cbapos" > "$R/etc/hostname"
if grep -q '^127.0.1.1' "$R/etc/hosts" 2>/dev/null; then
    sed -i 's/^127.0.1.1.*/127.0.1.1  cbapos/' "$R/etc/hosts"
else
    echo "127.0.1.1  cbapos" >> "$R/etc/hosts"
fi
CBAP_OS_ROOT="$R" python3 "$HERE/cbap-os/bin/cbap-os" list 2>&1 | sed 's/^/  /'
CBAP_OS_ROOT="$R" python3 "$HERE/cbap-os/bin/cbap-os" status 2>&1 | sed 's/^/  /' || true

step "3/3 把 rootfs 还给普通用户"
chown -R 1000:1000 "$R" 2>/dev/null
echo "  包数 $(grep -c '^Package: ' "$R/var/lib/dpkg/status" 2>/dev/null || echo n/a)"
echo "  CBAP 版本槽："
find "$R/opt/cbap-os/versions/cbap" -mindepth 1 -maxdepth 1 -type d -printf '    %f\n' 2>/dev/null | sort
echo "  Python 版本槽："
find "$R/opt/cbap-os/versions/python" -mindepth 1 -maxdepth 1 -type d -printf '    %f\n' 2>/dev/null | sort
echo
echo "════ F 段结束 ════"; date '+  %H:%M:%S'
