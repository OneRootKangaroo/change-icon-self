#!/bin/zsh
# install.sh — 安装并验证 push_icons.sh 所需的全部依赖 (macOS)
#
# 依赖清单:
#   1. adb        (android-platform-tools, 用于连接手机)
#   2. python3    (图像处理运行时)
#   3. Pillow     (Python 图像库, 生成图标变体)
#
# 用法: ./install.sh
# 全部就绪时输出: ✅已安装全部依赖

set -u

missing=()

has_adb()    { command -v adb >/dev/null 2>&1; }
has_python3(){ command -v python3 >/dev/null 2>&1; }
has_pillow() { python3 -c 'import PIL' >/dev/null 2>&1; }

check() {
  missing=()
  has_adb     || missing+=("adb")
  has_python3 || missing+=("python3")
  if has_python3; then
    has_pillow || missing+=("Pillow")
  else
    missing+=("Pillow")
  fi
}

echo "== 检查依赖 =="
check

if ((${#missing[@]} > 0)); then
  echo "缺少: ${missing[*]}"

  if ! command -v brew >/dev/null 2>&1; then
    echo "未检测到 Homebrew, 无法自动安装。请先安装 Homebrew:"
    echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    exit 1
  fi

  has_adb || { echo "安装 adb ..."; brew install --cask android-platform-tools || brew install android-platform-tools; }
  has_python3 || { echo "安装 python3 ..."; brew install python@3; }
  if has_python3 && ! has_pillow; then
    echo "安装 Pillow ..."
    python3 -m pip install --user pillow \
      || python3 -m pip install --user --break-system-packages pillow
  fi
fi

echo "== 验证 =="
check
if ((${#missing[@]} > 0)); then
  echo "以下依赖仍未就绪: ${missing[*]}"
  exit 1
fi

echo "  adb:     $(adb version | head -1)"
echo "  python3: $(python3 --version)"
echo "  Pillow:  $(python3 -c 'import PIL; print(PIL.__version__)')"
echo "✅已安装全部依赖"
