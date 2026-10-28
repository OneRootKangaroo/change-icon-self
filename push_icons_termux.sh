#!/data/data/com.termux/files/usr/bin/bash
# push_icons_termux.sh — Termux 版: 在手机上直接把 icon/ 里的图片注入当前第三方主题包
#
# 用法: ./push_icons_termux.sh [图标文件夹] [主题名]   (默认 脚本同目录/icon; 主题名自动识别)
# 前提: Termux 内已安装 python / python-pillow / zip / sqlite,
#       KernelSU 已授权 Termux 的 root, i主题 已应用一个第三方主题
# 逻辑与电脑版 push_icons.sh 相同, 区别仅是全部操作在本机进行, root 直接用 su。
#
# 流程: 读桌面数据库匹配标题 -> 生成主题规范图标 -> 注入当前主题包 -> 重新应用主题生效
# 图标规范: 240x240 可见区 62% (边距45px 圆角37px), 变体 _1x2/_2x1/_2x2
# 注意: 主题更新/重下会覆盖修改, 重跑即可; 首次修改前自动备份原包为 .itz.bak

set -euo pipefail
shopt -s nullglob   # 通配无匹配时展开为空, 而不是原样保留

# 依赖检测: 缺失时给出安装命令
_dep_missing=()
for c in python zip unzip sqlite3 su; do
  command -v "$c" >/dev/null 2>&1 || _dep_missing+=("$c")
done
python3 -c 'import PIL' >/dev/null 2>&1 || _dep_missing+=("python-pillow")
if ((${#_dep_missing[@]} > 0)); then
  echo "依赖未安装: ${_dep_missing[*]}"
  echo "请运行: pkg install python python-pillow zip sqlite"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_DIR="${1:-$SCRIPT_DIR/icon}"
THEME_ARG="${2:-}"
THEME_DIR="/data/bbkcore/theme"
DB="/data/user_de/0/com.bbk.launcher2/databases/launcher.db"
tables=(location_jan location_jan_drawer location_feb location_feb_drawer location_simple)

[[ -d "$ICON_DIR" ]] || { echo "图标文件夹不存在: $ICON_DIR"; exit 1; }

echo "== 检查 root =="
su -c 'id' | grep -q 'uid=0' || { echo "root 不可用, 检查 KernelSU 是否授权 Termux"; exit 1; }

# 不信任 TMPDIR (经 su 启动的 sshd 会把会话 TMPDIR 带成 /data/local/tmp, 无写权限)
BUILD="$(mktemp -d "${PREFIX:-/data/data/com.termux/files/usr}/tmp/theme_icons.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT

# 建立 icon/ 图片索引: 小写文件名(去扩展名) -> 文件路径
declare -A icon_index
for src in "$ICON_DIR"/*; do
  [[ -f "$src" ]] || continue
  ext="${src##*.}"
  case "${ext,,}" in
    png|jpg|jpeg|webp) ;;
    *) continue ;;
  esac
  name="${src##*/}"
  name_noext="${name%.*}"
  icon_index["${name_noext,,}"]="$src"
done
(( ${#icon_index[@]} > 0 )) || { echo "图标文件夹里没有可用图片: $ICON_DIR"; exit 1; }

echo "== 识别当前主题包 =="
# 当前主题名在 description.xml 里; 主题包是 .dwd 下的 .itz (排除 F/字体 U/解锁样式)
if [[ -n "$THEME_ARG" ]]; then
  theme_name="$THEME_ARG"
else
  theme_name=$(su -c "cat $THEME_DIR/description.xml" | tr -d '\r' \
    | sed -n 's/.*<title[^>]*><!\[CDATA\[\(.*\)\]\]><\/title>.*/\1/p' | head -1)
fi
[[ -n "$theme_name" && "$theme_name" != "默认" ]] \
  || { echo "未识别到第三方主题, 请先在 i主题 下载并应用一个第三方主题"; exit 1; }

itz_remote=$(su -c "find $THEME_DIR/.dwd -name '*.itz'" | tr -d '\r' \
  | grep -v '/F/' | grep -v '/U/' | { grep "/${theme_name}.itz$" || true; } | head -1)
[[ -n "$itz_remote" ]] || {
  echo "找不到主题包文件: ${theme_name}.itz, 设备上的主题包有:"
  su -c "find $THEME_DIR/.dwd -name '*.itz'" | tr -d '\r' | grep -v '/F/' | grep -v '/U/'
  echo "提示: 请先在 i主题 应用设备上存在的第三方主题, 或用第二个参数手动指定主题名"
  exit 1
}
echo "当前主题: $theme_name ($itz_remote)"

echo "== 从桌面数据库读取应用标题与组件 =="
ROWS_FILE="$BUILD/rows.tsv"
QSQL="$BUILD/query.sql"
{
  echo ".mode tabs"
  for t in "${tables[@]}"; do
    echo "SELECT '$t',_id,title,intent FROM $t WHERE title IS NOT NULL AND title<>'' AND intent LIKE '%/%';"
  done
} > "$QSQL"
# Termux 会话里 su 直读 /data/user_de 可能因 SELinux 类别被拦, 先拷到本地再查
su -c "cat '$DB'" > "$BUILD/launcher.db" \
  || { echo "无法读取桌面数据库, 检查 root 权限"; exit 1; }
sqlite3 "$BUILD/launcher.db" < "$QSQL" | tr -d '\r' | sed 's/"//g' > "$ROWS_FILE"
[[ -s "$ROWS_FILE" ]] || { echo "读取桌面数据库失败"; exit 1; }
echo "共 $(wc -l < "$ROWS_FILE" | tr -d ' ') 行桌面条目"

# 由源图生成 4 个尺寸变体, 几何与主题包原始图标一致: 62% 可见区
gen_variants() {
  local src="$1" base="$2"
  python3 - "$src" "$base" <<'PY'
import sys
from PIL import Image, ImageDraw, ImageChops
src, base = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGBA")

# 裁掉源图四周的透明留白, 只保留实际图形, 便于统一按主题几何摆放
bbox = img.getchannel("A").getbbox()
if bbox:
    img = img.crop(bbox)

# 主题包规范: 240 档边距 45px, 可见 150px, 圆角 37px
MARGIN_RATIO = 45 / 240
RADIUS_RATIO = 37 / 150

for suffix, cw, ch in [("", 240, 240), ("_1x2", 240, 480),
                       ("_2x1", 480, 240), ("_2x2", 480, 480)]:
    mx = round(cw * MARGIN_RATIO)
    my = round(ch * MARGIN_RATIO)
    aw, ah = cw - mx * 2, ch - my * 2
    radius = round(min(aw, ah) * RADIUS_RATIO)

    # 等比缩放到留白区 (允许放大, 保证各尺寸视觉大小一致)
    scale = min(aw / img.width, ah / img.height)
    art = img.resize((max(1, round(img.width * scale)),
                      max(1, round(img.height * scale))), Image.LANCZOS)

    tile = Image.new("RGBA", (aw, ah), (0, 0, 0, 0))
    tile.paste(art, ((aw - art.width) // 2, (ah - art.height) // 2), art)

    # 圆角遮罩, 4x 超采样抗锯齿
    s = 4
    mask = Image.new("L", (aw * s, ah * s), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, aw * s - 1, ah * s - 1], radius=radius * s, fill=255)
    mask = mask.resize((aw, ah), Image.LANCZOS)
    tile.putalpha(ImageChops.multiply(tile.getchannel("A"), mask))

    canvas = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
    canvas.paste(tile, (mx, my), tile)
    canvas.save(f"{base}{suffix}.png")
PY
}

# 逐行处理桌面条目: 标题 -> 图片, 组件类名 -> 主题包内文件名
ok=0
generated_list=""     # 已生成变体的类名 (空格分隔), 避免重复生成
matched_list=""       # 已匹配上的图片名 (空格分隔), 用于最后统计未用到的图
mkdir -p "$BUILD/staging/icons"
while IFS=$'\t' read -r tbl id title intent; do
  key="${title,,}"
  src="${icon_index[$key]:-}"
  [[ -n "$src" ]] || continue   # 该标题没有同名图片, 静默略过 (最后统一报未用到的图)

  # intent 列就是组件名: 包名/类名; 类名以 . 开头需补包名前缀
  pkg="${intent%%/*}"
  cls="${intent#*/}"
  if [[ "$cls" == .* ]]; then
    cls="$pkg$cls"
  fi

  if [[ " $generated_list " != *" $cls "* ]]; then
    echo "[处理] $title -> $cls"
    gen_variants "$src" "$BUILD/staging/icons/$cls"
    [[ "$pkg" != "$cls" ]] && gen_variants "$src" "$BUILD/staging/icons/$pkg"
    generated_list+=" $cls"
    matched_list+=" $key"
    ((ok++)) || true
  fi
done < "$ROWS_FILE"

# 报告本地有图但没匹配到任何桌面条目的
for k in "${!icon_index[@]}"; do
  if [[ " $matched_list " != *" $k "* ]]; then
    v="${icon_index[$k]}"
    echo "[跳过] ${v##*/} —— 桌面上没有叫这个名字的应用"
  fi
done

(( ok > 0 )) || { echo "没有可注入的图标"; exit 0; }

echo "== 拉取主题包并注入 $ok 个应用的图标 =="
# root 用 cat 读出主题包 (组件名可能含 $, zip 文件操作不经 shell 展开, 天然安全)
su -c "cat '$itz_remote'" > "$BUILD/theme.itz"
( cd "$BUILD/staging" && zip -q -r "$BUILD/theme.itz" icons )
# 校验: 包内不允许出现 0 字节的 PNG (曾因此导致 YouTube 图标破损)
bad=$(unzip -l "$BUILD/theme.itz" | awk '$1==0 && $4 ~ /png$/ {print $4}')
[[ -z "$bad" ]] || { echo "注入后包内出现空文件: $bad"; exit 1; }

echo "== 替换设备上的主题包 =="
# 首次修改前备份原包, 之后不覆盖备份
su -c "[ -f '$itz_remote.bak' ] || cp '$itz_remote' '$itz_remote.bak'"
cat "$BUILD/theme.itz" | su -c "cat > '$itz_remote'"
su -c "chown u0_a345:u0_a345 '$itz_remote'; chmod 777 '$itz_remote'; chcon u:object_r:vivo_data_file:s0:c512,c768 '$itz_remote'"

echo "完成: 已向主题「$theme_name」注入 $ok 个应用的图标。"
echo "原包备份: $itz_remote.bak"
echo "最后一步: 打开 i主题 → 我的 → 主题 → 重新应用「$theme_name」, 图标即生效。"
