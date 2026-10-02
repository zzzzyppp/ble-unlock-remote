#!/bin/bash
#
# verify-multikey.sh — 验证多密钥存储与令牌解析逻辑
#
# android.jar 里的 android.util.Base64 / org.json 都是 `throw new RuntimeException("Stub!")`
# 占位实现，无法在 JVM 上直接测试。这里用 tools/testdoubles/ 下提供真实实现的替身类
# 覆盖它们，从而在电脑上验证真正的 Protocol / MacEntryStore 逻辑，不需要手机。

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

# --- 定位 SDK（仅用于取 android.jar 里的 org.json 签名参考）---
SDK_ROOT=""
for cand in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$DIR/toolchain/android-sdk"; do
    if [ -n "$cand" ] && [ -d "$cand/platforms/android-34" ]; then SDK_ROOT="$cand"; break; fi
done
[ -n "$SDK_ROOT" ] || die "找不到 Android SDK"
ANDROID_JAR="$SDK_ROOT/platforms/android-34/android.jar"

OUT="$DIR/build/verify-jvm"
rm -rf "$OUT"
mkdir -p "$OUT"

info "编译生产代码 Protocol.java + 测试替身 + 验证程序"
"$JAVA_HOME/bin/javac" -encoding UTF-8 -nowarn \
    -cp "$ANDROID_JAR" \
    -d "$OUT" \
    android-src/java/com/bleunlock/remote/Protocol.java \
    tools/testdoubles/android/util/Base64.java \
    tools/testdoubles/org/json/*.java \
    tools/VerifyMultiKey.java 2>&1 | grep -v '^注:' || true
[ -f "$OUT/VerifyMultiKey.class" ] || die "编译失败"

# --- 用 Mac 上真实生成的令牌做一次真实数据验证（如果已安装）---
REAL_TOKEN=""
CONFIG="$HOME/Library/Application Support/BLEUnlockCmd/config.json"
if [ -f "$CONFIG" ]; then
    REAL_TOKEN="$(/usr/bin/python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['hmacKey'])
" "$CONFIG" 2>/dev/null || true)"
fi

echo
# 替身类必须排在 android.jar 之前，才能覆盖其中的 Stub 实现
"$JAVA_HOME/bin/java" -cp "$OUT:$ANDROID_JAR" VerifyMultiKey "$REAL_TOKEN"
RESULT=$?
echo
if [ $RESULT -eq 0 ]; then
    ok "多密钥逻辑验证通过"
else
    die "验证失败"
fi
