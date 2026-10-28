#!/bin/zsh
# push_icons.sh — 把「icon」文件夹里的 <应用名称>.png 注入当前第三方主题包
#
# 用法: ./push_icons.sh [图标文件夹] [主题名]   (默认 脚本同目录/icon; 主题名自动识别)
# 格式: png / jpg / jpeg / webp 均可, 内部统一转成 PNG 变体, 不改动源文件
# 前提: 手机已连 adb、KernelSU 已授权 shell、i主题 已应用一个第三方主题
#
# 流程:
#   1. 从桌面数据库 launcher.db 读出「应用标题 + 组件名」, 用标题去 icon/ 找同名图片
#   2. 生成主题规范的图标变体, 注入当前主题包 .itz (zip) 的 icons/ 目录
#   3. 替换设备上的主题包, 用户在 i主题 重新应用一次主题即生效
#
# 为什么走主题包而不是写桌面缓存 (2026-10-29 实测):
#   注入主题包后图标成为主题资源, 变形器调节图标大小不会回退,
#   电话/抖音/小红书等会被系统管线回退的顽固应用也能根治;
#   而写 launcher.db 缓存的做法会被回退、且变形器一调就还原, 已废弃。
#
# 图标规范 (实测自主题包原始图标):
#   无后缀 240x240 / _1x2 240x480 / _2x1 480x240 / _2x2 480x480 (无 _1x1)
#   可见区 62%: 四周透明边距 = 边长 * 45/240, 圆角半径 = 可见边 * 37/150
#   文件名: 桌面按组件类名找图标, 应用信息按包名找, 每个应用同时注入两套命名
#
# 注意: 主题从商店更新/重新下载会覆盖修改, 重跑本脚本即可;
#   首次修改前会在设备上备份原包为 <主题名>.itz.bak, 需要还原时改回即可。

set -euo pipefail

# 依赖检测: 缺失时提示先运行 install.sh
_dep_missing=()
command -v adb >/dev/null 2>&1 || _dep_missing+=("adb")
command -v python3 >/dev/null 2>&1 || _dep_missing+=("python3")
command -v zip >/dev/null 2>&1 || _dep_missing+=("zip")
python3 -c 'import PIL' >/dev/null 2>&1 || _dep_missing+=("Pillow")
if ((${#_dep_missing[@]} > 0)); then
  echo "依赖未安装，无法运行本脚本，请运行install.sh后再来"
  echo "缺少: ${_dep_missing[*]}"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_DIR="${1:-$SCRIPT_DIR/icon}"
THEME_ARG="${2:-}"
THEME_DIR="/data/bbkcore/theme"
DB="/data/user_de/0/com.bbk.launcher2/databases/launcher.db"
tables=(location_jan location_jan_drawer location_feb location_feb_drawer location_simple)

[[ -d "$ICON_DIR" ]] || { echo "图标文件夹不存在: $ICON_DIR"; exit 1; }

echo "== 检查设备与 root =="
adb shell "su -c 'id'" | grep -q 'uid=0' || { echo "ADB root 不可用, 检查 KernelSU 是否授权 shell"; exit 1; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# 建立 icon/ 图片索引: 小写文件名(去扩展名) -> 文件路径
typeset -A icon_index
for src in "$ICON_DIR"/*(N); do
  [[ -f "$src" ]] || continue
  case "${${src:e}:l}" in
    png|jpg|jpeg|webp) ;;
    *) continue ;;
  esac
  icon_index[${${${src:t}:r}:l}]="$src"
done
(( ${#icon_index[@]} > 0 )) || { echo "图标文件夹里没有可用图片: $ICON_DIR"; exit 1; }

echo "== 识别当前主题包 =="
# 当前主题名在 description.xml 里; 主题包是 .dwd 下的 .itz (排除 F/字体 U/解锁样式)
if [[ -n "$THEME_ARG" ]]; then
  theme_name="$THEME_ARG"
else
  theme_name=$(adb shell "su -c 'cat $THEME_DIR/description.xml'" | tr -d '\r' \
    | sed -n 's/.*<title[^>]*><!\[CDATA\[\(.*\)\]\]><\/title>.*/\1/p' | head -1)
fi
[[ -n "$theme_name" && "$theme_name" != "默认" ]] \
  || { echo "未识别到第三方主题, 请先在 i主题 下载并应用一个第三方主题"; exit 1; }

itz_remote=$(adb shell "su -c 'find $THEME_DIR/.dwd -name \"*.itz\"'" | tr -d '\r' \
  | grep -v '/F/' | grep -v '/U/' | grep "/${theme_name}.itz$" | head -1)
[[ -n "$itz_remote" ]] || {
  echo "找不到主题包文件: ${theme_name}.itz, 设备上的主题包有:"
  adb shell "su -c 'find $THEME_DIR/.dwd -name \"*.itz\"'" | tr -d '\r' | grep -v '/F/' | grep -v '/U/'
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
adb push "$QSQL" /data/local/tmp/query_rows.sql >/dev/null
adb shell "su -c 'sqlite3 $DB < /data/local/tmp/query_rows.sql'" | tr -d '\r' > "$ROWS_FILE"
adb shell "su -c 'rm -f /data/local/tmp/query_rows.sql'"
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
typeset -A generated    # 已生成变体的类名, 避免重复生成
typeset -A matched_icon # 已匹配上的图片索引 key, 用于最后统计未用到的图
mkdir -p "$BUILD/staging/icons"
while IFS=$'\t' read -r tbl id title intent; do
  key="${title:l}"
  src="${icon_index[$key]:-}"
  [[ -n "$src" ]] || continue   # 该标题没有同名图片, 静默略过 (最后统一报未用到的图)

  # intent 列就是组件名: 包名/类名; 类名以 . 开头需补包名前缀
  pkg="${intent%%/*}"
  cls="${intent#*/}"
  if [[ "$cls" == .* ]]; then
    cls="$pkg$cls"
  fi

  if [[ -z "${generated[$cls]:-}" ]]; then
    echo "[处理] $title -> $cls"
    gen_variants "$src" "$BUILD/staging/icons/$cls"
    [[ "$pkg" != "$cls" ]] && gen_variants "$src" "$BUILD/staging/icons/$pkg"
    generated[$cls]=1
    matched_icon[$key]=1
  fi
done < "$ROWS_FILE"
ok=${#generated[@]}

# 报告本地有图但没匹配到任何桌面条目的
for k v in ${(kv)icon_index}; do
  if [[ -z "${matched_icon[$k]:-}" ]]; then
    echo "[跳过] ${v:t:r} —— 桌面上没有叫这个名字的应用"
  fi
done

(( ok > 0 )) || { echo "没有可注入的图标"; exit 0; }

echo "== 拉取主题包并注入 $ok 个应用的图标 =="
# adb shell 身份无权读主题目录, 经 root 用 cat 拉取
adb shell "su -c 'cat \"$itz_remote\"'" > "$BUILD/theme.itz"
# 组件名里可能含 $ (如 YouTube 的 Shell$HomeActivity), 走 zip 文件操作不经 shell 展开, 天然安全
( cd "$BUILD/staging" && zip -q -r "$BUILD/theme.itz" icons )
# 校验: 包内不允许出现 0 字节的 PNG (曾因此导致 YouTube 图标破损)
bad=$(unzip -l "$BUILD/theme.itz" | awk '$1==0 && $4 ~ /png$/ {print $4}')
[[ -z "$bad" ]] || { echo "注入后包内出现空文件: $bad"; exit 1; }

echo "== 替换设备上的主题包 =="
# 首次修改前备份原包, 之后不覆盖备份
adb shell "su -c '[ -f \"$itz_remote.bak\" ] || cp \"$itz_remote\" \"$itz_remote.bak\"'"
adb push "$BUILD/theme.itz" /data/local/tmp/theme_new.itz >/dev/null
adb shell "su -c 'cat /data/local/tmp/theme_new.itz > \"$itz_remote\" && chown u0_a345:u0_a345 \"$itz_remote\" && chmod 777 \"$itz_remote\" && chcon u:object_r:vivo_data_file:s0:c512,c768 \"$itz_remote\" && rm /data/local/tmp/theme_new.itz'"

echo "完成: 已向主题「$theme_name」注入 $ok 个应用的图标。"
echo "原包备份: $itz_remote.bak"
echo "最后一步: 打开 i主题 → 我的 → 主题 → 重新应用「$theme_name」, 图标即生效。"
