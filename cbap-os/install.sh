#!/usr/bin/env bash
# Install the CBAP OS runtime layer into a rootfs (or a test root).
#
# Usage:
#   sudo bash cbap-os/install.sh --root / --cbap-src /path/to/cyberdyne-bridge
#   sudo bash cbap-os/install.sh --root / --cbap-version v1.4.0
#   bash cbap-os/install.sh --root /tmp/rootfs --cbap-src ... --no-systemd --no-users
#
# CBAP source is installed as an immutable version slot. Python can be a
# self-contained prefix or the host's system runtime; multiple slots can be
# added later by calling install.sh with another --python-prefix.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="/"
CBAP_SRC=""
CBAP_VERSION="v1.4.0"
CBAP_REPO="https://github.com/cyberdyne-bridge/cyberdyne-bridge-agent-physical-protocol.git"
CBAP_TARBALL="https://codeload.github.com/cyberdyne-bridge/cyberdyne-bridge-agent-physical-protocol/tar.gz/refs/tags"
PYTHON_VERSION=""
PYTHON_PREFIX=""
NO_SYSTEMD=0
NO_USERS=0
FORCE=0
PYTHON_MODE="link"

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root) ROOT="${2:?}"; shift 2 ;;
        --cbap-src) CBAP_SRC="${2:?}"; shift 2 ;;
        --cbap-version) CBAP_VERSION="${2:?}"; shift 2 ;;
        --cbap-repo) CBAP_REPO="${2:?}"; shift 2 ;;
        --cbap-tarball) CBAP_TARBALL="${2:?}"; shift 2 ;;
        --python-version) PYTHON_VERSION="${2:?}"; shift 2 ;;
        --python-prefix) PYTHON_PREFIX="${2:?}"; shift 2 ;;
        --python-mode) PYTHON_MODE="${2:?}"; shift 2 ;;
        --no-systemd) NO_SYSTEMD=1; shift ;;
        --no-users) NO_USERS=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

case "$ROOT" in
    /) ;;
    /*) ;;
    *) echo "--root must be an absolute path" >&2; exit 2 ;;
esac
[ "$PYTHON_MODE" = "link" ] || [ "$PYTHON_MODE" = "copy" ] || {
    echo "--python-mode must be link or copy" >&2; exit 2;
}
ROOT="${ROOT%/}"
[ -d "$ROOT" ] || { echo "rootfs does not exist: $ROOT" >&2; exit 1; }
case "$CBAP_VERSION" in
    ""|*[!A-Za-z0-9._+-]*) echo "invalid --cbap-version: $CBAP_VERSION" >&2; exit 2 ;;
esac

say() { printf '  %s\n' "$*"; }
step() { printf '\n════ %s ════\n' "$*"; }

step "1/7 version directories"
install -d -m 0755 "$ROOT/opt/cbap-os"/{bin,systemd,versions/cbap,versions/python,current}
install -d -m 0755 "$ROOT/etc/cbap-os" "$ROOT/etc/profile.d" \
    "$ROOT/etc/systemd/system" "$ROOT/usr/local/bin" "$ROOT/var/lib/cbap-os"
say "root: $ROOT"

step "2/7 CBAP source slot"
if [ -z "$CBAP_SRC" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    # GitHub smart-HTTP clone can stall behind some mirrors. codeload's
    # tag tarball is a single request and is much easier to bound by timeout.
    if command -v curl >/dev/null 2>&1; then
        say "downloading $CBAP_TARBALL/$CBAP_VERSION"
        curl -fL --retry 3 --connect-timeout 10 --max-time 180 \
            -o "$TMP/src.tar.gz" "$CBAP_TARBALL/$CBAP_VERSION"
        mkdir -p "$TMP/src"
        tar -xzf "$TMP/src.tar.gz" --strip-components=1 -C "$TMP/src"
        CBAP_SRC="$TMP/src"
    elif command -v git >/dev/null 2>&1; then
        say "git fallback: $CBAP_REPO @ $CBAP_VERSION"
        git clone --depth 1 --branch "$CBAP_VERSION" "$CBAP_REPO" "$TMP/src"
        CBAP_SRC="$TMP/src"
    else
        echo "curl/git not found; pass --cbap-src instead" >&2
        exit 1
    fi
fi
[ -d "$CBAP_SRC/kernel" ] || { echo "not a CBAP source tree: $CBAP_SRC" >&2; exit 1; }
CBAP_DEST="$ROOT/opt/cbap-os/versions/cbap/$CBAP_VERSION"
if [ -e "$CBAP_DEST" ] && [ "$FORCE" -ne 1 ]; then
    say "slot already exists: $CBAP_DEST (use --force to replace)"
else
    rm -rf "$CBAP_DEST"
    mkdir -p "$CBAP_DEST"
    # Keep the runtime payload only; no .git, logs, caches or editor junk.
    # Some minimal test/source trees only contain kernel + drivers.
    PAYLOAD=()
    for d in kernel drivers agents tools spec console; do
        [ -e "$CBAP_SRC/$d" ] && PAYLOAD+=("$d")
    done
    (cd "$CBAP_SRC" && tar --exclude=.git --exclude=logs --exclude=__pycache__ \
        --exclude='*.pyc' --exclude='*.sock' -cf - "${PAYLOAD[@]}") |
        tar -C "$CBAP_DEST" -xf -
    if [ -f "$CBAP_SRC/README.md" ]; then cp "$CBAP_SRC/README.md" "$CBAP_DEST/"; fi
    if [ -f "$CBAP_SRC/LICENSE" ]; then cp "$CBAP_SRC/LICENSE" "$CBAP_DEST/"; fi
    cat > "$CBAP_DEST/manifest.json" <<EOF
{"version": "$CBAP_VERSION", "source": "git", "python_min": "3.10"}
EOF
fi
say "cbap: $CBAP_DEST"

step "3/7 Python runtime slot"
# Default to the Python inside the target rootfs, not the host's Python.
PY_PREFIX_GUEST="${PYTHON_PREFIX:-/usr}"
PY_SRC_GUEST="$PY_PREFIX_GUEST/bin/python3"
SRC_PY="$ROOT$PY_SRC_GUEST"
if [ ! -x "$SRC_PY" ]; then
    # Test roots and unusual prefixes may only exist on the host.
    SRC_PY="$PY_SRC_GUEST"
    [ -x "$SRC_PY" ] || { echo "python not executable: $SRC_PY" >&2; exit 1; }
fi
if [ -z "$PYTHON_VERSION" ]; then
    if [ -n "$PYTHON_PREFIX" ]; then
        PYTHON_VERSION="$("$SRC_PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
    else
        # Prefer the target's stdlib directory for the default /usr slot.
        PYTHON_VERSION="$(ls -d "$ROOT"/usr/lib/python3.* 2>/dev/null | sed -n 's|.*/python3\.||p' | sort -V | tail -1 || true)"
    fi
fi
if [ -z "$PYTHON_VERSION" ]; then
    PYTHON_VERSION="$("$SRC_PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)"
fi
[ -n "$PYTHON_VERSION" ] || { echo "cannot determine Python version; pass --python-version" >&2; exit 1; }
case "$PYTHON_VERSION" in
    ""|*[!A-Za-z0-9._+-]*) echo "invalid Python version: $PYTHON_VERSION" >&2; exit 2 ;;
esac
PY_DEST="$ROOT/opt/cbap-os/versions/python/$PYTHON_VERSION"
if [ -e "$PY_DEST" ] && [ "$FORCE" -ne 1 ]; then
    say "slot already exists: $PY_DEST (use --force to replace)"
else
    rm -rf "$PY_DEST"; mkdir -p "$PY_DEST/bin"
    if [ "$PYTHON_MODE" = "copy" ]; then
        SRC_PREFIX="$ROOT$PY_PREFIX_GUEST"
        [ -d "$SRC_PREFIX" ] || SRC_PREFIX="$PY_PREFIX_GUEST"
        cp -a "$SRC_PREFIX" "$PY_DEST/prefix"
        ln -s prefix/bin/python3 "$PY_DEST/bin/python3"
    else
        # Absolute guest path: /usr/bin/python3 inside the image, not the host.
        ln -s "$PY_SRC_GUEST" "$PY_DEST/bin/python3"
    fi
    cat > "$PY_DEST/manifest.json" <<EOF
{"python": "$PYTHON_VERSION", "source": "$PY_PREFIX_GUEST", "mode": "$PYTHON_MODE"}
EOF
fi
say "python: $PY_DEST ($("$PY_DEST/bin/python3" --version 2>&1 || true))"

step "4/7 manager, wrappers and systemd units"
install -m 0755 "$HERE/bin/cbap-os" "$ROOT/usr/local/bin/cbap-os"
install -m 0755 "$HERE/bin/cbap" "$ROOT/usr/local/bin/cbap"
install -m 0755 "$HERE/bin/cbap-service" "$ROOT/usr/local/bin/cbap-service"
cat > "$ROOT/usr/local/bin/cbap-python" <<'EOF'
#!/bin/sh
exec /opt/cbap-os/current/python/bin/python3 "$@"
EOF
chmod 0755 "$ROOT/usr/local/bin/cbap-python"
install -m 0644 "$HERE/etc/runtime.env" "$ROOT/etc/cbap-os/runtime.env"
cat > "$ROOT/etc/profile.d/cbap-os.sh" <<'EOF'
# CBAP OS: make the selected runtime explicit, but do not silently replace
# the distribution's /usr/bin/python3 (apt and system tools still need it).
export CBAP_HOME=/opt/cbap-os/current/cbap
export CBAP_PYTHON=/opt/cbap-os/current/python/bin/python3
EOF
chmod 0644 "$ROOT/etc/profile.d/cbap-os.sh"

if [ "$NO_SYSTEMD" -eq 0 ]; then
    for unit in cbap-os-select.service cbap-os-mount.service cbap.service; do
        install -m 0644 "$HERE/systemd/$unit" "$ROOT/etc/systemd/system/$unit"
    done
    for target in basic.target; do
        mkdir -p "$ROOT/etc/systemd/system/$target.wants"
        ln -sf ../cbap-os-select.service "$ROOT/etc/systemd/system/$target.wants/cbap-os-select.service"
        ln -sf ../cbap-os-mount.service "$ROOT/etc/systemd/system/$target.wants/cbap-os-mount.service"
    done
    mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf ../cbap.service "$ROOT/etc/systemd/system/multi-user.target.wants/cbap.service"
    say "enabled: cbap-os-select, cbap-os-mount, cbap"
else
    say "systemd units skipped (--no-systemd)"
fi

step "5/7 user and permissions"
if [ "$NO_USERS" -eq 0 ] && [ -f "$ROOT/etc/passwd" ]; then
    if ! grep -q '^cbap:' "$ROOT/etc/passwd"; then
        if command -v chroot >/dev/null 2>&1 && [ "$ROOT" = "/" ]; then
            useradd --system --home /var/lib/cbap --shell /usr/sbin/nologin cbap 2>/dev/null || true
        else
            echo 'cbap:x:997:997:CBAP runtime:/var/lib/cbap:/usr/sbin/nologin' >> "$ROOT/etc/passwd"
            echo 'cbap:x:997:' >> "$ROOT/etc/group"
            echo 'cbap:!:19000:0:99999:7:::' >> "$ROOT/etc/shadow"
        fi
    fi
    install -d -o 997 -g 997 -m 0700 "$ROOT/var/lib/cbap" 2>/dev/null || true
    say "user: cbap (uid 997 when created offline)"
else
    say "user creation skipped"
fi
chmod 0755 "$ROOT/opt/cbap-os" "$ROOT/opt/cbap-os/versions" 2>/dev/null || true
find "$ROOT/opt/cbap-os/versions" -type d -exec chmod 0755 {} + 2>/dev/null || true

step "6/7 initial selection"
# The boot selector will overwrite this. Pick the installed slots so a
# headless boot still works before the first interactive choice.
CBAP_NAME="$(basename "$CBAP_DEST")"
PY_NAME="$(basename "$PY_DEST")"
cat > "$ROOT/etc/cbap-os/selection.json" <<EOF
{"cbap": "$CBAP_NAME", "python": "$PY_NAME", "source": "install", "updated_at": null}
EOF
say "cbap=$CBAP_NAME python=$PY_NAME"

step "7/7 smoke"
# Do not execute the copied script directly: its shebang is /usr/bin/python3,
# which is intentionally not the host interpreter. Prefix the test root.
CBAP_OS_ROOT="$ROOT" python3 "$HERE/bin/cbap-os" list
say "done"
