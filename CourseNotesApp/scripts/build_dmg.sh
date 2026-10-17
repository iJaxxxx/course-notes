#!/bin/bash
# build_dmg.sh — 编译「课程笔记」并打包成可分发的 DMG
# 用法：scripts/build_dmg.sh        产物：dist/课程笔记.app、dist/课程笔记-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="课程笔记"
EXEC="CourseNotes"
BUNDLE_ID="com.coursenotes.app"
VERSION="${VERSION:-1.0.0}"
BUILD="$(date +%Y%m%d%H%M)"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "▶ 编译（release, arm64）"
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: |Compiling|Build complete" | grep -v "^$" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$EXEC"
[[ -x "$BIN" ]] || { echo "编译失败"; exit 1; }

echo "▶ 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"

if [[ ! -f build/AppIcon.icns ]]; then
  echo "▶ 生成图标"
  rm -rf build/AppIcon.iconset && mkdir -p build
  swift scripts/make_icon.swift build/AppIcon.iconset >/dev/null
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.education</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>用麦克风录制课程声音（选择「麦克风」作为录制来源时）。</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>在本机把课程录音转成文字，音频不会上传。</string>
  <key>NSAudioCaptureUsageDescription</key><string>录制电脑正在播放的课程声音。</string>
</dict>
</plist>
EOF

echo "▶ 签名（ad-hoc）"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

echo "▶ 打包 DMG"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/打不开？看这里.txt" <<'EOF'
第一次打开「课程笔记」时，macOS 可能提示“无法验证开发者”。这是因为 App 没有付费签名，按下面做一次即可：

1. 把「课程笔记」拖进「应用程序」文件夹
2. 双击打开，看到提示后点「完成」
3. 打开「系统设置 → 隐私与安全性」，滚到最下面，点「仍要打开」，输入开机密码

或者在「终端」里执行一行（效果相同）：
  xattr -cr /Applications/课程笔记.app

首次录制「电脑声音」时会请求「屏幕与系统录音」权限：在系统设置里打开「课程笔记」，然后退出并重新打开 App。
需要 macOS 26 及以上、Apple 芯片的 Mac。
EOF
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
echo "✅ $DMG（$(du -h "$DMG" | cut -f1)）"
