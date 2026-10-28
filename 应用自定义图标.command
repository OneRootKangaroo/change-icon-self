#!/bin/zsh
# 双击运行: 把 icon/ 里的图标推送到手机主题
cd "$(dirname "$0")" && ./push_icons.sh
echo ""
read -n 1 -s -r "?按任意键关闭窗口..."
