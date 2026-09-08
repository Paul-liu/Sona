#!/usr/bin/env bash
#
# 把 swift build 的 release 产物组装成标准 macOS Sona.app bundle
#
# 用法（工程根目录任意位置执行）：
#   swift build -c release --disable-sandbox
#   ./Scripts/make_app.sh
#
# 产物：工程根目录 ./Sona.app（ad-hoc 签名，可拖入 /Applications，
#       内容与 GitHub Release 中的 Sona.app.zip 一致）
#
# 版本号来源（优先级从高到低）：
#   1. 环境变量 SONA_VERSION / SONA_BUILD
#   2. 最近的 git tag（如 v1.1.3 -> 1.1.3）
#   3. 回退默认 1.1.3 / build 1

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

BIN="$ROOT/.build/release/Sona"
ICON="$ROOT/Assets/AppIcon.icns"
APP="$ROOT/Sona.app"

# ---- 版本号 ----
if [ -n "${SONA_VERSION:-}" ]; then
  VERSION="$SONA_VERSION"
elif git describe --tags --abbrev=0 >/dev/null 2>&1; then
  VERSION=$(git describe --tags --abbrev=0 | sed 's/^v//')
else
  VERSION="1.1.3"
fi
BUILD="${SONA_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# ---- 防呆 ----
if [ ! -x "$BIN" ]; then
  echo "❌ 未找到构建产物 $BIN"
  echo "   请先运行：swift build -c release --disable-sandbox"
  exit 1
fi
if [ ! -f "$ICON" ]; then
  echo "❌ 未找到图标 $ICON"
  exit 1
fi

echo "==> 组装 Sona.app (v${VERSION} / build ${BUILD})"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Sona"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>Sona</string>
	<key>CFBundleExecutable</key>
	<string>Sona</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>cn.paulliu.Sona</string>
	<key>CFBundleName</key>
	<string>Sona</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.music</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<false/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

# ad-hoc 签名（与 Release 一致；未公证，Gatekeeper 首次打开需右键放行）
if codesign --force --deep -s - "$APP" >/dev/null 2>&1; then
  echo "    ad-hoc 签名完成"
else
  echo "    ⚠️ ad-hoc 签名失败（不影响本地直接运行）"
fi

# ---- 组装校验 ----
if [ -x "$APP/Contents/MacOS/Sona" ] && [ -f "$APP/Contents/Info.plist" ] && [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  echo "✅ 已生成 $APP (v${VERSION} / build ${BUILD})"
  echo "   可拖入 /Applications，或运行：open $APP"
else
  echo "❌ 组装不完整，请检查后重试"
  exit 1
fi
