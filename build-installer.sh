#!/bin/bash
#
# build-installer.sh — 生成「拖拽到应用程序」的安装包（.dmg）
#
# DMG 里是一个可正常运行的 App。用户把它拖进「应用程序」，然后打开，
# 在 App 界面内完成全部配置（服务端、配对密钥、钥匙串、开机自启、权限引导）。
#
# 为什么不在 DMG 里直接安装：
#   DMG 是只读挂载，从中运行并修改系统很容易出问题；而且 Gatekeeper 的路径
#   随机化会让辅助功能权限每次都无法稳定绑定。拖拽到 /Applications 后路径稳定，
#   权限才能持久。
#
# 关于 CPU 架构：本机 Command Line Tools 的 Swift 兼容库只有 arm64
# （libswiftCompatibility56.a 为 arm64/arm64e），无法交叉编译 x86_64，
# 因此安装包目前只支持 Apple Silicon。要出通用二进制需要完整 Xcode。
#
# 用法:
#   ./build-installer.sh           生成 dist/BLEUnlock-<版本>-arm64.dmg
#   ./build-installer.sh clean     清理中间产物

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------- 配置

VERSION="${VERSION:-1.3.1}"
MIN_MACOS="11.0"
ARCH="${ARCH:-arm64}"

APP_NAME="BLE Unlock"
EXEC_NAME="BLEUnlockSetup"
BUNDLE_ID="com.bleunlock.setup"
SERVICE_BUNDLE_ID="jp.sone.bleunlockcmd"

BUILD="$SCRIPT_DIR/build/installer"
DIST="$SCRIPT_DIR/dist"
APP="$BUILD/$APP_NAME.app"
APP_BIN="$APP/Contents/MacOS/$EXEC_NAME"
APP_RES="$APP/Contents/Resources"
STAGE="$BUILD/dmg-stage"
DMG="$DIST/BLEUnlock-${VERSION}-${ARCH}.dmg"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_BLUE=$'\033[34m'; C_YELLOW=$'\033[33m'
else
    C_RESET=""; C_GREEN=""; C_RED=""; C_BLUE=""; C_YELLOW=""
fi
info() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*"; }
die()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; exit 1; }

if [ "${1:-}" = "clean" ]; then
    rm -rf "$BUILD"
    rm -f "$DIST"/BLEUnlock-*.dmg
    ok "已清理安装包构建产物"
    exit 0
fi

command -v swiftc >/dev/null 2>&1 || die "找不到 swiftc（需要 Xcode Command Line Tools）"
command -v hdiutil >/dev/null 2>&1 || die "找不到 hdiutil"

info "版本 $VERSION / 架构 $ARCH / macOS $MIN_MACOS+"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP_RES" "$STAGE" "$DIST"

# ---------------------------------------------------------------- 1. 服务端（预编译）

info "编译服务端（${ARCH}）"
swiftc -O -suppress-warnings \
    -module-cache-path "$SCRIPT_DIR/.cache" \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    mac-src/main.swift \
    -o "$APP_RES/BLEUnlockCmd" \
    || die "服务端编译失败"
chmod 755 "$APP_RES/BLEUnlockCmd"

# 预签名：设置向导会连同签名一起复制到安装位置，使辅助功能权限绑定到
# 稳定的签名标识。标识必须与向导写入 Info.plist 的一致。
codesign --force --sign - --identifier "$SERVICE_BUNDLE_ID" \
    "$APP_RES/BLEUnlockCmd" >/dev/null 2>&1 \
    && ok "服务端已预签名" || warn "服务端签名失败（设置时仍会重签）"
ok "服务端：$(file -b "$APP_RES/BLEUnlockCmd" | cut -d, -f1)"

# ---------------------------------------------------------------- 2. 设置向导界面

info "生成版本信息"
cat > "$BUILD/BuildInfo.swift" <<SWIFT
// 由 build-installer.sh 生成，请勿手工修改
enum BuildInfo {
    static let serviceVersion = "$VERSION"
    static let installerVersion = "$VERSION"
}
SWIFT

info "编译设置向导"
swiftc -O -suppress-warnings \
    -module-cache-path "$SCRIPT_DIR/.cache" \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    "$BUILD/BuildInfo.swift" \
    installer-src/app/Installer.swift \
    installer-src/app/SetupWindow.swift \
    installer-src/app/AppDelegate.swift \
    installer-src/app/main.swift \
    -o "$APP_BIN" \
    || die "设置向导编译失败"
chmod 755 "$APP_BIN"
ok "设置向导已编译"

# ---------------------------------------------------------------- 3. App 外壳

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${EXEC_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 \
    && ok "App 已签名（adhoc）" || warn "App 签名失败（不影响功能）"

# ---------------------------------------------------------------- 4. DMG

info "制作 DMG（拖拽安装布局）"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
BLE Unlock
==========

安装步骤
--------
1. 把左边的「BLE Unlock」拖到右边的「Applications」文件夹
2. 打开「应用程序」里的 BLE Unlock
3. 按提示输入一次登录密码，其余全自动完成

首次打开如果提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」：
  右键点击 App → 选择「打开」→ 在弹窗中再点「打开」
（只需做一次。本项目没有 Apple 开发者签名证书，无法通过公证，
 与程序安全性无关。）

说明
----
• 请从「应用程序」运行，不要直接在 DMG 里运行
  （DMG 是只读的，且系统会给它分配随机路径，会导致权限无法保存）
• 再次打开本 App 即为重新配置/更新，配对密钥会保留
• 配置日志在 ~/Library/Logs/BLEUnlockSetup.log
TXT

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null 2>&1 || die "DMG 制作失败"

ok "已生成：$DMG （$(ls -lh "$DMG" | awk '{print $5}')）"

# ---------------------------------------------------------------- 5. 自检

info "自检"
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null | grep -o '/Volumes/.*' | head -1)
if [ -n "$MOUNT" ]; then
    INNER="$MOUNT/$APP_NAME.app/Contents"
    [ -x "$INNER/MacOS/$EXEC_NAME" ] && ok "设置向导可执行文件存在" || warn "设置向导缺失"
    [ -x "$INNER/Resources/BLEUnlockCmd" ] && ok "服务端二进制存在" || warn "服务端二进制缺失"
    [ -L "$MOUNT/Applications" ] && ok "存在「应用程序」快捷方式（可拖拽安装）" || warn "缺少 Applications 链接"
    if "$INNER/Resources/BLEUnlockCmd" --version >/dev/null 2>&1; then
        ok "服务端可运行（$("$INNER/Resources/BLEUnlockCmd" --version)）"
    else
        warn "服务端无法运行"
    fi
    codesign -v "$MOUNT/$APP_NAME.app" >/dev/null 2>&1 \
        && ok "App 签名有效" || warn "App 签名校验未通过"
    codesign -v "$INNER/Resources/BLEUnlockCmd" >/dev/null 2>&1 \
        && ok "服务端签名有效" || warn "服务端签名校验未通过"
    hdiutil detach "$MOUNT" >/dev/null 2>&1
    ok "已卸载测试卷"
else
    warn "无法挂载 DMG 做自检"
fi

echo
ok "完成：$DMG"
echo
echo "  校验值：$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo
echo "  用户操作：拖进「应用程序」→ 打开 → 输入密码 → 按引导授权"
echo "  提醒：首次打开需右键 → 打开（无 Apple 开发者证书，无法公证）"
echo
