#!/bin/bash
#
# build-installer.sh — 生成图形化安装包（.dmg）
#
# 产出一个双击即可安装的 DMG。里面是一个带界面的自安装 App，
# 服务端二进制已预编译在包内，用户不需要终端，也不需要 Xcode 命令行工具。
#
# 关于 CPU 架构：本机 Command Line Tools 的 Swift 兼容库只有 arm64
# （libswiftCompatibility56.a 为 arm64/arm64e），无法交叉编译 x86_64，
# 因此安装包目前只支持 Apple Silicon。要出通用二进制需要完整 Xcode。
#
# 用法:
#   ./build-installer.sh           生成 dist/BLEUnlock-Installer-<版本>.dmg
#   ./build-installer.sh clean     清理中间产物

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------- 版本

VERSION="${VERSION:-1.2.1}"
INSTALLER_VERSION="${INSTALLER_VERSION:-1.1.0}"
MIN_MACOS="11.0"
ARCH="${ARCH:-arm64}"

# ---------------------------------------------------------------- 目录

BUILD="$SCRIPT_DIR/build/installer"
DIST="$SCRIPT_DIR/dist"
APP="$BUILD/BLEUnlock Installer.app"
APP_BIN="$APP/Contents/MacOS/BLEUnlockInstaller"
APP_RES="$APP/Contents/Resources"
STAGE="$BUILD/dmg-stage"
DMG="$DIST/BLEUnlock-Installer-${VERSION}-${ARCH}.dmg"

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
    rm -f "$DIST"/BLEUnlock-Installer-*.dmg
    ok "已清理安装包构建产物"
    exit 0
fi

command -v swiftc >/dev/null 2>&1 || die "找不到 swiftc（需要 Xcode Command Line Tools）"
command -v hdiutil >/dev/null 2>&1 || die "找不到 hdiutil"

info "版本 $VERSION / 安装器 $INSTALLER_VERSION / 架构 $ARCH"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP_RES" "$STAGE" "$DIST"

# ---------------------------------------------------------------- 1. 服务端

info "编译服务端（$ARCH, macOS $MIN_MACOS+）"
swiftc -O -suppress-warnings \
    -module-cache-path "$SCRIPT_DIR/.cache" \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    mac-src/main.swift \
    -o "$APP_RES/BLEUnlockCmd" \
    || die "服务端编译失败"
chmod 755 "$APP_RES/BLEUnlockCmd"
# 预签名：安装器会连同签名一起复制过去，这样辅助功能权限在安装后立即绑定到
# 稳定的签名标识上。标识必须与安装器写入 Info.plist 的 CFBundleIdentifier 一致。
codesign --force --sign - --identifier "jp.sone.bleunlockcmd" \
    "$APP_RES/BLEUnlockCmd" >/dev/null 2>&1 \
    && ok "服务端已预签名" || warn "服务端签名失败（安装时仍会重签）"
ok "服务端：$(file -b "$APP_RES/BLEUnlockCmd" | cut -d, -f1)"

# ---------------------------------------------------------------- 2. 安装器界面

info "生成版本信息"
cat > "$BUILD/BuildInfo.swift" <<SWIFT
// 由 build-installer.sh 生成，请勿手工修改
enum BuildInfo {
    static let serviceVersion = "$VERSION"
    static let installerVersion = "$INSTALLER_VERSION"
}
SWIFT

info "编译安装器界面"
swiftc -O -suppress-warnings \
    -module-cache-path "$SCRIPT_DIR/.cache" \
    -target "${ARCH}-apple-macos${MIN_MACOS}" \
    "$BUILD/BuildInfo.swift" \
    installer-src/app/Installer.swift \
    installer-src/app/AppDelegate.swift \
    installer-src/app/main.swift \
    -o "$APP_BIN" \
    || die "安装器编译失败"
chmod 755 "$APP_BIN"
ok "安装器界面已编译"

# ---------------------------------------------------------------- 3. App 外壳

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BLEUnlockInstaller</string>
    <key>CFBundleIdentifier</key><string>com.bleunlock.installer</string>
    <key>CFBundleName</key><string>BLEUnlock Installer</string>
    <key>CFBundleDisplayName</key><string>BLE Unlock 安装器</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST
# 注入版本号（用 python 避免 sed 的转义问题）
python3 - "$APP/Contents/Info.plist" "$INSTALLER_VERSION" <<'PY'
import sys
p, v = sys.argv[1], sys.argv[2]
s = open(p).read().replace("__VERSION__", v)
open(p, "w").write(s)
PY

printf 'APPL????' > "$APP/Contents/PkgInfo"

# 签名安装器自身（adhoc）。辅助功能权限不涉及安装器，但仍需可执行。
codesign --force --sign - --identifier "com.bleunlock.installer" "$APP" >/dev/null 2>&1 \
    && ok "安装器已签名（adhoc）" || warn "安装器签名失败（不影响功能）"

# ---------------------------------------------------------------- 4. DMG

info "制作 DMG"
cp -R "$APP" "$STAGE/"
# 放一个「应用程序」快捷方式，方便用户日后把安装器留在原处
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/使用说明.txt" <<'TXT'
BLE Unlock 安装器
=================

双击「BLEUnlock Installer」开始安装，按提示操作即可。

安装完成后可以把这个安装器删除。

如果双击后提示「无法打开，因为 Apple 无法检查其是否包含恶意软件」：
  右键点击 App → 选择「打开」→ 在弹窗中再点「打开」
（只需做一次。这是因为本项目没有 Apple 开发者签名证书，
 无法通过公证，与程序安全性无关。）
TXT

rm -f "$DMG"
hdiutil create -volname "BLE Unlock 安装器" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null 2>&1 || die "DMG 制作失败"

ok "已生成：$DMG （$(ls -lh "$DMG" | awk '{print $5}')）"

# ---------------------------------------------------------------- 5. 自检

info "自检"
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly 2>/dev/null | grep -o '/Volumes/.*' | head -1)
if [ -n "$MOUNT" ]; then
    INNER="$MOUNT/BLEUnlock Installer.app/Contents"
    [ -x "$INNER/MacOS/BLEUnlockInstaller" ] && ok "安装器可执行文件存在" || warn "安装器可执行文件缺失"
    [ -x "$INNER/Resources/BLEUnlockCmd" ] && ok "服务端二进制存在" || warn "服务端二进制缺失"
    if "$INNER/Resources/BLEUnlockCmd" --version >/dev/null 2>&1; then
        ok "服务端可运行（$("$INNER/Resources/BLEUnlockCmd" --version)）"
    else
        warn "服务端无法运行"
    fi
    # 注意：不要在这里运行安装器——它会立刻弹出安装窗口。
    # 只检查可执行位与签名即可。
    [ -x "$INNER/MacOS/BLEUnlockInstaller" ] \
        && ok "安装器有可执行权限" || warn "安装器缺少可执行权限"
    if codesign -v "$INNER/Resources/BLEUnlockCmd" >/dev/null 2>&1; then
        ok "服务端签名有效"
    else
        warn "服务端签名校验未通过"
    fi
    if codesign -v "$MOUNT/BLEUnlock Installer.app" >/dev/null 2>&1; then
        ok "安装器签名有效"
    else
        warn "安装器签名校验未通过"
    fi
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
echo "  分发给用户时提醒：首次打开需右键 → 打开（无 Apple 开发者证书，无法公证）"
echo
