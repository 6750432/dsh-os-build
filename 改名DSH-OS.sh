#!/usr/bin/env bash
# 把拼装出来的系统从 mili 改名为 DSH OS
#
# 全程只在 ~/拼装/构建/kernel-rootfs 里改文件 —— 不需要 root、不碰宿主。
# 改完要跑一次 本轮A-开机看桌面.sh 重新生成镜像才能看到效果。
set -u
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
R="$DIR/构建/kernel-rootfs"
NEWHOST=dshos        # 主机名不能有空格
NEWUSER=dsh
BRAND="DSH OS"

[ -d "$R" ] || { echo "✗ 找不到 $R"; exit 1; }

echo "════ 1/5 系统身份 ════"
echo "$NEWHOST" > "$R/etc/hostname"
if grep -q '^127.0.1.1' "$R/etc/hosts"; then
    sed -i "s/^127.0.1.1.*/127.0.1.1  $NEWHOST/" "$R/etc/hosts"
else
    echo "127.0.1.1  $NEWHOST" >> "$R/etc/hosts"
fi

# os-release：/etc 的这份优先于 /usr/lib 那份（os-release(5) 规定的）
rm -f "$R/etc/os-release"
cat > "$R/etc/os-release" <<EOF
PRETTY_NAME="$BRAND 1.0"
NAME="$BRAND"
VERSION_ID="1.0"
VERSION="1.0 (trixie)"
VERSION_CODENAME=trixie
ID=dshos
ID_LIKE=debian
HOME_URL="https://www.debian.org/"
SUPPORT_URL="https://www.debian.org/support"
BUG_REPORT_URL="https://bugs.debian.org/"
DEBIAN_VERSION_FULL=13.7
EOF
# 控制台横幅（getty 会解释 \n \l 这两个转义）
printf '%s 1.0 \\n \\l\n\n' "$BRAND" > "$R/etc/issue"
printf '%s 1.0\n' "$BRAND" > "$R/etc/issue.net"
cat > "$R/etc/motd" <<EOF
$BRAND 1.0 —— Debian 13 (trixie) 打底，现成件自己拼的。
EOF
sed -i "s|^GRUB_DISTRIBUTOR=.*|GRUB_DISTRIBUTOR=\"$BRAND\"|" "$R/etc/default/grub" 2>/dev/null
echo "  hostname     → $(cat "$R/etc/hostname")"
echo "  os-release   → $(grep PRETTY_NAME "$R/etc/os-release")"
echo "  issue        → $(head -1 "$R/etc/issue")"
echo "  grub 发行商  → $(grep DISTRIBUTOR "$R/etc/default/grub")"

echo
echo "════ 2/5 用户名 mili → $NEWUSER ════"
if grep -q '^mili:' "$R/etc/passwd" 2>/dev/null; then
    for f in passwd shadow group gshadow subuid subgid passwd- shadow- group- gshadow-; do
        [ -f "$R/etc/$f" ] && sed -i 's/\bmili\b/dsh/g' "$R/etc/$f"
    done
    [ -d "$R/home/olduser" ] && mv "$R/home/olduser" "$R/home/$NEWUSER"
    sed -i 's/\bmili\b/dsh/g' "$R/etc/lightdm/lightdm.conf.d/50-autologin.conf" 2>/dev/null
    echo "  passwd : $(grep "^$NEWUSER:" "$R/etc/passwd")"
    echo "  自动登录: $(grep autologin-user= "$R/etc/lightdm/lightdm.conf.d/50-autologin.conf" | head -2 | tr '\n' ' ')"
    echo "  home   : $(ls -d "$R/home/$NEWUSER" 2>/dev/null || echo 缺)"
else
    echo "  （已经改过了，跳过）"
fi

echo
echo "════ 3/5 画一张 DSH OS 壁纸 ════"
W="$R/usr/share/backgrounds/dsh-os.png"
mkdir -p "$(dirname "$W")"
FONT=""
for cand in /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
            /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf; do
    [ -f "$cand" ] && { FONT="-font $cand"; break; }
done
# shellcheck disable=SC2086
convert -size 1920x1200 gradient:'#0a1f33'-'#12507d' \
    $FONT -gravity center \
    -pointsize 190 -fill '#eaf6ff' -annotate +0-70 "$BRAND" \
    -pointsize 46  -fill '#8fc4e8' -annotate +0+90 "Debian 13 (trixie) · built by hand" \
    "$W" && echo "  ✔ $W ($(identify -format '%wx%h' "$W"))" || echo "  ✘ 生成失败"

echo
echo "════ 4/5 让桌面用上这张（四重保险）════"
# 壁纸的矢量版：主题里那些 *.svg 用它
write_wall_svg() {
    cat > "$1" <<'SVGEOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1920" height="1200" viewBox="0 0 1920 1200">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0a1f33"/>
      <stop offset="1" stop-color="#12507d"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="1920" height="1200" fill="url(#bg)"/>
  <text x="960" y="640" font-family="DejaVu Sans, Noto Sans CJK SC, sans-serif"
        font-size="200" font-weight="bold" fill="#eaf6ff" text-anchor="middle">DSH OS</text>
  <text x="960" y="730" font-family="DejaVu Sans, Noto Sans CJK SC, sans-serif"
        font-size="46" fill="#8fc4e8" text-anchor="middle">Debian 13 (trixie) · built by hand</text>
</svg>
SVGEOF
}
# 4a) 覆盖当前激活主题里的壁纸文件
THEME_LINK="$(readlink "$R/etc/alternatives/desktop-theme" 2>/dev/null)"
THEME="$(readlink "$R/etc/alternatives/$THEME_LINK" 2>/dev/null)"
[ -n "$THEME" ] && [ -d "$R$THEME" ] || THEME="$THEME_LINK"
if [ -n "${THEME:-}" ] && [ -d "$R$THEME" ]; then
    echo "  激活主题：$THEME"
    n=0
    while IFS= read -r img; do
        case "$img" in
            *.png|*.jpg) cp -f "$W" "$img" && n=$((n+1));;
            *.svg)       write_wall_svg "$img" && n=$((n+1));;
        esac
    done < <(find "$R$THEME" -path '*wallpaper*' -type f 2>/dev/null)
    echo "    覆盖了 $n 个主题壁纸文件（png/jpg/svg 全覆盖）"
else
    echo "  （读不出激活主题，跳过 4a）"
fi
# 4b) 顺手把 xfce 自带那几张也换掉
n=0
for img in "$R"/usr/share/xfce4/backdrops/*.png "$R"/usr/share/xfce4/backdrops/*.jpg; do
    [ -f "$img" ] && cp -f "$W" "$img" && n=$((n+1))
done
echo "    xfce 自带 backdrop 换了 $n 张"

# 4c) 两个 xfconf 渠道文件（系统级 + 用户预置），能命中就一定生效
write_xfdesktop() {
    cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorVGA-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/backgrounds/dsh-os.png"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
      <property name="monitorVirtual-1" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/backgrounds/dsh-os.png"/>
          <property name="image-style" type="int" value="5"/>
        </property>
      </property>
    </property>
  </property>
  <property name="last-settings-migration-version" type="uint" value="1"/>
</channel>
EOF
}
mkdir -p "$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
write_xfdesktop "$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
mkdir -p "$R/home/$NEWUSER/.config/xfce4/xfconf/xfce-perchannel-xml"
write_xfdesktop "$R/home/$NEWUSER/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml"
# ⚠️ 上次踩的坑：渠道 xfce4-desktop 的配置文件名必须叫 xfce4-desktop.xml。
#    上一轮写成了 xfdesktop.xml → 根本没人读 → xfdesktop 回落到编译进去的默认图
#    （/usr/share/backgrounds/xfce/xfce-x.svg），所以开机还是 Debian 那张。
rm -f "$R/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfdesktop.xml" \
      "$R/home/$NEWUSER/.config/xfce4/xfconf/xfce-perchannel-xml/xfdesktop.xml"
chown -R 1000:1000 "$R/home/$NEWUSER" 2>/dev/null
echo "    xfconf 渠道文件写了两份（系统级 + 用户预置，文件名 xfce4-desktop.xml）"

# 4d) 兜底：xfdesktop 编译进去的那张默认图也换成 DSH OS
#     —— 万一哪天配置没生效（比如新建用户），至少默认图是本项目的
if [ -f "$R/usr/share/backgrounds/xfce/xfce-x.svg" ]; then
    write_wall_svg "$R/usr/share/backgrounds/xfce/xfce-x.svg"
    echo "    默认兜底图已换：/usr/share/backgrounds/xfce/xfce-x.svg"
fi

echo
echo "════ 5/5 核对 ════"
echo "  os-release   : $(grep -E '^(NAME|PRETTY_NAME)=' "$R/etc/os-release" | tr '\n' ' ')"
echo "  hostname     : $(cat "$R/etc/hostname")"
echo "  有 dsh 用户吗: $(grep -c '^dsh:' "$R/etc/passwd")"
echo "  还剩几处 mili: $(grep -rl '\bmili\b' "$R/etc" 2>/dev/null | tr '\n' ' ')"
chown -R 1000:1000 "$R" 2>/dev/null
echo
echo "✔ 改完了。跑「本轮A-开机看桌面.sh」重新生成镜像就能看到。"
