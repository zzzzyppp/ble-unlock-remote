#!/bin/bash
#
# verify-protocol.sh — 验证 Mac 端与 Android 端的协议实现完全一致
#
# 做三件事：
#   1. 编译 Mac 端 Swift 二进制
#   2. 编译并运行 tools/VerifyProtocol.java，检查报文结构与 HMAC 算法
#   3. 让 Swift 端对同一条消息计算 HMAC，比对两者是否逐字节相同

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_GREEN=""; C_RED=""; C_BLUE=""
fi
info() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
die()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; exit 1; }

# --- 定位 JDK ---
JAVA_HOME_FOUND=""
for cand in "${JAVA_HOME:-}" "$DIR"/toolchain/jdk-*/Contents/Home "$DIR"/toolchain/jdk-*; do
    if [ -n "$cand" ] && [ -x "$cand/bin/javac" ]; then JAVA_HOME_FOUND="$cand"; break; fi
done
if [ -z "$JAVA_HOME_FOUND" ] && command -v javac >/dev/null 2>&1; then
    JAVA_HOME_FOUND="$(cd "$(dirname "$(command -v javac)")/.." && pwd)"
fi
[ -n "$JAVA_HOME_FOUND" ] || die "找不到 JDK"
export JAVA_HOME="$JAVA_HOME_FOUND"
info "JDK: $JAVA_HOME"

# --- 定位 SDK ---
SDK_ROOT=""
for cand in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$DIR/toolchain/android-sdk"; do
    if [ -n "$cand" ] && [ -d "$cand/platforms/android-34" ]; then SDK_ROOT="$cand"; break; fi
done
[ -n "$SDK_ROOT" ] || die "找不到 Android SDK"
info "SDK: $SDK_ROOT"

mkdir -p "$DIR/build/verify"

# --- 1. 编译 Mac 端 ---
info "编译 Mac 端 Swift 二进制"
swiftc -O -suppress-warnings \
    -module-cache-path "$DIR/.cache" \
    mac-src/main.swift -o "$DIR/build/verify/BLEUnlockCmd" \
    || die "Swift 编译失败"
ok "Mac 端编译通过"

# --- 2. 编译验证工具 ---
info "编译协议验证工具"
"$JAVA_HOME/bin/javac" -encoding UTF-8 \
    -classpath "$SDK_ROOT/platforms/android-34/android.jar" \
    -d "$DIR/build/verify" \
    tools/VerifyProtocol.java 2>&1 | grep -v '^Note:' || true
[ -f "$DIR/build/verify/VerifyProtocol.class" ] || die "验证工具编译失败"

# --- 3. 运行比对 ---
echo
"$JAVA_HOME/bin/java" -cp "$DIR/build/verify" VerifyProtocol \
    "$SDK_ROOT/platforms/android-34/android.jar" \
    "$SDK_ROOT/build-tools/34.0.0" \
    "$DIR/build/verify/BLEUnlockCmd"
RESULT=$?
echo
if [ $RESULT -eq 0 ]; then
    ok "两端协议一致，可以放心使用"
else
    die "协议不一致，请勿使用"
fi
