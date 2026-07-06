#!/usr/bin/env bash
# 打包 MonitorControl.app 为可分发的 .dmg
# 用法: ./scripts/build-dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="MonitorControl.xcodeproj"
SCHEME="MonitorControl"
CONFIG="Release"
APP_NAME="MonitorControl"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_NAME/Info.plist" 2>/dev/null \
          || /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_NAME/Info.plist")
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
BUILD_DIR="build"

echo "==> 配置"
echo "    project = $PROJECT"
echo "    scheme  = $SCHEME"
echo "    config  = $CONFIG"
echo "    dmg     = $DMG_NAME"

# 1) 编译 Release(禁止代码签名以避免需要 Apple Developer 账号)
echo "==> xcodebuild Release"
rm -rf "$BUILD_DIR"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build | tail -5

APP_PATH="$(find "$BUILD_DIR/DerivedData/Build/Products/$CONFIG" -maxdepth 1 -name "$APP_NAME.app" | head -1)"
if [ -z "$APP_PATH" ]; then
  echo "❌ 找不到编译产物 $APP_NAME.app"
  exit 1
fi
# 从编译后的 .app 读真实 version(源码 plist 用的是 $(MARKETING_VERSION),编译后才被替换)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
DMG_NAME="${APP_NAME}-v${VERSION}.dmg"
echo "    构建产物 = $APP_PATH"
echo "    实际版本 = $VERSION"

# 2) ad-hoc 签名(没有 Apple 开发者账号也能用,只是其他机器首次打开需要右键 → 打开)
echo "==> codesign --sign -"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --verbose "$APP_PATH" || true

# 3) 准备 dmg 暂存目录
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

# 4) 生成 dmg
echo "==> hdiutil create"
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create \
  "$BUILD_DIR/$DMG_NAME" \
  -volname "$APP_NAME v$VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO

echo "==> 完成"
echo "    dmg path = $BUILD_DIR/$DMG_NAME"
echo
echo "用这个文件:"
echo "    open \"$BUILD_DIR/$DMG_NAME\""
