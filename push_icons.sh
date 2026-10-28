#!/bin/zsh
# push_icons.sh — 把「自定义图标」文件夹里的 <应用名称>.png 批量应用到 vivo 主题图标
#
# 用法: ./push_icons.sh [图标文件夹]        (默认 脚本同目录/icon)
# 格式: png / jpg / jpeg / webp 均可, 内部统一转成 PNG 变体, 不改动源文件
# 前提: 手机已连 adb、KernelSU 已授权 shell、i主题 已应用目标主题
#
# 匹配方式 (不再依赖 icon_map.tsv):
#   从桌面数据库 launcher.db 直接读出「应用标题 + 组件名」,
#   用标题去 icon/ 里找同名图片 (大小写不敏感), 找到即处理。
#
# 原理(2026-10-24 豆包实测):
#   主题图标目录 /data/bbkcore/theme/icons/ (owner u0_a345, 777,
#   SELinux u:object_r:vivo_data_file:s0:c512,c768)
#   桌面按组件类名找图标, 应用信息/分身按包名找, 故每个应用同时推两套命名;
#   尺寸变体(以主题自带图标缓存实测为准: 高德/微信 blob, 240 档):
#     无后缀 240x240 / _1x2 240x480 / _2x1 480x240 / _2x2 480x480
#     四周透明边距 = 边长 * 21/240 (240 档 21px, 480 档 42px)
#     圆角半径 = 可见边 * 39/198 (240 档可见 198px, 半径 39px)
#     之前按 45px 边距生成导致自定义图标视觉上比主题自带小约 25%
#   刷新: 桌面不监听主题目录变化, 重启桌面无效, 单独发 intent.action.theme.changed 也无效;
#   故直接写 launcher.db 的 location_* 表 icon 字段 (240x240 PNG) 再重启桌面, 不重装任何应用。
#   缓存更新按 表+行号 精确写入 (行号来自上一步的查询结果), 不再用包名 LIKE。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_DIR="${1:-$SCRIPT_DIR/icon}"
TARGET="/data/bbkcore/theme/icons"
OWNER="u0_a345:u0_a345"
SECTX="u:object_r:vivo_data_file:s0:c512,c768"
DB="/data/user_de/0/com.bbk.launcher2/databases/launcher.db"
tables=(location_jan location_jan_drawer location_feb location_feb_drawer location_simple)

[[ -d "$ICON_DIR" ]] || { echo "图标文件夹不存在: $ICON_DIR"; exit 1; }

echo "== 检查设备与 root =="
adb shell "su -c 'id'" | grep -q 'uid=0' || { echo "ADB root 不可用, 检查 KernelSU 是否授权 shell"; exit 1; }

# 换主题会清空/删除该目录, 不存在时按实测的 owner/权限/SELinux 重建
adb shell "su -c 'mkdir -p $TARGET && chown $OWNER $TARGET && chmod 777 $TARGET && chcon $SECTX $TARGET'" \
  || { echo "无法准备目标目录 $TARGET"; exit 1; }

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

echo "== 从桌面数据库读取应用标题与组件 =="
# 直接从库中取 表名/行号/标题/intent, 后续缓存按行号精确回写
ROWS_FILE="$BUILD/rows.tsv"
# 多层 shell 嵌套下引号容易被吃掉, 改成推 SQL 文件用重定向执行
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

# 由源图生成 4 个尺寸变体, 几何以主题自带图标缓存实测为准:
#   边距 = 边长 * 21/240 (四周), 圆角半径 = 可见边 * 39/198
#   主题没有 _1x1 变体, 不生成
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

# 边距与圆角按主题自带图标的实测比例: 240 档边距 21, 可见 198, 半径 39
MARGIN_RATIO = 21 / 240   # 四周透明边距占边长比例
RADIUS_RATIO = 39 / 198   # 圆角半径占可见边比例
VARIANTS = [("", 240, 240), ("_1x2", 240, 480),
            ("_2x1", 480, 240), ("_2x2", 480, 480)]

for suffix, cw, ch in VARIANTS:
    mx = round(cw * MARGIN_RATIO)
    my = round(ch * MARGIN_RATIO)
    ax0, ay0 = mx, my
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
    canvas.paste(tile, (ax0, ay0), tile)
    canvas.save(f"{base}{suffix}.png")
PY
}

# 逐行处理桌面条目: 标题 -> 图片, 组件类名 -> 主题文件名, 行号 -> 缓存回写
ok=0
typeset -A generated    # 已生成变体的类名, 避免重复生成
typeset -A matched_icon # 已匹配上的图片索引 key, 用于最后统计未用到的图
typeset -a upd_table upd_id upd_png
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
    gen_variants "$src" "$BUILD/$cls"
    [[ "$pkg" != "$cls" ]] && gen_variants "$src" "$BUILD/$pkg"
    generated[$cls]=1
    matched_icon[$key]=1
  fi
  upd_table+=("$tbl"); upd_id+=("$id"); upd_png+=("$cls")
done < "$ROWS_FILE"
ok=${#generated[@]}

# 报告本地有图但没匹配到任何桌面条目的
for k v in ${(kv)icon_index}; do
  if [[ -z "${matched_icon[$k]:-}" ]]; then
    echo "[跳过] ${v:t:r} —— 桌面上没有叫这个名字的应用"
  fi
done

(( ok > 0 )) || { echo "没有可推送的图标"; exit 0; }

echo "== 推送 $ok 个应用的图标到手机 =="
adb push "$BUILD"/*.png /data/local/tmp/ >/dev/null

# 逐文件: 拷贝 + owner + 权限 + SELinux 上下文
# 组件名里可能出现 $ (如 YouTube 的 Shell$HomeActivity), 必须整体加引号, 故生成设备端脚本执行
files=("$BUILD"/*.png)
APPLY="$BUILD/apply.sh"
{
  for f in "${files[@]}"; do echo "cp '/data/local/tmp/${f:t}' '$TARGET/'"; done
  echo "cd '$TARGET'"
  for f in "${files[@]}"; do echo "chown $OWNER '${f:t}'; chmod 777 '${f:t}'; chcon $SECTX '${f:t}'"; done
} > "$APPLY"
remote_list=""
for f in "${files[@]}"; do remote_list+="/data/local/tmp/${f:t} "; done
adb push "$APPLY" /data/local/tmp/apply_icons.sh >/dev/null
adb shell "su -c 'sh /data/local/tmp/apply_icons.sh'"

echo "== 写入桌面图标缓存 =="
# 桌面把图标位图缓存在 launcher.db 的 location_* 表 icon 字段 (240x240 PNG)。
# 只重启桌面不会重读主题目录; 应用主题的 intent.action.theme.changed 广播单独发也无效。
# 因此直接把生成好的 240 档 PNG 写进缓存, 再重启桌面。按 表+行号 精确写入。
SQL="$BUILD/update.sql"
echo ".timeout 15000" > "$SQL"
for ((i=1; i<=${#upd_table[@]}; i++)); do
  echo "UPDATE ${upd_table[i]} SET icon=readfile('/data/local/tmp/${upd_png[i]}.png') WHERE _id=${upd_id[i]};" >> "$SQL"
done

adb shell "su -c 'am force-stop com.bbk.launcher2; sleep 1'"
adb shell "su -c 'cp $DB /data/local/tmp/launcher.db.bak'"
adb push "$SQL" /data/local/tmp/update_icons.sql >/dev/null
adb shell "su -c 'sqlite3 $DB < /data/local/tmp/update_icons.sql'"
# 清掉 root 产生的日志文件并恢复 owner/权限, 否则桌面可能打不开库
adb shell "su -c 'rm -f $DB-journal $DB-wal $DB-shm; chown u0_a108:u0_a108 $DB; chmod 660 $DB'"
# 写库期间系统可能已自动把桌面拉起来并缓存了旧图, 再停一次确保它重启后读新缓存
adb shell "su -c 'am force-stop com.bbk.launcher2; sleep 1; am force-stop com.bbk.launcher2'"
adb shell "su -c 'am start -n com.bbk.launcher2/.Launcher'" >/dev/null 2>&1 || true

adb shell "su -c 'rm -f $remote_list'"

echo "完成: 成功 $ok 个应用 (写入 ${#upd_table[@]} 行缓存)。解锁手机查看效果。"
echo "缓存库备份: /data/local/tmp/launcher.db.bak"
