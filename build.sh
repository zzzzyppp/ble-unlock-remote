#!/bin/bash
#
# build.sh — 构建 BLE Unlock 的 Android APK
#
# 不需要 Gradle。直接调用 aapt2 / javac / d8 / apksigner 完成构建，
# 因此没有网络依赖，也不会有 Gradle 版本问题。
#
# 用法:
#   ./build.sh            构建 APK（输出到 dist/BLEUnlockRemote.apk）
#   ./build.sh clean      清理构建产物
#
# 环境要求（脚本会自动在 ./toolchain 下查找便携版工具链）:
#   JDK 17+        -> $JAVA_HOME 或 ./toolchain/jdk-*
#   Android SDK    -> $ANDROID_SDK_ROOT 或 ./toolchain/android-sdk
#                     需要 platforms/android-34 与 build-tools/34.0.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SRC_DIR="$SCRIPT_DIR/android-src"
OUT_DIR="$SCRIPT_DIR/build"
DIST_DIR="$SCRIPT_DIR/dist"

# ---------------------------------------------------------------- 签名密钥位置
#
# 密钥刻意放在项目目录之外，避免被误删或误提交：
#   1. 环境变量 BLEUNLOCK_KEYSTORE_DIR 指定的目录
#   2. ~/.config/ble-unlock/            （默认，推荐）
#   3. 项目目录                          （兼容早期版本，仍然可用）
#
# 密钥丢了就无法对已安装的 APK 做覆盖升级（只能卸载重装），所以请一并备份。
KEY_ALIAS="bleunlock"
KEYSTORE_DIR=""
KEYSTORE=""
KEYSTORE_PASS_FILE=""

locate_keystore() {
    local candidates=()
    [ -n "${BLEUNLOCK_KEYSTORE_DIR:-}" ] && candidates+=("$BLEUNLOCK_KEYSTORE_DIR")
    candidates+=("$HOME/.config/ble-unlock")
    candidates+=("$SCRIPT_DIR")

    local dir
    for dir in "${candidates[@]}"; do
        if [ -f "$dir/keystore.jks" ]; then
            KEYSTORE_DIR="$dir"
            KEYSTORE="$dir/keystore.jks"
            KEYSTORE_PASS_FILE="$dir/.keystore-pass"
            return 0
        fi
    done

    # 一个都没有：在首选位置新建
    KEYSTORE_DIR="${BLEUNLOCK_KEYSTORE_DIR:-$HOME/.config/ble-unlock}"
    KEYSTORE="$KEYSTORE_DIR/keystore.jks"
    KEYSTORE_PASS_FILE="$KEYSTORE_DIR/.keystore-pass"
    return 1
}

COMPILE_SDK="android-34"
# 注意：build-tools 34.0.0 自带的 d8 在转换本项目代码时会内部报错（R8 的 NPE），
# 因此优先使用 35.0.0+；脚本会自动挑选可用的最高版本。
BUILD_TOOLS_VERSION="${BUILD_TOOLS_VERSION:-}"
MIN_SDK="26"
TARGET_SDK="34"

# 版本号：每次改动功能都应递增 versionCode，否则手机上无法覆盖安装。
# 可用环境变量临时覆盖：VERSION_CODE=3 VERSION_NAME=1.2.0 ./build.sh
VERSION_CODE="${VERSION_CODE:-3}"
VERSION_NAME="${VERSION_NAME:-1.2.0}"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""
fi
info() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}!${C_RESET} $*"; }
die()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; exit 1; }

# ---------------------------------------------------------------- 定位工具链

find_java_home() {
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ]; then
        echo "$JAVA_HOME"; return 0
    fi
    local candidate
    for candidate in "$SCRIPT_DIR"/toolchain/jdk-*/Contents/Home \
                     "$SCRIPT_DIR"/toolchain/jdk-*; do
        if [ -x "$candidate/bin/javac" ]; then echo "$candidate"; return 0; fi
    done
    if command -v javac >/dev/null 2>&1; then
        echo "$(cd "$(dirname "$(command -v javac)")/.." && pwd)"; return 0
    fi
    return 1
}

find_sdk_root() {
    local candidate
    if [ -n "${ANDROID_SDK_ROOT:-}" ] && [ -d "$ANDROID_SDK_ROOT" ]; then
        echo "$ANDROID_SDK_ROOT"; return 0
    fi
    if [ -n "${ANDROID_HOME:-}" ] && [ -d "$ANDROID_HOME" ]; then
        echo "$ANDROID_HOME"; return 0
    fi
    for candidate in "$SCRIPT_DIR/toolchain/android-sdk" \
                     "$HOME/Library/Android/sdk"; do
        if [ -d "$candidate/platforms/$COMPILE_SDK" ]; then echo "$candidate"; return 0; fi
    done
    return 1
}

JAVA_HOME="$(find_java_home)" || die "找不到 JDK。请设置 JAVA_HOME，或把 JDK 放到 toolchain/ 下。"
export JAVA_HOME
SDK_ROOT="$(find_sdk_root)" || die "找不到 Android SDK。请设置 ANDROID_SDK_ROOT，或把 SDK 放到 toolchain/android-sdk。"

# 挑选 build-tools：优先 35+，其次可用的最高版本
if [ -z "$BUILD_TOOLS_VERSION" ]; then
    for candidate in 36.0.0 35.0.0 34.0.0; do
        if [ -x "$SDK_ROOT/build-tools/$candidate/aapt2" ]; then
            BUILD_TOOLS_VERSION="$candidate"
            break
        fi
    done
fi
[ -n "$BUILD_TOOLS_VERSION" ] || die "在 $SDK_ROOT/build-tools 下找不到可用的 build-tools"

BUILD_TOOLS="$SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION"
ANDROID_JAR="$SDK_ROOT/platforms/$COMPILE_SDK/android.jar"
[ -d "$BUILD_TOOLS" ] || die "缺少 build-tools ${BUILD_TOOLS_VERSION}（${BUILD_TOOLS}）"
[ -f "$ANDROID_JAR" ] || die "缺少 platform ${COMPILE_SDK}（${ANDROID_JAR}）"

AAPT2="$BUILD_TOOLS/aapt2"
D8="$BUILD_TOOLS/d8"
APKSIGNER="$BUILD_TOOLS/apksigner"
ZIPALIGN="$BUILD_TOOLS/zipalign"
for tool in "$AAPT2" "$D8" "$APKSIGNER" "$ZIPALIGN"; do
    [ -x "$tool" ] || die "缺少可执行文件 $tool"
done

# sdkmanager 需要可写的用户目录；某些环境（沙箱）下 ~/.android 不可写
export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$SCRIPT_DIR/toolchain/android-home}"
mkdir -p "$ANDROID_USER_HOME"

# 定位（或准备新建）签名密钥
if locate_keystore; then
    :
fi

if [ "${1:-}" = "clean" ]; then
    rm -rf "$OUT_DIR" "$DIST_DIR"
    ok "已清理 build/ 与 dist/"
    exit 0
fi

info "JDK:       $JAVA_HOME"
info "SDK:       $SDK_ROOT"
info "build-tools: $BUILD_TOOLS_VERSION / platform $COMPILE_SDK"
if [ -f "$KEYSTORE" ]; then
    info "签名密钥:   $KEYSTORE"
else
    info "签名密钥:   尚不存在，将在 $KEYSTORE_DIR 新建"
fi

# ---------------------------------------------------------------- 清理

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/res-compiled" "$OUT_DIR/gen" "$OUT_DIR/classes" "$OUT_DIR/dex" "$DIST_DIR"

# ---------------------------------------------------------------- 1. 资源

info "编译资源 (aapt2 compile)"
"$AAPT2" compile --dir "$SRC_DIR/res" -o "$OUT_DIR/res-compiled/res.zip"

info "链接资源并生成 R.java (aapt2 link)"
"$AAPT2" link \
    -o "$OUT_DIR/base.apk" \
    -I "$ANDROID_JAR" \
    --manifest "$SRC_DIR/AndroidManifest.xml" \
    --java "$OUT_DIR/gen" \
    --min-sdk-version "$MIN_SDK" \
    --target-sdk-version "$TARGET_SDK" \
    --version-code "$VERSION_CODE" \
    --version-name "$VERSION_NAME" \
    "$OUT_DIR/res-compiled/res.zip"

# ---------------------------------------------------------------- 2. 编译 Java

info "编译 Java 源码 (javac)"
# 只把 java/ 下与包名匹配的源码交给 javac，避免把无关文件带进来
find "$SRC_DIR/java" -name '*.java' > "$OUT_DIR/sources.txt"
find "$OUT_DIR/gen" -name '*.java' >> "$OUT_DIR/sources.txt"

"$JAVA_HOME/bin/javac" \
    -source 17 -target 17 \
    -encoding UTF-8 \
    -classpath "$ANDROID_JAR" \
    -d "$OUT_DIR/classes" \
    -nowarn \
    @"$OUT_DIR/sources.txt" 2>&1 | grep -v '^Note:' || true

if [ ! -d "$OUT_DIR/classes/com/bleunlock/remote" ]; then
    die "Java 编译失败（没有产生 class 文件）"
fi
ok "Java 编译完成"

# ---------------------------------------------------------------- 3. DEX

info "转换为 DEX (d8)"
find "$OUT_DIR/classes" -name '*.class' > "$OUT_DIR/classes.txt"
"$D8" --min-api "$MIN_SDK" --lib "$ANDROID_JAR" \
      --output "$OUT_DIR/dex" @"$OUT_DIR/classes.txt"
[ -f "$OUT_DIR/dex/classes.dex" ] || die "d8 未生成 classes.dex"
ok "已生成 classes.dex ($(du -h "$OUT_DIR/dex/classes.dex" | cut -f1))"

# ---------------------------------------------------------------- 4. 打包

info "打包 APK"
cp "$OUT_DIR/base.apk" "$OUT_DIR/unsigned.apk"
(cd "$OUT_DIR/dex" && zip -q -X "$OUT_DIR/unsigned.apk" classes.dex)

"$ZIPALIGN" -f -p 4 "$OUT_DIR/unsigned.apk" "$OUT_DIR/aligned.apk"

# ---------------------------------------------------------------- 5. 签名

if [ ! -f "$KEYSTORE" ]; then
    info "生成签名密钥 ($KEYSTORE)"
    # 固定密码：这是自用侧载包，不需要保密；保留密钥库是为了后续能覆盖安装升级
    mkdir -p "$KEYSTORE_DIR"
    chmod 700 "$KEYSTORE_DIR" 2>/dev/null || true
    if [ ! -f "$KEYSTORE_PASS_FILE" ]; then
        printf 'bleunlock' > "$KEYSTORE_PASS_FILE"
        chmod 600 "$KEYSTORE_PASS_FILE"
    fi
    STORE_PASS="$(cat "$KEYSTORE_PASS_FILE")"
    "$JAVA_HOME/bin/keytool" -genkeypair \
        -keystore "$KEYSTORE" \
        -alias "$KEY_ALIAS" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass "$STORE_PASS" -keypass "$STORE_PASS" \
        -dname "CN=BLE Unlock, OU=Self-signed, O=BLEUnlock, L=, S=, C=" \
        >/dev/null 2>&1 || die "生成密钥库失败"
    chmod 600 "$KEYSTORE" 2>/dev/null || true
    echo
    warn "已在 $KEYSTORE_DIR 新建签名密钥"
    warn "请务必备份该目录：密钥丢失后无法对已安装的 APK 做覆盖升级。"
    echo
fi

[ -f "$KEYSTORE_PASS_FILE" ] || die "缺少密钥库口令文件：$KEYSTORE_PASS_FILE"
STORE_PASS="$(cat "$KEYSTORE_PASS_FILE")"
info "签名 APK (apksigner)"
"$APKSIGNER" sign \
    --ks "$KEYSTORE" \
    --ks-key-alias "$KEY_ALIAS" \
    --ks-pass "pass:$STORE_PASS" \
    --key-pass "pass:$STORE_PASS" \
    --v1-signing-enabled true \
    --v2-signing-enabled true \
    --v4-signing-enabled false \
    --out "$DIST_DIR/BLEUnlockRemote.apk" \
    "$OUT_DIR/aligned.apk"

info "校验签名"
"$APKSIGNER" verify --print-certs "$DIST_DIR/BLEUnlockRemote.apk" | head -6

# ---------------------------------------------------------------- 6. 结果

APK="$DIST_DIR/BLEUnlockRemote.apk"
SIZE="$(ls -lh "$APK" | awk '{print $5}')"
echo
ok "构建完成：$APK （${SIZE}）"
echo
echo "  安装到手机（需开启 USB 调试）:"
echo "      adb install -r \"$APK\""
echo
echo "  或者把 APK 传到手机，用文件管理器点击安装"
echo "  （需要在系统设置里允许「安装未知来源应用」）"
echo
