#!/bin/bash
#
# mac-ble-unlock.sh — 在 Mac 上安装/运行蓝牙解锁服务
#
# 用法:
#   ./mac-ble-unlock.sh install      安装（编译 + 配置 + 注册开机自启）
#   ./mac-ble-unlock.sh token        显示配对令牌（在手机 App 里填写）
#   ./mac-ble-unlock.sh set-password 把登录密码存入钥匙串
#   ./mac-ble-unlock.sh accessibility 申请「辅助功能」权限
#   ./mac-ble-unlock.sh start        启动服务
#   ./mac-ble-unlock.sh stop         停止服务
#   ./mac-ble-unlock.sh restart      重启服务
#   ./mac-ble-unlock.sh status       查看运行状态
#   ./mac-ble-unlock.sh log          实时查看日志
#   ./mac-ble-unlock.sh check        自检（权限 / 密码 / 锁屏状态）
#   ./mac-ble-unlock.sh uninstall    卸载
#
# 说明: 解锁方式与开源项目 BLEUnlock 相同 —— 读取钥匙串中的登录密码，
#       通过 CGEvent 合成键盘输入到锁屏界面。因此必须授予「辅助功能」权限。

set -uo pipefail

# ---------------------------------------------------------------- 基本路径

APP_SUPPORT="$HOME/Library/Application Support/BLEUnlockCmd"
APP_BUNDLE="$APP_SUPPORT/BLEUnlockCmd.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/BLEUnlockCmd"
CONFIG_FILE="$APP_SUPPORT/config.json"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/jp.sone.bleunlockcmd.plist"
LOG_FILE="$APP_SUPPORT/ble-unlock.log"
KEYCHAIN_SERVICE="ble-unlock-cmd"
SERVICE_LABEL="jp.sone.bleunlockcmd"

# 脚本自身所在目录（用于定位同目录下的 Swift 源码）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
    C_RESET=""; C_BOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}!${C_RESET} $*"; }
fail()  { printf '%s\n' "${C_RED}✗${C_RESET} $*" >&2; }

die() { fail "$*"; exit 1; }

# ---------------------------------------------------------------- Swift 源码

# 优先使用同目录的 main.swift（开发场景），否则用本脚本内嵌的副本（自包含场景）
swift_source_path() {
    if [ -f "$SCRIPT_DIR/mac-src/main.swift" ]; then
        echo "$SCRIPT_DIR/mac-src/main.swift"
    elif [ -f "$SCRIPT_DIR/main.swift" ]; then
        echo "$SCRIPT_DIR/main.swift"
    else
        echo ""
    fi
}

extract_embedded_source() {
    local target="$1"
    awk '/^__SWIFT_SOURCE_BELOW__$/{flag=1;next}/^__SWIFT_SOURCE_END__$/{flag=0}flag' \
        "${BASH_SOURCE[0]}" | base64 --decode > "$target" 2>/dev/null
    [ -s "$target" ]
}

# ---------------------------------------------------------------- 权限检查

need_macos() {
    [ "$(uname -s)" = "Darwin" ] || die "这个脚本只能在 macOS 上运行。"
}

check_swiftc() {
    if ! command -v swiftc >/dev/null 2>&1; then
        fail "找不到 swiftc 编译器。"
        echo "  请安装 Xcode 命令行工具：xcode-select --install"
        exit 1
    fi
}

have_accessibility() {
    # 用一个极小的探测程序判断是否已获得辅助功能权限
    local probe="$APP_SUPPORT/.axprobe"
    local probe_src="$APP_SUPPORT/.axprobe.swift"
    if [ ! -x "$probe" ] || [ ! -f "$probe_src" ] || [ "$probe_src" -nt "$probe" ]; then
        cat > "$probe_src" <<'PROBE'
import ApplicationServices
let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
let trusted = AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
exit(trusted ? 0 : 1)
PROBE
        swiftc -O "$probe_src" -o "$probe" >/dev/null 2>&1 || return 1
    fi
    "$probe" >/dev/null 2>&1
}

# ---------------------------------------------------------------- 编译与安装

compile_binary() {
    need_macos
    check_swiftc
    mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
    chmod 700 "$APP_SUPPORT"

    local src
    src="$(swift_source_path)"
    local tmp_src="$APP_SUPPORT/.main.swift"

    if [ -n "$src" ]; then
        info "使用源码：$src"
        cp "$src" "$tmp_src"
    else
        info "从脚本中提取内嵌源码"
        if ! extract_embedded_source "$tmp_src"; then
            fail "无法提取内嵌的 Swift 源码，且同目录下没有 main.swift。"
            rm -f "$tmp_src"
            exit 1
        fi
    fi

    info "正在编译（首次编译约需 10-30 秒）…"
    mkdir -p "$APP_SUPPORT/.modcache"
    if ! swiftc -O -suppress-warnings \
            -module-cache-path "$APP_SUPPORT/.modcache" \
            "$tmp_src" -o "$APP_BIN" 2>"$APP_SUPPORT/.build.log"; then
        fail "编译失败："
        cat "$APP_SUPPORT/.build.log" >&2
        rm -f "$tmp_src"
        exit 1
    fi
    rm -f "$tmp_src"
    chmod 755 "$APP_BIN"

    # Info.plist：蓝牙权限说明是 macOS 弹出授权框的前提
    cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BLEUnlockCmd</string>
    <key>CFBundleIdentifier</key>
    <string>jp.sone.bleunlockcmd</string>
    <key>CFBundleName</key>
    <string>BLEUnlockCmd</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>BLEUnlockCmd 需要通过蓝牙接收手机发来的解锁指令。</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>BLEUnlockCmd 需要通过蓝牙接收手机发来的解锁指令。</string>
</dict>
</plist>
PLIST

    # 临时签名：辅助功能权限是按签名绑定的，未签名的话每次重编译都要重新授权
    codesign --force --sign - --identifier "jp.sone.bleunlockcmd" \
        "$APP_BUNDLE" >/dev/null 2>&1 && \
        ok "已完成临时签名" || warn "签名失败（不影响使用，但权限可能需要重新授予）"

    ok "编译完成：$APP_BIN"
}

generate_key() {
    if [ -f "$CONFIG_FILE" ]; then
        return 0
    fi
    local key
    key="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    local device_name
    device_name="$(scutil --get ComputerName 2>/dev/null || hostname -s)"
    cat > "$CONFIG_FILE" <<JSON
{
  "deviceName" : "BLEUnlock-${device_name}",
  "hmacKey" : "${key}",
  "keychainAccount" : "$(whoami)"
}
JSON
    chmod 600 "$CONFIG_FILE"
    ok "已生成配对密钥"
}

store_password() {
    local account
    account="$(whoami)"
    local pw=""
    local pw2=""

    if [ -t 0 ]; then
        printf '%s' "请输入你的 Mac 登录密码（输入不会显示）: "
        read -rs pw
        printf '\n%s' "再输入一次确认: "
        read -rs pw2
        printf '\n'
        if [ "$pw" != "$pw2" ]; then
            die "两次输入不一致。"
        fi
    else
        # 非交互场景：从标准输入读取一行
        IFS= read -r pw || true
        if [ -z "$pw" ]; then
            die "没有读到密码。请在终端里交互运行：$0 set-password"
        fi
    fi

    [ -n "$pw" ] || die "密码为空。"

    # -U 表示已存在则更新
    if security add-generic-password -U \
            -a "$account" -s "$KEYCHAIN_SERVICE" -l "BLEUnlockCmd" -w "$pw" 2>/dev/null; then
        ok "密码已存入钥匙串（服务名 ${KEYCHAIN_SERVICE}，账户 ${account}）"
    else
        die "写入钥匙串失败。"
    fi
    unset pw pw2
}

write_launch_agent() {
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$LAUNCH_AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SERVICE_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BIN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
</dict>
</plist>
PLIST
    ok "已写入开机自启配置：$LAUNCH_AGENT"
}

stop_service() {
    launchctl bootout "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1
    # 清理可能存在的游离进程
    pkill -f "BLEUnlockCmd.app/Contents/MacOS/BLEUnlockCmd" >/dev/null 2>&1
    sleep 0.3
}

start_service() {
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" >/dev/null 2>&1
    launchctl kickstart -k "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1
    sleep 1
}

status_service() {
    if launchctl print "gui/$(id -u)/${SERVICE_LABEL}" >/dev/null 2>&1; then
        local pid
        pid="$(launchctl print "gui/$(id -u)/${SERVICE_LABEL}" 2>/dev/null \
               | awk '/^\tpid = /{print $3}')"
        if [ -n "$pid" ]; then
            ok "服务正在运行（PID ${pid}）"
        else
            warn "服务已注册，但当前没有运行"
        fi
    else
        warn "服务未注册（未安装或已卸载）"
    fi
}

# ---------------------------------------------------------------- 子命令

cmd_install() {
    need_macos
    info "开始安装 BLEUnlockCmd"
    mkdir -p "$APP_SUPPORT"

    compile_binary
    generate_key
    write_launch_agent

    info "配置登录密码"
    store_password

    info "申请「辅助功能」权限"
    grant_accessibility

    # 启动前把访问权限先探测一次，避免首次解锁失败
    info "启动服务"
    start_service
    status_service

    echo
    info "${C_BOLD}安装完成${C_RESET}"
    echo
    echo "  配对令牌（在手机 App 中填写）:"
    echo
    echo "      ${C_GREEN}$(cmd_token_raw)${C_RESET}"
    echo
    echo "  手机 App 打开后粘贴上面的令牌，保存并连接，然后点「解锁」即可。"
    echo
    echo "  常用命令："
    echo "    $0 status     查看状态"
    echo "    $0 check      自检"
    echo "    $0 log        查看日志"
    echo
}

cmd_token_raw() {
    [ -f "$CONFIG_FILE" ] || return 1
    /usr/bin/python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || \
        sed -n 's/.*"hmacKey" *: *"\([^"]*\)".*/\1/p' "$CONFIG_FILE"
import json,sys
with open(sys.argv[1]) as f:
    print(json.load(f)["hmacKey"])
PY
}

cmd_token() {
    [ -f "$CONFIG_FILE" ] || die "尚未安装，请先运行：$0 install"
    local token
    token="$(cmd_token_raw)"
    [ -n "$token" ] || die "无法从配置文件读取令牌。"
    echo
    echo "${C_BOLD}配对令牌${C_RESET}（在手机 App 中填写）："
    echo
    echo "    ${C_GREEN}${token}${C_RESET}"
    echo
    echo "十六进制形式（同样可用）："
    echo "    $(printf '%s' "$token" | base64 --decode | xxd -p | tr -d '\n')"
    echo
}

grant_accessibility() {
    [ -x "$APP_BIN" ] || die "还没有编译好的程序，请先运行：$0 install"

    if have_accessibility; then
        ok "已获得「辅助功能」权限"
        return 0
    fi

    # 通过 LaunchAgent 启动，让系统把权限请求归属到正确的进程
    write_launch_agent
    stop_service
    start_service
    "$APP_BIN" --add-accessibility >/dev/null 2>&1 &
    sleep 1

    warn "需要你在系统设置里手动授权（这是 macOS 的强制要求，脚本无法代劳）："
    echo
    echo "    1. 打开「系统设置 → 隐私与安全性 → 辅助功能」"
    echo "    2. 找到 BLEUnlockCmd 并打开开关（找不到就点左下角 + 添加：）"
    echo "       ${APP_BIN}"
    echo
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
    printf '%s' "  授权完成后按回车继续…"
    if [ -t 0 ]; then read -r _; else echo; fi

    if have_accessibility; then
        ok "权限已确认"
    else
        warn "检测到权限仍未生效。可以稍后重试：$0 accessibility"
        warn "（有时需要重启服务：$0 restart）"
    fi
}

cmd_set_password() {
    [ -f "$CONFIG_FILE" ] || die "尚未安装，请先运行：$0 install"
    store_password
    echo "提示：如果稍后弹出钥匙串访问请求，请选择「始终允许」。"
}

cmd_start() {
    [ -x "$APP_BIN" ] || die "尚未安装，请先运行：$0 install"
    start_service
    status_service
}

cmd_stop() {
    stop_service
    ok "服务已停止"
}

cmd_restart() {
    [ -x "$APP_BIN" ] || die "尚未安装，请先运行：$0 install"
    stop_service
    start_service
    status_service
}

cmd_status() {
    echo "${C_BOLD}运行状态${C_RESET}"
    status_service
    echo
    echo "${C_BOLD}权限与配置${C_RESET}"
    if have_accessibility; then
        ok "辅助功能权限：已授权"
    else
        fail "辅助功能权限：未授权（解锁不会生效）"
    fi
    if [ -x "$APP_BIN" ]; then
        ok "程序：$APP_BIN"
    else
        fail "程序：未编译"
    fi
    if [ -f "$CONFIG_FILE" ]; then
        ok "配置文件：$CONFIG_FILE"
    else
        fail "配置文件：缺失"
    fi
    if security find-generic-password -a "$(whoami)" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
        ok "钥匙串密码：已保存"
    else
        fail "钥匙串密码：未保存"
    fi
    echo
    echo "${C_BOLD}最近日志${C_RESET}"
    if [ -f "$LOG_FILE" ]; then
        tail -n 12 "$LOG_FILE"
    else
        echo "（暂无日志）"
    fi
}

cmd_check() {
    [ -x "$APP_BIN" ] || die "尚未安装，请先运行：$0 install"
    "$APP_BIN" --check
}

cmd_log() {
    [ -f "$LOG_FILE" ] || die "还没有日志文件，服务可能尚未启动过。"
    info "实时日志（Ctrl-C 退出）"
    tail -f "$LOG_FILE"
}

cmd_uninstall() {
    echo "将删除："
    echo "  - LaunchAgent  ${LAUNCH_AGENT}"
    echo "  - 程序与配置   ${APP_SUPPORT}"
    echo "  - 钥匙串条目   ${KEYCHAIN_SERVICE}"
    printf '%s' "确认卸载？[y/N] "
    if [ -t 0 ]; then
        read -r answer
        case "$answer" in
            y|Y|yes|YES) ;;
            *) echo "已取消。"; exit 0 ;;
        esac
    fi

    stop_service
    rm -f "$LAUNCH_AGENT"
    security delete-generic-password -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1
    rm -rf "$APP_SUPPORT"
    ok "已卸载"
    echo "提醒：如果不再需要，可在「系统设置 → 隐私与安全性 → 辅助功能」中移除 BLEUnlockCmd。"
}

# ---------------------------------------------------------------- 入口

case "${1:-}" in
    install)       cmd_install ;;
    token)         cmd_token ;;
    set-password)  cmd_set_password ;;
    accessibility) grant_accessibility ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_restart ;;
    status)        cmd_status ;;
    check)         cmd_check ;;
    log)           cmd_log ;;
    uninstall)     cmd_uninstall ;;
    ""|-h|--help|help)
        # 打印文件开头的注释块作为帮助（遇到第一个非注释行即停止）
        awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
        echo
        echo "注意：'install' 需要交互输入登录密码，请在终端中运行。"
        ;;
    *)
        fail "未知命令：$1"
        echo "运行 '$0 help' 查看用法。"
        exit 1
        ;;
esac

exit 0

# ---------------------------------------------------------------- 内嵌源码
# 下面的内容是 mac-src/main.swift 的 base64 副本，由 build-mac.sh 生成。
# 没有同目录源码时，安装脚本会解出这段内容再编译。
__SWIFT_SOURCE_BELOW__
Ly8gQkxFVW5sb2NrQ21kIOKAlCBNYWMgQkxFIOino+mUgeacjeWKoeerrwovLwovLyDkvZznlKjvvJrkvZzkuLogQkxFIOWkluiuvihHQVRUIFNlcnZlcinlub/mkq3vvIzmiYvmnLogQXBwIOi/nuaOpeWQjuWGmeWFpeS4gOadoeW4piBITUFDLVNIQTI1NiDnrb7lkI3nmoQKLy8gICAgICAg5oyH5Luk77yb5qCh6aqM6YCa6L+H5YiZ6LCD55So5LiOIEJMRVVubG9jayDnm7jlkIznmoTmnLrliLboh6rliqjovpPlhaXnmbvlvZXlr4bnoIHmnaXop6PplIHlsY/luZXjgIIKLy8KLy8g57yW6K+R77yac3dpZnRjIC1PIG1haW4uc3dpZnQgLW8gQkxFVW5sb2NrQ21kCi8vIOS+nei1lu+8mkNvcmVCbHVldG9vdGggLyBDcnlwdG9LaXQgLyBDb3JlR3JhcGhpY3MgLyBJT0tpdO+8iOWFqOmDqOS4uuezu+e7n+ahhuaetu+8iQoKaW1wb3J0IEZvdW5kYXRpb24KaW1wb3J0IENvcmVCbHVldG9vdGgKaW1wb3J0IENyeXB0b0tpdAppbXBvcnQgQ29yZUdyYXBoaWNzCmltcG9ydCBEYXJ3aW4KaW1wb3J0IElPS2l0LnB3cl9tZ3QKaW1wb3J0IEFwcGxpY2F0aW9uU2VydmljZXMKCi8vIE1BUks6IC0g5Y2P6K6u5bi46YeP77yI5b+F6aG75LiOIEFuZHJvaWQg56uv5LiA6Ie077yJCgpsZXQga1NlcnZpY2VVVUlEICAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAxLTRBMDAtODAwMC0wMDgwNUY5QjAwMDEiKQpsZXQga0NoYXJDb21tYW5kVVVJRCAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAyLTRBMDAtODAwMC0wMDgwNUY5QjAwMDIiKQpsZXQga0NoYXJTdGF0dXNVVUlEICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAzLTRBMDAtODAwMC0wMDgwNUY5QjAwMDMiKQpsZXQga0NoYXJJbmZvVVVJRCAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDA0LTRBMDAtODAwMC0wMDgwNUY5QjAwMDQiKQoKbGV0IGtNYWdpYzogW1VJbnQ4XSA9IFsweDQyLCAweDU1XSAgICAgICAgICAvLyAiQlUiCmxldCBrVmVyc2lvbjogVUludDggPSAweDAxCmxldCBrQ21kVW5sb2NrOiBVSW50OCA9IDB4MDEKbGV0IGtDbWRMb2NrOiBVSW50OCA9IDB4MDIKbGV0IGtDbWRQaW5nOiBVSW50OCA9IDB4MDMKCmxldCBrUGFja2V0TGVuICA9IDYyICAgICAgICAgICAgICAgICAgICAgICAgLy8gMiBtYWdpYyArIDEgdmVyICsgMSBjbWQgKyA4IHRzICsgMTYgbm9uY2UgKyAzMiBobWFjCmxldCBrSG1hY09mZnNldCA9IDMwICAgICAgICAgICAgICAgICAgICAgICAgLy8gSE1BQyDopobnm5bliY0gMzAg5a2X6IqCCgpsZXQga1RpbWVzdGFtcFNrZXc6IEludDY0ID0gMTIwICAgICAgICAgICAgIC8vIOWFgeiuuOeahOaXtumSn+WBj+W3ru+8iOenku+8iQpsZXQga05vbmNlQ2FjaGVMaW1pdCA9IDUxMgoKLy8gTUFSSzogLSDov5DooYznjq/looPot6/lvoQKLy8KLy8g6buY6K6k5L2/55SoIH4vTGlicmFyeS9BcHBsaWNhdGlvbiBTdXBwb3J0L0JMRVVubG9ja0NtZOOAggovLyDnjq/looPlj5jph48gQkxFVU5MT0NLX0FQUF9TVVBQT1JUIOWPr+imhuebluivpeebruW9le+8iOa1i+ivlS/mspnnrrHnjq/looPnlKjvvInjgIIKCmxldCBrQXBwU3VwcG9ydDogU3RyaW5nID0gewogICAgaWYgbGV0IG92ZXJyaWRlID0gUHJvY2Vzc0luZm8ucHJvY2Vzc0luZm8uZW52aXJvbm1lbnRbIkJMRVVOTE9DS19BUFBfU1VQUE9SVCJdLAogICAgICAgIW92ZXJyaWRlLmlzRW1wdHkgewogICAgICAgIHJldHVybiBvdmVycmlkZQogICAgfQogICAgcmV0dXJuICgifi9MaWJyYXJ5L0FwcGxpY2F0aW9uIFN1cHBvcnQvQkxFVW5sb2NrQ21kIiBhcyBOU1N0cmluZykuZXhwYW5kaW5nVGlsZGVJblBhdGgKfSgpCmxldCBrQ29uZmlnUGF0aCA9IGtBcHBTdXBwb3J0ICsgIi9jb25maWcuanNvbiIKbGV0IGtMb2dQYXRoICAgID0ga0FwcFN1cHBvcnQgKyAiL2JsZS11bmxvY2subG9nIgpsZXQga0tleWNoYWluU2VydmljZSA9ICJibGUtdW5sb2NrLWNtZCIKCi8vLyDml6Xlv5fmlofku7bmmK/lkKblj6/nlKjvvIjnm67lvZXkuI3lj6/lhpnml7bpgIDljJbkuLrlj6rovpPlh7rliLAgc3RkZXJy77yJCmxldCBrTG9nRmlsZVdyaXRhYmxlOiBCb29sID0gewogICAgRmlsZU1hbmFnZXIuZGVmYXVsdC5jcmVhdGVGaWxlKGF0UGF0aDoga0xvZ1BhdGgsIGNvbnRlbnRzOiBuaWwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYXR0cmlidXRlczogWy5wb3NpeFBlcm1pc3Npb25zOiAwbzYwMF0pCiAgICByZXR1cm4gRmlsZU1hbmFnZXIuZGVmYXVsdC5pc1dyaXRhYmxlRmlsZShhdFBhdGg6IGtMb2dQYXRoKQp9KCkKCi8vIE1BUks6IC0g5pel5b+XCgpsZXQgbG9nRm9ybWF0dGVyOiBEYXRlRm9ybWF0dGVyID0gewogICAgbGV0IGYgPSBEYXRlRm9ybWF0dGVyKCkKICAgIGYuZGF0ZUZvcm1hdCA9ICJ5eXl5LU1NLWRkIEhIOm1tOnNzIgogICAgcmV0dXJuIGYKfSgpCgpmdW5jIGxvZyhfIG1lc3NhZ2U6IFN0cmluZykgewogICAgbGV0IGxpbmUgPSAiW1wobG9nRm9ybWF0dGVyLnN0cmluZyhmcm9tOiBEYXRlKCkpKV0gXChtZXNzYWdlKVxuIgogICAgRmlsZUhhbmRsZS5zdGFuZGFyZEVycm9yLndyaXRlKGxpbmUuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgIGlmIGtMb2dGaWxlV3JpdGFibGUsIGxldCBoYW5kbGUgPSBGaWxlSGFuZGxlKGZvcldyaXRpbmdBdFBhdGg6IGtMb2dQYXRoKSB7CiAgICAgICAgaGFuZGxlLnNlZWtUb0VuZE9mRmlsZSgpCiAgICAgICAgaGFuZGxlLndyaXRlKGxpbmUuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgICAgICB0cnk/IGhhbmRsZS5jbG9zZSgpCiAgICB9Cn0KCi8vIE1BUks6IC0g6YWN572uCgpzdHJ1Y3QgQ29uZmlnOiBDb2RhYmxlIHsKICAgIHZhciBobWFjS2V5OiBTdHJpbmcgICAgICAgICAgLy8gYmFzZTY0IOe8lueggeeahCAzMiDlrZfoioLpooTlhbHkuqvlr4bpkqUKICAgIHZhciBrZXljaGFpbkFjY291bnQ6IFN0cmluZyAgLy8g55m75b2V5a+G56CB5omA5Zyo55qE6ZKl5YyZ5Liy6LSm5oi35ZCNCiAgICB2YXIgZGV2aWNlTmFtZTogU3RyaW5nICAgICAgIC8vIOW5v+aSreWHuuWOu+eahOiuvuWkh+WQjQp9CgpmdW5jIGxvYWRDb25maWcoKSAtPiBDb25maWc/IHsKICAgIGd1YXJkIGxldCBkYXRhID0gRmlsZU1hbmFnZXIuZGVmYXVsdC5jb250ZW50cyhhdFBhdGg6IGtDb25maWdQYXRoKSBlbHNlIHsgcmV0dXJuIG5pbCB9CiAgICByZXR1cm4gdHJ5PyBKU09ORGVjb2RlcigpLmRlY29kZShDb25maWcuc2VsZiwgZnJvbTogZGF0YSkKfQoKZnVuYyBlbnN1cmVTdXBwb3J0RGlyZWN0b3J5KCkgewogICAgdHJ5PyBGaWxlTWFuYWdlci5kZWZhdWx0LmNyZWF0ZURpcmVjdG9yeShhdFBhdGg6IGtBcHBTdXBwb3J0LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB3aXRoSW50ZXJtZWRpYXRlRGlyZWN0b3JpZXM6IHRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGF0dHJpYnV0ZXM6IFsucG9zaXhQZXJtaXNzaW9uczogMG83MDBdKQp9CgovLyBNQVJLOiAtIOWvhueggeivu+WPlu+8iGtleWNoYWlu77yJCgpmdW5jIGZldGNoUGFzc3dvcmQoYWNjb3VudDogU3RyaW5nKSAtPiBTdHJpbmc/IHsKICAgIGxldCBwcm9jZXNzID0gUHJvY2VzcygpCiAgICBwcm9jZXNzLmV4ZWN1dGFibGVVUkwgPSBVUkwoZmlsZVVSTFdpdGhQYXRoOiAiL3Vzci9iaW4vc2VjdXJpdHkiKQogICAgcHJvY2Vzcy5hcmd1bWVudHMgPSBbImZpbmQtZ2VuZXJpYy1wYXNzd29yZCIsCiAgICAgICAgICAgICAgICAgICAgICAgICAiLWEiLCBhY2NvdW50LAogICAgICAgICAgICAgICAgICAgICAgICAgIi1zIiwga0tleWNoYWluU2VydmljZSwKICAgICAgICAgICAgICAgICAgICAgICAgICItdyJdCiAgICBsZXQgcGlwZSA9IFBpcGUoKQogICAgcHJvY2Vzcy5zdGFuZGFyZE91dHB1dCA9IHBpcGUKICAgIHByb2Nlc3Muc3RhbmRhcmRFcnJvciA9IEZpbGVIYW5kbGUubnVsbERldmljZQogICAgZG8gewogICAgICAgIHRyeSBwcm9jZXNzLnJ1bigpCiAgICB9IGNhdGNoIHsKICAgICAgICBsb2coIuaXoOazleaJp+ihjCBzZWN1cml0eSDlkb3ku6Q6IFwoZXJyb3IpIikKICAgICAgICByZXR1cm4gbmlsCiAgICB9CiAgICBsZXQgZGF0YSA9IHBpcGUuZmlsZUhhbmRsZUZvclJlYWRpbmcucmVhZERhdGFUb0VuZE9mRmlsZSgpCiAgICBwcm9jZXNzLndhaXRVbnRpbEV4aXQoKQogICAgZ3VhcmQgcHJvY2Vzcy50ZXJtaW5hdGlvblN0YXR1cyA9PSAwIGVsc2UgeyByZXR1cm4gbmlsIH0KICAgIHZhciBwdyA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpID8/ICIiCiAgICAvLyBzZWN1cml0eSAtdyDkvJrpmYTluKbkuIDkuKrmjaLooYwKICAgIHdoaWxlIHB3Lmhhc1N1ZmZpeCgiXG4iKSB8fCBwdy5oYXNTdWZmaXgoIlxyIikgeyBwdy5yZW1vdmVMYXN0KCkgfQogICAgcmV0dXJuIHB3LmlzRW1wdHkgPyBuaWwgOiBwdwp9CgovLyBNQVJLOiAtIOWxj+W5leeKtuaAgSAvIOaYvuekuuWZqOaOp+WItgoKZnVuYyBpc1NjcmVlbkxvY2tlZCgpIC0+IEJvb2wgewogICAgLy8g5YWs5byAIEFQSe+8mkNHU2Vzc2lvbkNvcHlDdXJyZW50RGljdGlvbmFyee+8iFF1YXJ0eiDnp4HmnInkvYbooqvlub/ms5vkvb/nlKjnmoQgc2Vzc2lvbiDlrZflhbjvvIkKICAgIGd1YXJkIGxldCBkaWN0ID0gQ0dTZXNzaW9uQ29weUN1cnJlbnREaWN0aW9uYXJ5KCkgYXM/IFtTdHJpbmc6IEFueV0gZWxzZSB7IHJldHVybiBmYWxzZSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEludCB7IHJldHVybiBsb2NrZWQgPT0gMSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEJvb2wgeyByZXR1cm4gbG9ja2VkIH0KICAgIHJldHVybiBmYWxzZQp9Cgp2YXIgZGlzcGxheUFzc2VydGlvbklEID0gSU9QTUFzc2VydGlvbklEKDApCgpmdW5jIHdha2VEaXNwbGF5KCkgewogICAgSU9QTUFzc2VydGlvbkRlY2xhcmVVc2VyQWN0aXZpdHkoIkJMRVVubG9ja0NtZCIgYXMgQ0ZTdHJpbmcsIGtJT1BNVXNlckFjdGl2ZUxvY2FsLCAmZGlzcGxheUFzc2VydGlvbklEKQp9CgpmdW5jIHNsZWVwRGlzcGxheSgpIHsKICAgIC8vIElPUmVnaXN0cnlFbnRyeUZyb21QYXRoIOmcgOimgSBDIOWtl+espuS4sui3r+W+hAogICAgbGV0IGVudHJ5ID0gSU9SZWdpc3RyeUVudHJ5RnJvbVBhdGgoa0lPTWFzdGVyUG9ydERlZmF1bHQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiSU9TZXJ2aWNlOi9JT1Jlc291cmNlcy9JT0Rpc3BsYXlXcmFuZ2xlciIpCiAgICBpZiBlbnRyeSAhPSAwIHsKICAgICAgICBJT1JlZ2lzdHJ5RW50cnlTZXRDRlByb3BlcnR5KGVudHJ5LCAiSU9SZXF1ZXN0SWRsZSIgYXMgQ0ZTdHJpbmcsIGtDRkJvb2xlYW5UcnVlKQogICAgICAgIElPT2JqZWN0UmVsZWFzZShlbnRyeSkKICAgIH0KfQoKLy8gTUFSSzogLSDlhajlsYDlvIDlhbMKCi8vLyDlronlhajmtYvor5XmqKHlvI/vvJrlrozmlbTotbDkuIDpgY0gQkxFIOaUtuWMheS4juagoemqjO+8jOS9huS4jeecn+eahOazqOWFpeWvhueggQp2YXIgZHJ5UnVuID0gZmFsc2UKCi8vIE1BUks6IC0g6ZSu55uY5LqL5Lu25rOo5YWl77yI6Kej6ZSB55qE5qC45b+D77yJCgpmdW5jIGZha2VLZXlTdHJva2VzKF8gc3RyaW5nOiBTdHJpbmcpIHsKICAgIGlmIGRyeVJ1biB7CiAgICAgICAgbG9nKCJbZHJ5LXJ1bl0g5pys5bqU5rOo5YWlIFwoc3RyaW5nLmNvdW50KSDkuKrlrZfnrKbnmoTlr4bnoIHlubblm57ovabvvIzlt7Lot7Pov4ciKQogICAgICAgIHJldHVybgogICAgfQogICAgZ3VhcmQgbGV0IHNvdXJjZSA9IENHRXZlbnRTb3VyY2Uoc3RhdGVJRDogLmhpZFN5c3RlbVN0YXRlKSBlbHNlIHsKICAgICAgICBsb2coIuaXoOazleWIm+W7uiBDR0V2ZW50U291cmNlIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIGxldCB1bml0cyA9IEFycmF5KHN0cmluZy51dGYxNikKICAgIGxldCBwZXJDaHVuayA9IDIwICAgLy8g5Y2V5Liq6ZSu55uY5LqL5Lu25pyA5aSa5pC65bimIDIwIOS4qiBVVEYtMTYg5a2X56ymCgogICAgdmFyIGluZGV4ID0gMAogICAgd2hpbGUgaW5kZXggPCB1bml0cy5jb3VudCB7CiAgICAgICAgbGV0IGNvdW50ID0gbWluKHBlckNodW5rLCB1bml0cy5jb3VudCAtIGluZGV4KQogICAgICAgIHZhciBidWZmZXIgPSBBcnJheSh1bml0c1tpbmRleCAuLjwgaW5kZXggKyBjb3VudF0pCgogICAgICAgIGd1YXJkIGxldCBkb3duID0gQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDQ5LCBrZXlEb3duOiB0cnVlKSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGRvd24ua2V5Ym9hcmRTZXRVbmljb2RlU3RyaW5nKHN0cmluZ0xlbmd0aDogY291bnQsIHVuaWNvZGVTdHJpbmc6ICZidWZmZXIpCiAgICAgICAgZG93bi5wb3N0KHRhcDogLmNnaGlkRXZlbnRUYXApCgogICAgICAgIENHRXZlbnQoa2V5Ym9hcmRFdmVudFNvdXJjZTogc291cmNlLCB2aXJ0dWFsS2V5OiA0OSwga2V5RG93bjogZmFsc2UpPwogICAgICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgICAgIGluZGV4ICs9IGNvdW50CiAgICB9CgogICAgLy8g5Zue6L2m6ZSu77yIdmlydHVhbEtleSA1MiA9IFJldHVybu+8iQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiB0cnVlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiBmYWxzZSk/CiAgICAgICAgLnBvc3QodGFwOiAuY2doaWRFdmVudFRhcCkKfQoKZnVuYyBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IEJvb2wgPSBmYWxzZSkgLT4gQm9vbCB7CiAgICBsZXQga2V5ID0ga0FYVHJ1c3RlZENoZWNrT3B0aW9uUHJvbXB0LnRha2VVbnJldGFpbmVkVmFsdWUoKSBhcyBTdHJpbmcKICAgIHJldHVybiBBWElzUHJvY2Vzc1RydXN0ZWRXaXRoT3B0aW9ucyhba2V5OiBwcm9tcHRdIGFzIENGRGljdGlvbmFyeSkKfQoKLy8gTUFSSzogLSDop6PplIEgLyDplIHlrpoKCnZhciB1bmxvY2tJbkZsaWdodCA9IGZhbHNlCgovLy8g6Ieq5Yqo6Kej6ZSB77ya5ZSk6YaS5bGP5bmVIC0+IOehruiupOWkhOS6jumUgeWxjyAtPiDms6jlhaXlr4bnoIEKZnVuYyBwZXJmb3JtVW5sb2NrKHJlcGx5OiBAZXNjYXBpbmcgKFN0cmluZykgLT4gVm9pZCkgewogICAgZ3VhcmQgIXVubG9ja0luRmxpZ2h0IGVsc2UgewogICAgICAgIHJlcGx5KCJCVVNZIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIC8vIGRyeS1ydW4g5LiL5LiN5qOA5p+l6L6F5Yqp5Yqf6IO95p2D6ZmQ77yM5Zug5Li65LiN5Lya55yf55qE5rOo5YWl5LqL5Lu2CiAgICBndWFyZCBkcnlSdW4gfHwgYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSBlbHNlIHsKICAgICAgICBsb2coIuino+mUgeWksei0pe+8mue8uuWwkeOAjOi+heWKqeWKn+iDveOAjeadg+mZkCIpCiAgICAgICAgcmVwbHkoIkVSUl9OT19BWCIpCiAgICAgICAgcmV0dXJuCiAgICB9CiAgICBndWFyZCBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpLCBsZXQgcGFzc3dvcmQgPSBmZXRjaFBhc3N3b3JkKGFjY291bnQ6IGNvbmZpZy5rZXljaGFpbkFjY291bnQpIGVsc2UgewogICAgICAgIGxvZygi6Kej6ZSB5aSx6LSl77ya6ZKl5YyZ5Liy5Lit6K+75LiN5Yiw5a+G56CBIikKICAgICAgICByZXBseSgiRVJSX05PX1BXIikKICAgICAgICByZXR1cm4KICAgIH0KCiAgICBpZiBkcnlSdW4gewogICAgICAgIGxvZygiW2RyeS1ydW5dIOagoemqjOmAmui/h++8jOacrOW6lOaJp+ihjOino+mUge+8iOWvhueggSBcKHBhc3N3b3JkLmNvdW50KSDlrZfnrKbvvIkiKQogICAgICAgIHJlcGx5KCJPSyIpCiAgICAgICAgcmV0dXJuCiAgICB9CgogICAgdW5sb2NrSW5GbGlnaHQgPSB0cnVlCiAgICBsb2coIuaUtuWIsOino+mUgeaMh+S7pO+8jOW8gOWni+aJp+ihjCIpCgogICAgd2FrZURpc3BsYXkoKQoKICAgIC8vIOaYvuekuuWZqOWUpOmGkuWQjumcgOimgeS4gOeCueaXtumXtOaJjeecn+ato+eCueS6ru+8jOmHjeivleWHoOi9rgogICAgdmFyIGF0dGVtcHQgPSAwCiAgICBsZXQgbWF4QXR0ZW1wdHMgPSA4CgogICAgZnVuYyBmaW5pc2gocGFzc3dvcmQ6IFN0cmluZywgYXR0ZW1wdDogSW50KSB7CiAgICAgICAgbG9nKCLlsY/luZXlt7LplIHlrprvvIzms6jlhaXlr4bnoIHvvIjnrKwgXChhdHRlbXB0KSDmrKHlsJ3or5XvvIkiKQogICAgICAgIGZha2VLZXlTdHJva2VzKHBhc3N3b3JkKQogICAgICAgIHVubG9ja0luRmxpZ2h0ID0gZmFsc2UKICAgICAgICBsb2coIuW3suazqOWFpeWvhueggeW5tuWbnui9pu+8jOino+mUgeaMh+S7pOWujOaIkCIpCiAgICAgICAgcmVwbHkoIk9LIikKICAgIH0KCiAgICBmdW5jIHRpY2soKSB7CiAgICAgICAgYXR0ZW1wdCArPSAxCiAgICAgICAgd2FrZURpc3BsYXkoKQoKICAgICAgICBpZiBpc1NjcmVlbkxvY2tlZCgpIHsKICAgICAgICAgICAgLy8g5YaN562JIDAuNHMg6K6p5a+G56CB6L6T5YWl5qGG6I635b6X54Sm54K5CiAgICAgICAgICAgIGxldCBjdXJyZW50ID0gYXR0ZW1wdAogICAgICAgICAgICBEaXNwYXRjaFF1ZXVlLm1haW4uYXN5bmNBZnRlcihkZWFkbGluZTogLm5vdygpICsgMC40KSB7CiAgICAgICAgICAgICAgICBmaW5pc2gocGFzc3dvcmQ6IHBhc3N3b3JkLCBhdHRlbXB0OiBjdXJyZW50KQogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybgogICAgICAgIH0KCiAgICAgICAgaWYgYXR0ZW1wdCA+PSBtYXhBdHRlbXB0cyB7CiAgICAgICAgICAgIHVubG9ja0luRmxpZ2h0ID0gZmFsc2UKICAgICAgICAgICAgbG9nKCLop6PplIHkuK3mraLvvJrlsY/luZXmnKrlpITkuo7plIHlrprnirbmgIHvvIjlj6/og73lt7LnlLHnlKjmiLfmiYvliqjop6PplIHvvIkiKQogICAgICAgICAgICByZXBseSgiTk9UX0xPQ0tFRCIpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIH0KICAgICAgICBEaXNwYXRjaFF1ZXVlLm1haW4uYXN5bmNBZnRlcihkZWFkbGluZTogLm5vdygpICsgMC41LCBleGVjdXRlOiB0aWNrKQogICAgfQoKICAgIHRpY2soKQp9CgpmdW5jIHBlcmZvcm1Mb2NrKHJlcGx5OiBAZXNjYXBpbmcgKFN0cmluZykgLT4gVm9pZCkgewogICAgaWYgZHJ5UnVuIHsKICAgICAgICBsb2coIltkcnktcnVuXSDmnKzlupTplIHlrprlsY/luZXvvIzlt7Lot7Pov4ciKQogICAgICAgIHJlcGx5KCJPSyIpCiAgICAgICAgcmV0dXJuCiAgICB9CiAgICBsb2coIuaUtuWIsOmUgeWumuaMh+S7pCIpCiAgICAvLyDpgJrov4fplIHlsY/np4HmnIkgQVBJIOmUgeWumu+8m+iLpeS4jeWPr+eUqOWImemAgOWbnuWxj+S/nQogICAgbGV0IGhhbmRsZSA9IGRsb3BlbigiL1N5c3RlbS9MaWJyYXJ5L1ByaXZhdGVGcmFtZXdvcmtzL2xvZ2luLmZyYW1ld29yay9sb2dpbiIsIFJUTERfTk9XKQogICAgaWYgbGV0IGhhbmRsZSA9IGhhbmRsZSwgbGV0IHN5bSA9IGRsc3ltKGhhbmRsZSwgIlNBQ0xvY2tTY3JlZW5JbW1lZGlhdGUiKSB7CiAgICAgICAgdHlwZWFsaWFzIExvY2tGbiA9IEBjb252ZW50aW9uKGMpICgpIC0+IEludDMyCiAgICAgICAgbGV0IGxvY2sgPSB1bnNhZmVCaXRDYXN0KHN5bSwgdG86IExvY2tGbi5zZWxmKQogICAgICAgIGxldCByZXN1bHQgPSBsb2NrKCkKICAgICAgICBkbGNsb3NlKGhhbmRsZSkKICAgICAgICBsb2coIlNBQ0xvY2tTY3JlZW5JbW1lZGlhdGUg6L+U5ZueIFwocmVzdWx0KSIpCiAgICAgICAgcmVwbHkocmVzdWx0ID09IDAgPyAiT0siIDogIkVSUl9MT0NLIikKICAgIH0gZWxzZSB7CiAgICAgICAgbG9nKCJsb2dpbi5mcmFtZXdvcmsg5LiN5Y+v55So77yM5pS555So5bGP5L+d6ZSB5a6aIikKICAgICAgICBQcm9jZXNzLmxhdW5jaGVkUHJvY2VzcyhsYXVuY2hQYXRoOiAiL3Vzci9iaW4vb3BlbiIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYXJndW1lbnRzOiBbIi1hIiwgIlNjcmVlblNhdmVyRW5naW5lIl0pCiAgICAgICAgcmVwbHkoIk9LX1NTIikKICAgIH0KICAgIHNsZWVwRGlzcGxheSgpCn0KCi8vIE1BUks6IC0g6Ziy6YeN5pS+CgpmaW5hbCBjbGFzcyBOb25jZUNhY2hlIHsKICAgIHByaXZhdGUgdmFyIHNlZW46IFtTdHJpbmc6IERhdGVdID0gWzpdCiAgICBwcml2YXRlIGxldCBsb2NrID0gTlNMb2NrKCkKCiAgICAvLy8g6L+U5ZueIHRydWUg6KGo56S66K+lIG5vbmNlIOaYr+aWsOeahO+8iOacquiiq+mHjeaUvu+8iQogICAgZnVuYyBhY2NlcHQoXyBub25jZTogRGF0YSkgLT4gQm9vbCB7CiAgICAgICAgbGV0IGtleSA9IG5vbmNlLmJhc2U2NEVuY29kZWRTdHJpbmcoKQogICAgICAgIGxvY2subG9jaygpCiAgICAgICAgZGVmZXIgeyBsb2NrLnVubG9jaygpIH0KICAgICAgICBsZXQgbm93ID0gRGF0ZSgpCiAgICAgICAgc2VlbiA9IHNlZW4uZmlsdGVyIHsgbm93LnRpbWVJbnRlcnZhbFNpbmNlKCQwLnZhbHVlKSA8IDMwMCB9CiAgICAgICAgaWYgc2VlbltrZXldICE9IG5pbCB7IHJldHVybiBmYWxzZSB9CiAgICAgICAgaWYgc2Vlbi5jb3VudCA+PSBrTm9uY2VDYWNoZUxpbWl0IHsKICAgICAgICAgICAgaWYgbGV0IG9sZGVzdCA9IHNlZW4ubWluKGJ5OiB7ICQwLnZhbHVlIDwgJDEudmFsdWUgfSk/LmtleSB7IHNlZW4ucmVtb3ZlVmFsdWUoZm9yS2V5OiBvbGRlc3QpIH0KICAgICAgICB9CiAgICAgICAgc2VlbltrZXldID0gbm93CiAgICAgICAgcmV0dXJuIHRydWUKICAgIH0KfQoKbGV0IG5vbmNlQ2FjaGUgPSBOb25jZUNhY2hlKCkKCi8vIE1BUks6IC0g5pWw5o2u5YyF5qCh6aqMCgplbnVtIFZlcmlmeVJlc3VsdCB7CiAgICBjYXNlIG9rKGNvbW1hbmQ6IFVJbnQ4KQogICAgY2FzZSBmYWlsZWQoU3RyaW5nKQp9CgpmdW5jIHZlcmlmeVBhY2tldChfIGRhdGE6IERhdGEsIGtleTogU3ltbWV0cmljS2V5KSAtPiBWZXJpZnlSZXN1bHQgewogICAgZ3VhcmQgZGF0YS5jb3VudCA+PSBrUGFja2V0TGVuIGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX0xFTiIpIH0KICAgIGxldCBieXRlcyA9IFtVSW50OF0oZGF0YSkKCiAgICBndWFyZCBieXRlc1swXSA9PSBrTWFnaWNbMF0sIGJ5dGVzWzFdID09IGtNYWdpY1sxXSBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9NQUdJQyIpIH0KICAgIGd1YXJkIGJ5dGVzWzJdID09IGtWZXJzaW9uIGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX1ZFUiIpIH0KCiAgICBsZXQgbm93ID0gSW50NjQoRGF0ZSgpLnRpbWVJbnRlcnZhbFNpbmNlMTk3MCkKICAgIHZhciB0czogSW50NjQgPSAwCiAgICBmb3IgaSBpbiAwLi48OCB7IHRzID0gKHRzIDw8IDgpIHwgSW50NjQoYnl0ZXNbNCArIGldKSB9CiAgICBndWFyZCBhYnMobm93IC0gdHMpIDw9IGtUaW1lc3RhbXBTa2V3IGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX1RJTUUiKSB9CgogICAgbGV0IG5vbmNlID0gRGF0YShieXRlc1sxMi4uPDI4XSkKICAgIGd1YXJkIG5vbmNlQ2FjaGUuYWNjZXB0KG5vbmNlKSBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9SRVBMQVkiKSB9CgogICAgbGV0IG1lc3NhZ2UgPSBEYXRhKGJ5dGVzWzAuLjxrSG1hY09mZnNldF0pCiAgICBsZXQgZXhwZWN0ZWQgPSBEYXRhKEhNQUM8U0hBMjU2Pi5hdXRoZW50aWNhdGlvbkNvZGUoZm9yOiBtZXNzYWdlLCB1c2luZzoga2V5KSkKICAgIGxldCByZWNlaXZlZCA9IERhdGEoYnl0ZXNba0htYWNPZmZzZXQuLjxrUGFja2V0TGVuXSkKICAgIC8vIOW4uOmHj+aXtumXtOavlOi+gwogICAgZ3VhcmQgZXhwZWN0ZWQuY291bnQgPT0gcmVjZWl2ZWQuY291bnQgZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfSE1BQyIpIH0KICAgIHZhciBkaWZmOiBVSW50OCA9IDAKICAgIGZvciBpIGluIDAuLjxleHBlY3RlZC5jb3VudCB7IGRpZmYgfD0gZXhwZWN0ZWRbaV0gXiByZWNlaXZlZFtpXSB9CiAgICBndWFyZCBkaWZmID09IDAgZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfSE1BQyIpIH0KCiAgICByZXR1cm4gLm9rKGNvbW1hbmQ6IGJ5dGVzWzNdKQp9CgovLyBNQVJLOiAtIEJMRSDlpJborr4KCmZpbmFsIGNsYXNzIFBlcmlwaGVyYWxTZXJ2ZXI6IE5TT2JqZWN0LCBDQlBlcmlwaGVyYWxNYW5hZ2VyRGVsZWdhdGUgewogICAgcHJpdmF0ZSB2YXIgbWFuYWdlcjogQ0JQZXJpcGhlcmFsTWFuYWdlciEKICAgIHByaXZhdGUgdmFyIGNvbW1hbmRDaGFyOiBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyEKICAgIHByaXZhdGUgdmFyIHN0YXR1c0NoYXI6IENCTXV0YWJsZUNoYXJhY3RlcmlzdGljIQogICAgcHJpdmF0ZSB2YXIga2V5OiBTeW1tZXRyaWNLZXkhCiAgICBwcml2YXRlIHZhciBkZXZpY2VOYW1lOiBTdHJpbmcgPSAiQkxFVW5sb2NrLU1hYyIKICAgIHByaXZhdGUgdmFyIGFkdmVydGlzZVRpbWVyOiBUaW1lcj8KICAgIHByaXZhdGUgdmFyIHN0YXR1c1ZhbHVlID0gIlJFQURZIgoKICAgIGZ1bmMgc3RhcnQoa2V5OiBTeW1tZXRyaWNLZXksIGRldmljZU5hbWU6IFN0cmluZykgewogICAgICAgIHNlbGYua2V5ID0ga2V5CiAgICAgICAgc2VsZi5kZXZpY2VOYW1lID0gZGV2aWNlTmFtZQogICAgICAgIG1hbmFnZXIgPSBDQlBlcmlwaGVyYWxNYW5hZ2VyKGRlbGVnYXRlOiBzZWxmLCBxdWV1ZTogbmlsKQogICAgfQoKICAgIHByaXZhdGUgZnVuYyBidWlsZFNlcnZpY2UoKSB7CiAgICAgICAgY29tbWFuZENoYXIgPSBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyh0eXBlOiBrQ2hhckNvbW1hbmRVVUlELAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcHJvcGVydGllczogWy53cml0ZSwgLndyaXRlV2l0aG91dFJlc3BvbnNlXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBuaWwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwZXJtaXNzaW9uczogWy53cml0ZWFibGVdKQoKICAgICAgICAvLyDms6jmhI/vvJrluKYgLm5vdGlmeS8ucmVhZCDnmoTnibnlvoHkuI3og73pooTnva7nvJPlrZjlgLzvvIhDb3JlQmx1ZXRvb3RoIOS8muaKmwogICAgICAgIC8vICJDaGFyYWN0ZXJpc3RpY3Mgd2l0aCBjYWNoZWQgdmFsdWVzIG11c3QgYmUgcmVhZC1vbmx5Iu+8ie+8jAogICAgICAgIC8vIOWboOatpOi/memHjCB2YWx1ZSDlv4XpobvmmK8gbmls77yM6K+75Y+W5pe25ZyoIGRpZFJlY2VpdmVSZWFkIOmHjOWKqOaAgei/lOWbnuOAggogICAgICAgIHN0YXR1c0NoYXIgPSBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyh0eXBlOiBrQ2hhclN0YXR1c1VVSUQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3BlcnRpZXM6IFsucmVhZCwgLm5vdGlmeV0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBuaWwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBlcm1pc3Npb25zOiBbLnJlYWRhYmxlXSkKCiAgICAgICAgLy8g5Y+q6K+75LiU5YC85Zu65a6a55qE54m55b6B5Y+v5Lul6aKE572u57yT5a2Y5YC877yM5a+55omL5py656uv5pu055yB5LiA5qyh5Lqk5LqSCiAgICAgICAgbGV0IGluZm8gPSAiQkxFVW5sb2NrQ21kIHYxO1woZGV2aWNlTmFtZSkiCiAgICAgICAgbGV0IGluZm9DaGFyID0gQ0JNdXRhYmxlQ2hhcmFjdGVyaXN0aWModHlwZToga0NoYXJJbmZvVVVJRCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwcm9wZXJ0aWVzOiBbLnJlYWRdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBpbmZvLmRhdGEodXNpbmc6IC51dGY4KSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwZXJtaXNzaW9uczogWy5yZWFkYWJsZV0pCgogICAgICAgIGxldCBzZXJ2aWNlID0gQ0JNdXRhYmxlU2VydmljZSh0eXBlOiBrU2VydmljZVVVSUQsIHByaW1hcnk6IHRydWUpCiAgICAgICAgc2VydmljZS5jaGFyYWN0ZXJpc3RpY3MgPSBbY29tbWFuZENoYXIsIHN0YXR1c0NoYXIsIGluZm9DaGFyXQogICAgICAgIG1hbmFnZXIuYWRkKHNlcnZpY2UpCiAgICB9CgogICAgcHJpdmF0ZSBmdW5jIHN0YXJ0QWR2ZXJ0aXNpbmcoKSB7CiAgICAgICAgZ3VhcmQgbWFuYWdlci5zdGF0ZSA9PSAucG93ZXJlZE9uIGVsc2UgeyByZXR1cm4gfQogICAgICAgIGd1YXJkICFtYW5hZ2VyLmlzQWR2ZXJ0aXNpbmcgZWxzZSB7IHJldHVybiB9CiAgICAgICAgbWFuYWdlci5zdGFydEFkdmVydGlzaW5nKFsKICAgICAgICAgICAgQ0JBZHZlcnRpc2VtZW50RGF0YVNlcnZpY2VVVUlEc0tleTogW2tTZXJ2aWNlVVVJRF0sCiAgICAgICAgICAgIENCQWR2ZXJ0aXNlbWVudERhdGFMb2NhbE5hbWVLZXk6IGRldmljZU5hbWUsCiAgICAgICAgXSkKICAgIH0KCiAgICBmdW5jIHNldFN0YXR1cyhfIHRleHQ6IFN0cmluZykgewogICAgICAgIHN0YXR1c1ZhbHVlID0gdGV4dAogICAgICAgIC8vIOazqOaEj++8muS4jeimgee7mSBzdGF0dXNDaGFyLnZhbHVlIOi1i+WAvOOAguW4piAubm90aWZ5IOeahOeJueW+geS4gOaXpuiiq+i1i+S6iOe8k+WtmOWAvO+8jAogICAgICAgIC8vIOS5i+WQjiBtYW5hZ2VyLmFkZChzZXJ2aWNlKSDkvJrmipsgIkNoYXJhY3RlcmlzdGljcyB3aXRoIGNhY2hlZCB2YWx1ZXMgbXVzdCBiZSByZWFkLW9ubHki44CCCiAgICAgICAgLy8g6K+75Y+W55SxIGRpZFJlY2VpdmVSZWFkIOWKqOaAgei/lOWbnu+8jOaOqOmAgei1sCB1cGRhdGVWYWx1ZeOAggogICAgICAgIGd1YXJkIG1hbmFnZXIuc3RhdGUgPT0gLnBvd2VyZWRPbiwgbGV0IGNoYXJhY3RlcmlzdGljID0gc3RhdHVzQ2hhciBlbHNlIHsgcmV0dXJuIH0KICAgICAgICBpZiAhbWFuYWdlci51cGRhdGVWYWx1ZSh0ZXh0LmRhdGEodXNpbmc6IC51dGY4KSEsIGZvcjogY2hhcmFjdGVyaXN0aWMsIG9uU3Vic2NyaWJlZENlbnRyYWxzOiBuaWwpIHsKICAgICAgICAgICAgLy8g6Zif5YiX5bey5ruh77yM562JIHBlcmlwaGVyYWxNYW5hZ2VySXNSZWFkeSDml7booaXlj5EKICAgICAgICAgICAgcGVuZGluZ1N0YXR1cyA9IHRleHQKICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlckRpZFVwZGF0ZVN0YXRlKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlcikgewogICAgICAgIHN3aXRjaCBwZXJpcGhlcmFsLnN0YXRlIHsKICAgICAgICBjYXNlIC5wb3dlcmVkT246CiAgICAgICAgICAgIGxvZygi6JOd54mZ5bey5bCx57uq77yM5rOo5YaMIEdBVFQg5pyN5YqhIikKICAgICAgICAgICAgYnVpbGRTZXJ2aWNlKCkKICAgICAgICAgICAgc3RhcnRBZHZlcnRpc2luZygpCiAgICAgICAgICAgIC8vIOWumuacn+mHjeaWsOW5v+aSre+8jOmBv+WFjemUgeWxjy/ns7vnu5/kvJHnnKDlkI7lub/mkq3ooqvlgZzmjokKICAgICAgICAgICAgYWR2ZXJ0aXNlVGltZXI/LmludmFsaWRhdGUoKQogICAgICAgICAgICBhZHZlcnRpc2VUaW1lciA9IFRpbWVyLnNjaGVkdWxlZFRpbWVyKHdpdGhUaW1lSW50ZXJ2YWw6IDIwLCByZXBlYXRzOiB0cnVlKSB7IFt3ZWFrIHNlbGZdIF8gaW4KICAgICAgICAgICAgICAgIHNlbGY/LnN0YXJ0QWR2ZXJ0aXNpbmcoKQogICAgICAgICAgICB9CiAgICAgICAgICAgIFJ1bkxvb3AubWFpbi5hZGQoYWR2ZXJ0aXNlVGltZXIhLCBmb3JNb2RlOiAuY29tbW9uKQogICAgICAgICAgICBzZXRTdGF0dXMoIlJFQURZIikKICAgICAgICBjYXNlIC5wb3dlcmVkT2ZmOgogICAgICAgICAgICBsb2coIuiTneeJmeW3suWFs+mXre+8jOetieW+hemHjeaWsOW8gOWQryIpCiAgICAgICAgY2FzZSAudW5hdXRob3JpemVkOgogICAgICAgICAgICBsb2coIuiTneeJmeadg+mZkOiiq+aLkue7ne+8jOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDok53niZnjgI3kuK3mjojmnYMiKQogICAgICAgIGRlZmF1bHQ6CiAgICAgICAgICAgIGJyZWFrCiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXJEaWRTdGFydEFkdmVydGlzaW5nKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwgZXJyb3I6IEVycm9yPykgewogICAgICAgIGlmIGxldCBlcnJvciA9IGVycm9yIHsKICAgICAgICAgICAgbG9nKCLlub/mkq3lpLHotKU6IFwoZXJyb3IubG9jYWxpemVkRGVzY3JpcHRpb24pIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBsb2coIuato+WcqOW5v+aSre+8jOetieW+heaJi+acuui/nuaOpe+8iOiuvuWkh+WQjSBcKGRldmljZU5hbWUp77yJIikKICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsIGRpZEFkZCBzZXJ2aWNlOiBDQlNlcnZpY2UsIGVycm9yOiBFcnJvcj8pIHsKICAgICAgICBpZiBsZXQgZXJyb3IgPSBlcnJvciB7CiAgICAgICAgICAgIGxvZygi5re75Yqg5pyN5Yqh5aSx6LSlOiBcKGVycm9yLmxvY2FsaXplZERlc2NyaXB0aW9uKSIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9nKCJHQVRUIOacjeWKoeW3suWwsee7qu+8iFNlcnZpY2UgXChrU2VydmljZVVVSUQudXVpZFN0cmluZynvvIkiKQogICAgICAgIH0KICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwgY2VudHJhbDogQ0JDZW50cmFsLCBkaWRTdWJzY3JpYmVUbyBjaGFyYWN0ZXJpc3RpYzogQ0JDaGFyYWN0ZXJpc3RpYykgewogICAgICAgIGxvZygi5omL5py65bey6K6i6ZiF54q25oCB54m55b6BOiBcKGNlbnRyYWwuaWRlbnRpZmllci51dWlkU3RyaW5nKSIpCiAgICAgICAgc2V0U3RhdHVzKCJDT05ORUNURUQiKQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXIoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLCBjZW50cmFsOiBDQkNlbnRyYWwsIGRpZFVuc3Vic2NyaWJlRnJvbSBjaGFyYWN0ZXJpc3RpYzogQ0JDaGFyYWN0ZXJpc3RpYykgewogICAgICAgIGxvZygi5omL5py65Y+W5raI6K6i6ZiF54q25oCB54m55b6BIikKICAgIH0KCiAgICBwcml2YXRlIHZhciBwZW5kaW5nU3RhdHVzOiBTdHJpbmc/CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcklzUmVhZHkodG9VcGRhdGVTdWJzY3JpYmVycyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyKSB7CiAgICAgICAgLy8g5LiK5LiA5qyhIHVwZGF0ZVZhbHVlIOWboOWPkemAgemYn+WIl+a7oeiAjOWksei0pe+8jOi/memHjOihpeWPkQogICAgICAgIGd1YXJkIGxldCB0ZXh0ID0gcGVuZGluZ1N0YXR1cywgbWFuYWdlci5zdGF0ZSA9PSAucG93ZXJlZE9uLCBsZXQgY2hhcmFjdGVyaXN0aWMgPSBzdGF0dXNDaGFyIGVsc2UgeyByZXR1cm4gfQogICAgICAgIHBlbmRpbmdTdGF0dXMgPSBuaWwKICAgICAgICBtYW5hZ2VyLnVwZGF0ZVZhbHVlKHRleHQuZGF0YSh1c2luZzogLnV0ZjgpISwgZm9yOiBjaGFyYWN0ZXJpc3RpYywgb25TdWJzY3JpYmVkQ2VudHJhbHM6IG5pbCkKICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwKICAgICAgICAgICAgICAgICAgICAgICAgICAgZGlkUmVjZWl2ZVdyaXRlIHJlcXVlc3RzOiBbQ0JBVFRSZXF1ZXN0XSkgewogICAgICAgIGZvciByZXF1ZXN0IGluIHJlcXVlc3RzIHsKICAgICAgICAgICAgZ3VhcmQgcmVxdWVzdC5jaGFyYWN0ZXJpc3RpYy51dWlkID09IGtDaGFyQ29tbWFuZFVVSUQgZWxzZSB7IGNvbnRpbnVlIH0KICAgICAgICAgICAgbGV0IGRhdGEgPSByZXF1ZXN0LnZhbHVlID8/IERhdGEoKQogICAgICAgICAgICBsb2coIuaUtuWIsOWGmeWFpSBcKGRhdGEuY291bnQpIOWtl+iKgiIpCgogICAgICAgICAgICAvLyDml6DorrrmoKHpqoznu5PmnpzlpoLkvZXpg73opoHlupTnrZTvvJvluKblupTnrZTlhpnkuI3lm57kvJrorqnmiYvmnLrnq6/ljaHkvY8KICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuc3VjY2VzcykKCiAgICAgICAgICAgIGxldCByZXN1bHQgPSB2ZXJpZnlQYWNrZXQoZGF0YSwga2V5OiBrZXkpCiAgICAgICAgICAgIHN3aXRjaCByZXN1bHQgewogICAgICAgICAgICBjYXNlIC5mYWlsZWQobGV0IHJlYXNvbik6CiAgICAgICAgICAgICAgICBsb2coIuagoemqjOWksei0pTogXChyZWFzb24pIikKICAgICAgICAgICAgICAgIHNldFN0YXR1cyhyZWFzb24pCgogICAgICAgICAgICBjYXNlIC5vayhsZXQgY29tbWFuZCk6CiAgICAgICAgICAgICAgICBzd2l0Y2ggY29tbWFuZCB7CiAgICAgICAgICAgICAgICBjYXNlIGtDbWRVbmxvY2s6CiAgICAgICAgICAgICAgICAgICAgc2V0U3RhdHVzKCJVTkxPQ0tJTkciKQogICAgICAgICAgICAgICAgICAgIHBlcmZvcm1VbmxvY2sgeyBzdGF0dXMgaW4KICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5zZXRTdGF0dXMoc3RhdHVzKQogICAgICAgICAgICAgICAgICAgICAgICBsb2coIuino+mUgee7k+aenDogXChzdGF0dXMpIikKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBjYXNlIGtDbWRMb2NrOgogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiTE9DS0lORyIpCiAgICAgICAgICAgICAgICAgICAgcGVyZm9ybUxvY2sgeyBzdGF0dXMgaW4KICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5zZXRTdGF0dXMoc3RhdHVzKQogICAgICAgICAgICAgICAgICAgICAgICBsb2coIumUgeWumue7k+aenDogXChzdGF0dXMpIikKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBjYXNlIGtDbWRQaW5nOgogICAgICAgICAgICAgICAgICAgIGxvZygi5pS25YiwIFBJTkciKQogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiUE9ORyIpCiAgICAgICAgICAgICAgICBkZWZhdWx0OgogICAgICAgICAgICAgICAgICAgIGxvZygi5pyq55+l5oyH5LukIDB4XChTdHJpbmcoY29tbWFuZCwgcmFkaXg6IDE2KSkiKQogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiRVJSX0NNRCIpCiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgIGRpZFJlY2VpdmVSZWFkIHJlcXVlc3Q6IENCQVRUUmVxdWVzdCkgewogICAgICAgIGlmIHJlcXVlc3QuY2hhcmFjdGVyaXN0aWMudXVpZCA9PSBrQ2hhclN0YXR1c1VVSUQgewogICAgICAgICAgICBsZXQgZGF0YSA9IHN0YXR1c1ZhbHVlLmRhdGEodXNpbmc6IC51dGY4KSEKICAgICAgICAgICAgaWYgcmVxdWVzdC5vZmZzZXQgPiBkYXRhLmNvdW50IHsKICAgICAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLmludmFsaWRPZmZzZXQpCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgfQogICAgICAgICAgICByZXF1ZXN0LnZhbHVlID0gZGF0YS5zdWJkYXRhKGluOiByZXF1ZXN0Lm9mZnNldC4uPGRhdGEuY291bnQpCiAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLnN1Y2Nlc3MpCiAgICAgICAgfSBlbHNlIGlmIHJlcXVlc3QuY2hhcmFjdGVyaXN0aWMudXVpZCA9PSBrQ2hhckluZm9VVUlEIHsKICAgICAgICAgICAgbGV0IGRhdGEgPSAiQkxFVW5sb2NrQ21kIHYxO1woZGV2aWNlTmFtZSkiLmRhdGEodXNpbmc6IC51dGY4KSEKICAgICAgICAgICAgcmVxdWVzdC52YWx1ZSA9IGRhdGEKICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuc3VjY2VzcykKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBwZXJpcGhlcmFsLnJlc3BvbmQodG86IHJlcXVlc3QsIHdpdGhSZXN1bHQ6IC5hdHRyaWJ1dGVOb3RGb3VuZCkKICAgICAgICB9CiAgICB9Cn0KCi8vIE1BUks6IC0g5YWl5Y+jCgpmdW5jIHByaW50VXNhZ2UoKSB7CiAgICBwcmludCgiIiIKICAgIEJMRVVubG9ja0NtZCDigJQg55So5omL5py66YCa6L+H6JOd54mZ6Kej6ZSB6L+Z5Y+wIE1hYwoKICAgIOeUqOazlTogQkxFVW5sb2NrQ21kIFvpgInpobldCgogICAgICAtLXByaW50LXRva2VuICAgICAgICDmiZPljbDphY3lr7nku6TniYzvvIjlnKjmiYvmnLogQXBwIOS4reWhq+WGmei/meS4quWAvO+8iQogICAgICAtLXNldC1rZXkgPGJhc2U2ND4gICDlhpnlhaXmjIflrprnmoTphY3lr7nlr4bpkqUKICAgICAgLS1kZXZpY2UtbmFtZSA85ZCNPiAgIOW5v+aSreeahOiuvuWkh+WQjQogICAgICAtLWFkZC1hY2Nlc3NpYmlsaXR5ICDmiZPlvIDjgIzovoXliqnlip/og73jgI3mjojmnYPmj5DnpLoKICAgICAgLS1jaGVjayAgICAgICAgICAgICAg6Ieq5qOA77ya5omT5Y2w5p2D6ZmQ44CB6ZKl5YyZ5Liy5LiO6YWN572u54q25oCBCiAgICAgIC0tZHJ5LXJ1biAgICAgICAgICAgIOWuieWFqOa1i+ivleaooeW8j++8mui1sOWujCBCTEUg5pS25YyF5LiO5qCh6aqM77yM5L2G5LiN55yf55qE6Kej6ZSBCiAgICAgIC0tc2hvdy10b2tlbiAgICAgICAgIOaJk+WNsOmFjeWvueS7pOeJjO+8iOacquWuieijheaXtuiHquWKqOeUn+aIkOS4gOS4quS4tOaXtuWvhumSpe+8iQogICAgICAtLXNlbGZ0ZXN0IDxoZXg+ICAgICDljY/orq7oh6rmo4DvvJrlr7nnu5nlrprnmoTljYHlha3ov5vliLbmtojmga/ovpPlh7ogSE1BQy1TSEEyNTYKICAgICAgLS12ZXJzaW9uICAgICAgICAgICAg5pi+56S654mI5pysCiAgICAiIiIpCn0KCmVuc3VyZVN1cHBvcnREaXJlY3RvcnkoKQoKbGV0IGFyZ3MgPSBBcnJheShDb21tYW5kTGluZS5hcmd1bWVudHMuZHJvcEZpcnN0KCkpCgppZiBhcmdzLmNvbnRhaW5zKCItLXZlcnNpb24iKSB7CiAgICBwcmludCgiQkxFVW5sb2NrQ21kIDEuMC4wIikKICAgIGV4aXQoMCkKfQoKLy8g5Y2P6K6u6Zet546v6Ieq5qOA77ya5LiN5L6d6LWW6JOd54mZ77yM55u05o6l6LWwIuaUtuWMhSAtPiDmoKHpqowgLT4g5omn6KGMIuWFqOa1geeoiwppZiBhcmdzLmNvbnRhaW5zKCItLXNlbGZ0ZXN0LXByb3RvY29sIikgewogICAgZHJ5UnVuID0gdHJ1ZQogICAgdmFyIGZhaWxlZCA9IDAKCiAgICBmdW5jIGV4cGVjdChfIGxhYmVsOiBTdHJpbmcsIF8gb2s6IEJvb2wsIF8gZGV0YWlsOiBTdHJpbmcgPSAiIikgewogICAgICAgIGlmIG9rIHsKICAgICAgICAgICAgcHJpbnQoIiAg4pyTIFwobGFiZWwpIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBwcmludCgiICDinJcgXChsYWJlbCkgIFwoZGV0YWlsKSIpCiAgICAgICAgICAgIGZhaWxlZCArPSAxCiAgICAgICAgfQogICAgfQoKICAgIC8vIOeUqOS4tOaXtuWvhumSpeaehOmAoOa1i+ivleWMhQogICAgdmFyIGtleUJ5dGVzID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiAzMikKICAgIGZvciBpIGluIDAuLjwzMiB7IGtleUJ5dGVzW2ldID0gVUludDgoaSkgfQogICAgbGV0IHRlc3RLZXkgPSBTeW1tZXRyaWNLZXkoZGF0YTogRGF0YShrZXlCeXRlcykpCgogICAgZnVuYyBtYWtlUGFja2V0KGNvbW1hbmQ6IFVJbnQ4LCB0aW1lc3RhbXA6IEludDY0ID0gSW50NjQoRGF0ZSgpLnRpbWVJbnRlcnZhbFNpbmNlMTk3MCksCiAgICAgICAgICAgICAgICAgICAgbm9uY2U6IERhdGE/ID0gbmlsLCB0YW1wZXI6IEJvb2wgPSBmYWxzZSkgLT4gRGF0YSB7CiAgICAgICAgdmFyIG1lc3NhZ2UgPSBEYXRhKFsweDQyLCAweDU1LCAweDAxLCBjb21tYW5kXSkKICAgICAgICB2YXIgdHMgPSBVSW50NjQoYml0UGF0dGVybjogdGltZXN0YW1wKS5iaWdFbmRpYW4KICAgICAgICB3aXRoVW5zYWZlQnl0ZXMob2Y6ICZ0cykgeyBtZXNzYWdlLmFwcGVuZChjb250ZW50c09mOiAkMCkgfQogICAgICAgIHZhciBuID0gbm9uY2UgPz8gRGF0YSgoMC4uPDE2KS5tYXAgeyBfIGluIFVJbnQ4LnJhbmRvbShpbjogMC4uLjI1NSkgfSkKICAgICAgICBpZiBuLmNvdW50ICE9IDE2IHsgbiA9IERhdGEocmVwZWF0aW5nOiAwLCBjb3VudDogMTYpIH0KICAgICAgICBtZXNzYWdlLmFwcGVuZChuKQogICAgICAgIG1lc3NhZ2UuYXBwZW5kKGNvbnRlbnRzT2Y6IFsweDAwLCAweDAwXSkKICAgICAgICB2YXIgdGFnID0gRGF0YShITUFDPFNIQTI1Nj4uYXV0aGVudGljYXRpb25Db2RlKGZvcjogbWVzc2FnZSwgdXNpbmc6IHRlc3RLZXkpKQogICAgICAgIGlmIHRhbXBlciB7IHRhZ1swXSBePSAweEZGIH0KICAgICAgICByZXR1cm4gbWVzc2FnZSArIHRhZwogICAgfQoKICAgIHByaW50KCI9PSDmiqXmlofmoKHpqowgPT0iKQoKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vayhsZXQgYyk6IGV4cGVjdCgi5ZCI5rOV6Kej6ZSB5YyF6YCa6L+H5qCh6aqMIiwgYyA9PSBrQ21kVW5sb2NrLCAi5ZG95LukPVwoYykiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLlkIjms5Xop6PplIHljIXpgJrov4fmoKHpqowiLCBmYWxzZSwgcikKICAgIH0KCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFBpbmcpLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rKGxldCBjKTogZXhwZWN0KCJQSU5HIOWMhemAmui/h+agoemqjCIsIGMgPT0ga0NtZFBpbmcsICLlkb3ku6Q9XChjKSIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIlBJTkcg5YyF6YCa6L+H5qCh6aqMIiwgZmFsc2UsIHIpCiAgICB9CgogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2ssIHRhbXBlcjogdHJ1ZSksIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi56+h5pS555qEIEhNQUMg5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLnr6HmlLnnmoQgSE1BQyDooqvmi5Lnu50iLCByID09ICJFUlJfSE1BQyIsIHIpCiAgICB9CgogICAgbGV0IHdyb25nS2V5ID0gU3ltbWV0cmljS2V5KGRhdGE6IERhdGEocmVwZWF0aW5nOiAweEFCLCBjb3VudDogMzIpKQogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2spLCBrZXk6IHdyb25nS2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLplJnor6/lr4bpkqXlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIumUmeivr+WvhumSpeiiq+aLkue7nSIsIHIgPT0gIkVSUl9ITUFDIiwgcikKICAgIH0KCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KERhdGEoWzB4NDIsIDB4NTUsIDB4MDFdKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLov4fnn63nmoTljIXlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIui/h+efreeahOWMheiiq+aLkue7nSIsIHIgPT0gIkVSUl9MRU4iLCByKQogICAgfQoKICAgIHZhciBiYWRNYWdpYyA9IG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jaykKICAgIGJhZE1hZ2ljWzBdID0gMHgwMAogICAgc3dpdGNoIHZlcmlmeVBhY2tldChiYWRNYWdpYywga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLplJnor6/prZTmlbDlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIumUmeivr+mtlOaVsOiiq+aLkue7nSIsIHIgPT0gIkVSUl9NQUdJQyIsIHIpCiAgICB9CgogICAgbGV0IHN0YWxlID0gSW50NjQoRGF0ZSgpLnRpbWVJbnRlcnZhbFNpbmNlMTk3MCkgLSA2MDAKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrLCB0aW1lc3RhbXA6IHN0YWxlKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLov4fmnJ/ml7bpl7TmiLPlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIui/h+acn+aXtumXtOaIs+iiq+aLkue7nSIsIHIgPT0gIkVSUl9USU1FIiwgcikKICAgIH0KCiAgICBwcmludCgpCiAgICBwcmludCgiPT0g6Ziy6YeN5pS+ID09IikKICAgIGxldCBmaXhlZE5vbmNlID0gRGF0YShyZXBlYXRpbmc6IDB4NUEsIGNvdW50OiAxNikKICAgIGxldCBwMSA9IG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jaywgbm9uY2U6IGZpeGVkTm9uY2UpCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KHAxLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIuWQjOS4gCBub25jZSDpppbmrKHpgJrov4ciLCB0cnVlKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLlkIzkuIAgbm9uY2Ug6aaW5qyh6YCa6L+HIiwgZmFsc2UsIHIpCiAgICB9CiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KHAxLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIuWQjOS4gCBub25jZSDph43mlL7lv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIuWQjOS4gCBub25jZSDph43mlL7ooqvmi5Lnu50iLCByID09ICJFUlJfUkVQTEFZIiwgcikKICAgIH0KCiAgICBwcmludCgpCiAgICBwcmludCgiPT0g6Kej6ZSB5rWB56iL77yIZHJ5LXJ1bu+8jOS4jeS8muecn+eahOazqOWFpeWvhuegge+8iT09IikKICAgIC8vIOmAoOS4gOS4quS4tOaXtumFjee9ru+8jOaMh+WQkeS4gOS4quS4jeWtmOWcqOeahOmSpeWMmeS4sui0puaIt++8jOmihOacn+W+l+WIsCBFUlJfTk9fUFcKICAgIGxldCB0ZW1wQ29uZmlnID0gQ29uZmlnKGhtYWNLZXk6IERhdGEoa2V5Qnl0ZXMpLmJhc2U2NEVuY29kZWRTdHJpbmcoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtleWNoYWluQWNjb3VudDogIl9fYmxldW5sb2NrX3NlbGZ0ZXN0X25vbmV4aXN0ZW50X18iLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgZGV2aWNlTmFtZTogIlNFTEZURVNUIikKICAgIGxldCBlbmMgPSBKU09ORW5jb2RlcigpCiAgICBlbmMub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuYy5lbmNvZGUodGVtcENvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKCiAgICB2YXIgdW5sb2NrUmVzdWx0ID0gIiIKICAgIGxldCBzZW0gPSBEaXNwYXRjaFNlbWFwaG9yZSh2YWx1ZTogMCkKICAgIHBlcmZvcm1VbmxvY2sgeyBzdGF0dXMgaW4KICAgICAgICB1bmxvY2tSZXN1bHQgPSBzdGF0dXMKICAgICAgICBzZW0uc2lnbmFsKCkKICAgIH0KICAgIF8gPSBzZW0ud2FpdCh0aW1lb3V0OiAubm93KCkgKyAyMCkKICAgIGV4cGVjdCgi57y65bCR6ZKl5YyZ5Liy5a+G56CB5pe26L+U5ZueIEVSUl9OT19QVyIsIHVubG9ja1Jlc3VsdCA9PSAiRVJSX05PX1BXIiwgIuWunumZhSBcKHVubG9ja1Jlc3VsdCkiKQoKICAgIHByaW50KCkKICAgIGlmIGZhaWxlZCA9PSAwIHsKICAgICAgICBwcmludCgi57uT5p6cOiDlhajpg6jpgJrov4cg4pyTIikKICAgICAgICBleGl0KDApCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLnu5Pmnpw6IFwoZmFpbGVkKSDpobnlpLHotKUg4pyXIikKICAgICAgICBleGl0KDEpCiAgICB9Cn0KCi8vIOWNj+iuruiHquajgO+8mueUqOWbuuWumua1i+ivleWvhumSpeWvuee7meWumueahOWNgeWFrei/m+WItua2iOaBr+iuoeeulyBITUFD77yM5L6b6Leo6K+t6KiA5q+U5a+55L2/55SoCmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLXNlbGZ0ZXN0IiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIGxldCBoZXhTdHJpbmcgPSBhcmdzW2lkeCArIDFdCiAgICB2YXIgbWVzc2FnZSA9IERhdGEoKQogICAgdmFyIGkgPSBoZXhTdHJpbmcuc3RhcnRJbmRleAogICAgd2hpbGUgaSA8IGhleFN0cmluZy5lbmRJbmRleCB7CiAgICAgICAgZ3VhcmQgbGV0IG5leHQgPSBoZXhTdHJpbmcuaW5kZXgoaSwgb2Zmc2V0Qnk6IDIsIGxpbWl0ZWRCeTogaGV4U3RyaW5nLmVuZEluZGV4KSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGxldCBieXRlU3RyaW5nID0gaGV4U3RyaW5nW2kuLjxuZXh0XQogICAgICAgIGd1YXJkIGxldCBieXRlID0gVUludDgoYnl0ZVN0cmluZywgcmFkaXg6IDE2KSBlbHNlIHsKICAgICAgICAgICAgRmlsZUhhbmRsZS5zdGFuZGFyZEVycm9yLndyaXRlKCLml6DmlYjnmoTljYHlha3ov5vliLbovpPlhaVcbiIuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBtZXNzYWdlLmFwcGVuZChieXRlKQogICAgICAgIGkgPSBuZXh0CiAgICB9CiAgICAvLyDkuI4gQW5kcm9pZCDnq68gVmVyaWZ5UHJvdG9jb2wuamF2YSDkvb/nlKjlrozlhajnm7jlkIznmoTmtYvor5Xlr4bpkqXvvJoweDAwLDB4MDEsLi4uLDB4MWYKICAgIHZhciBrZXlCeXRlcyA9IFtVSW50OF0oKQogICAgZm9yIG4gaW4gMC4uPDMyIHsga2V5Qnl0ZXMuYXBwZW5kKFVJbnQ4KG4pKSB9CiAgICBsZXQgdGVzdEtleSA9IFN5bW1ldHJpY0tleShkYXRhOiBEYXRhKGtleUJ5dGVzKSkKICAgIGxldCB0YWcgPSBEYXRhKEhNQUM8U0hBMjU2Pi5hdXRoZW50aWNhdGlvbkNvZGUoZm9yOiBtZXNzYWdlLCB1c2luZzogdGVzdEtleSkpCiAgICBwcmludCh0YWcubWFwIHsgU3RyaW5nKGZvcm1hdDogIiUwMngiLCAkMCkgfS5qb2luZWQoKSkKICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1wcmludC10b2tlbiIpIHsKICAgIGd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICAgICAgcHJpbnQoIuWwmuacquWIneWni+WMlumFjee9ru+8jOivt+WFiOi/kOihjOWuieijheiEmuacrOOAgiIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgcHJpbnQoY29uZmlnLmhtYWNLZXkpCiAgICBleGl0KDApCn0KCmlmIGFyZ3MuY29udGFpbnMoIi0tYWRkLWFjY2Vzc2liaWxpdHkiKSB7CiAgICBsZXQgb2sgPSBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IHRydWUpCiAgICBwcmludChvayA/ICLlt7LojrflvpfovoXliqnlip/og73mnYPpmZDjgIIiIDogIuW3suW8ueWHuuaOiOadg+ivt+axgu+8jOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDovoXliqnlip/og73jgI3kuK3li77pgIkgQkxFVW5sb2NrQ21k44CCIikKICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1jaGVjayIpIHsKICAgIGd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICAgICAgcHJpbnQoIumFjee9rjog57y65aSx77yIXChrQ29uZmlnUGF0aCnvvIkiKQogICAgICAgIGV4aXQoMSkKICAgIH0KICAgIHByaW50KCLphY3nva46IOato+W4uCIpCiAgICBwcmludCgi6K6+5aSH5ZCNOiBcKGNvbmZpZy5kZXZpY2VOYW1lKSIpCiAgICBwcmludCgi6ZKl5YyZ5Liy6LSm5oi3OiBcKGNvbmZpZy5rZXljaGFpbkFjY291bnQpIikKICAgIHByaW50KCLovoXliqnlip/og73mnYPpmZA6IFwoYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSA/ICLlt7LmjojmnYMiIDogIuacquaOiOadg++8iOino+mUgeS8muWksei0pe+8iSIpIikKICAgIGlmIGxldCBwdyA9IGZldGNoUGFzc3dvcmQoYWNjb3VudDogY29uZmlnLmtleWNoYWluQWNjb3VudCkgewogICAgICAgIHByaW50KCLnmbvlvZXlr4bnoIE6IOW3suWtmOWFpemSpeWMmeS4su+8iFwocHcuY291bnQpIOS4quWtl+espu+8iSIpCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLnmbvlvZXlr4bnoIE6IOacquaJvuWIsCIpCiAgICB9CiAgICBwcmludCgi5b2T5YmN5piv5ZCm6ZSB5bGPOiBcKGlzU2NyZWVuTG9ja2VkKCkgPyAi5pivIiA6ICLlkKYiKSIpCiAgICBleGl0KDApCn0KCi8vIC0tc2V0LWtleQppZiBsZXQgaWR4ID0gYXJncy5maXJzdEluZGV4KG9mOiAiLS1zZXQta2V5IiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIGxldCBuZXdLZXkgPSBhcmdzW2lkeCArIDFdCiAgICBndWFyZCBEYXRhKGJhc2U2NEVuY29kZWQ6IG5ld0tleSk/LmNvdW50ID09IDMyIGVsc2UgewogICAgICAgIHByaW50KCLplJnor6/vvJrlr4bpkqXlv4XpobvmmK8gMzIg5a2X6IqC55qEIGJhc2U2NCDnvJbnoIHlrZfnrKbkuLLjgIIiKQogICAgICAgIGV4aXQoMSkKICAgIH0KICAgIHZhciBjb25maWcgPSBsb2FkQ29uZmlnKCkgPz8gQ29uZmlnKGhtYWNLZXk6IG5ld0tleSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtleWNoYWluQWNjb3VudDogTlNVc2VyTmFtZSgpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZGV2aWNlTmFtZTogSG9zdC5jdXJyZW50KCkubG9jYWxpemVkTmFtZSA/PyAiTWFjIikKICAgIGNvbmZpZy5obWFjS2V5ID0gbmV3S2V5CiAgICBsZXQgZW5jb2RlciA9IEpTT05FbmNvZGVyKCkKICAgIGVuY29kZXIub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuY29kZXIuZW5jb2RlKGNvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5zZXRBdHRyaWJ1dGVzKFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdLCBvZkl0ZW1BdFBhdGg6IGtDb25maWdQYXRoKQogICAgcHJpbnQoIuW3suabtOaWsOmFjeWvueWvhumSpe+8jOivt+WcqOaJi+acuiBBcHAg5Lit5ZCM5q2l5L+u5pS544CCIikKICAgIGV4aXQoMCkKfQoKLy8gLS1zaG93LXRva2Vu77ya5omT5Y2w5b2T5YmN5a+G6ZKl77yb5pyq5a6J6KOF5pe255Sf5oiQ5LiA5Liq5Li05pe25a+G6ZKl77yI6YWN5ZCIIC0tZHJ5LXJ1biDmtYvor5XnlKjvvIkKaWYgYXJncy5jb250YWlucygiLS1zaG93LXRva2VuIikgewogICAgaWYgbGV0IGNvbmZpZyA9IGxvYWRDb25maWcoKSB7CiAgICAgICAgcHJpbnQoY29uZmlnLmhtYWNLZXkpCiAgICB9IGVsc2UgewogICAgICAgIHZhciBieXRlcyA9IFtVSW50OF0ocmVwZWF0aW5nOiAwLCBjb3VudDogMzIpCiAgICAgICAgZm9yIGkgaW4gMC4uPDMyIHsgYnl0ZXNbaV0gPSBVSW50OC5yYW5kb20oaW46IDAuLi4yNTUpIH0KICAgICAgICBwcmludChEYXRhKGJ5dGVzKS5iYXNlNjRFbmNvZGVkU3RyaW5nKCkpCiAgICB9CiAgICBleGl0KDApCn0KCmlmIGFyZ3MuY29udGFpbnMoIi0tZHJ5LXJ1biIpIHsKICAgIGRyeVJ1biA9IHRydWUKfQoKLy8g5rWL6K+V5qih5byP5LiU5rKh5pyJ5q2j5byP6YWN572u5pe277yM55So5Li05pe25a+G6ZKlICsg5Li05pe26LSm5oi377yM5pa55L6/5Zyo5pyq5a6J6KOF55qE5py65Zmo5LiK6aqM6K+BCmlmIGRyeVJ1biAmJiBsb2FkQ29uZmlnKCkgPT0gbmlsIHsKICAgIHZhciBieXRlcyA9IFtVSW50OF0ocmVwZWF0aW5nOiAwLCBjb3VudDogMzIpCiAgICBmb3IgaSBpbiAwLi48MzIgeyBieXRlc1tpXSA9IFVJbnQ4LnJhbmRvbShpbjogMC4uLjI1NSkgfQogICAgbGV0IHRlbXBDb25maWcgPSBDb25maWcoaG1hY0tleTogRGF0YShieXRlcykuYmFzZTY0RW5jb2RlZFN0cmluZygpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAga2V5Y2hhaW5BY2NvdW50OiBOU1VzZXJOYW1lKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZXZpY2VOYW1lOiAiQkxFVW5sb2NrLURSWVJVTiIpCiAgICBsZXQgZW5jb2RlciA9IEpTT05FbmNvZGVyKCkKICAgIGVuY29kZXIub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuY29kZXIuZW5jb2RlKHRlbXBDb25maWcpLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrQ29uZmlnUGF0aCkpCiAgICB0cnk/IEZpbGVNYW5hZ2VyLmRlZmF1bHQuc2V0QXR0cmlidXRlcyhbLnBvc2l4UGVybWlzc2lvbnM6IDBvNjAwXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIG9mSXRlbUF0UGF0aDoga0NvbmZpZ1BhdGgpCiAgICBsb2coImRyeS1ydW7vvJrlt7LnlJ/miJDkuLTml7bphY3nva4gXChrQ29uZmlnUGF0aCkiKQp9CgpndWFyZCBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIGVsc2UgewogICAgcHJpbnQoIumUmeivr++8muaJvuS4jeWIsOmFjee9ruaWh+S7tiBcKGtDb25maWdQYXRoKSIpCiAgICBwcmludCgi6K+35YWI6L+Q6KGMIG1hYy1ibGUtdW5sb2NrLnNoIGluc3RhbGwg5a6M5oiQ5Yid5aeL5YyW44CCIikKICAgIGV4aXQoMSkKfQoKZ3VhcmQgbGV0IGtleURhdGEgPSBEYXRhKGJhc2U2NEVuY29kZWQ6IGNvbmZpZy5obWFjS2V5KSwga2V5RGF0YS5jb3VudCA9PSAzMiBlbHNlIHsKICAgIHByaW50KCLplJnor6/vvJrphY3nva7mlofku7bkuK3nmoQgaG1hY0tleSDml6DmlYjjgIIiKQogICAgZXhpdCgxKQp9CgppZiBsZXQgaWR4ID0gYXJncy5maXJzdEluZGV4KG9mOiAiLS1kZXZpY2UtbmFtZSIpLCBpZHggKyAxIDwgYXJncy5jb3VudCB7CiAgICB2YXIgdXBkYXRlZCA9IGNvbmZpZwogICAgdXBkYXRlZC5kZXZpY2VOYW1lID0gYXJnc1tpZHggKyAxXQogICAgbGV0IGVuY29kZXIgPSBKU09ORW5jb2RlcigpCiAgICBlbmNvZGVyLm91dHB1dEZvcm1hdHRpbmcgPSBbLnByZXR0eVByaW50ZWQsIC5zb3J0ZWRLZXlzXQogICAgdHJ5PyBlbmNvZGVyLmVuY29kZSh1cGRhdGVkKS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga0NvbmZpZ1BhdGgpKQogICAgcHJpbnQoIuiuvuWkh+WQjeW3suabtOaWsOS4uiBcKHVwZGF0ZWQuZGV2aWNlTmFtZSkiKQogICAgZXhpdCgwKQp9CgpsZXQgc3ltbWV0cmljS2V5ID0gU3ltbWV0cmljS2V5KGRhdGE6IGtleURhdGEpCgppZiAhYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSB7CiAgICBsb2coIuitpuWRiu+8muWwmuacquiOt+W+l+OAjOi+heWKqeWKn+iDveOAjeadg+mZkO+8jOino+mUgeS4jeS8mueUn+aViOOAgiIpCiAgICBsb2coIuivt+i/kOihjO+8mkJMRVVubG9ja0NtZCAtLWFkZC1hY2Nlc3NpYmlsaXR5IikKfQoKbG9nKCLlkK/liqggQkxFVW5sb2NrQ21k77yM6K6+5aSH5ZCN44CMXChjb25maWcuZGV2aWNlTmFtZSnjgI0iKQoKbGV0IHNlcnZlciA9IFBlcmlwaGVyYWxTZXJ2ZXIoKQpzZXJ2ZXIuc3RhcnQoa2V5OiBzeW1tZXRyaWNLZXksIGRldmljZU5hbWU6IGNvbmZpZy5kZXZpY2VOYW1lKQoKLy8g6Ziy5q2i57O757uf56m66Zey5LyR55yg77ya5LyR55yg5Lya5YGc5o6J6JOd54mZ5bm/5pKt77yM5omL5py65bCx5YaN5Lmf6L+e5LiN5LiK5LqGCnZhciBzbGVlcEFzc2VydGlvbiA9IElPUE1Bc3NlcnRpb25JRCgwKQpsZXQgYXNzZXJ0aW9uUmVzdWx0ID0gSU9QTUFzc2VydGlvbkNyZWF0ZVdpdGhOYW1lKGtJT1BNQXNzZXJ0aW9uVHlwZU5vSWRsZVNsZWVwIGFzIENGU3RyaW5nLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSU9QTUFzc2VydGlvbkxldmVsKGtJT1BNQXNzZXJ0aW9uTGV2ZWxPbiksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiQkxFVW5sb2NrQ21kIOS/neaMgeiTneeJmeWPr+i/nuaOpSIgYXMgQ0ZTdHJpbmcsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAmc2xlZXBBc3NlcnRpb24pCmlmIGFzc2VydGlvblJlc3VsdCA9PSBrSU9SZXR1cm5TdWNjZXNzIHsKICAgIGxvZygi5bey6Zi75q2i57O757uf56m66Zey5LyR55yg77yM5Lul5L+d5oyB6JOd54mZ5Y+v6L+e5o6l77yI5pi+56S65Zmo5LuN5Lya5q2j5bi45oGv5bGP77yJIikKfSBlbHNlIHsKICAgIGxvZygi6K2m5ZGK77ya5peg5rOV5Yib5bu66Ziy5LyR55yg5pat6KiA77yM57O757uf5LyR55yg5ZCO6JOd54mZ5bCG5pat5byAIikKfQoKLy8g6L+b56iL6YCA5Ye65pe26YeK5pS+5pat6KiACmZ1bmMgY2xlYW51cCgpIHsKICAgIGlmIHNsZWVwQXNzZXJ0aW9uICE9IDAgewogICAgICAgIElPUE1Bc3NlcnRpb25SZWxlYXNlKHNsZWVwQXNzZXJ0aW9uKQogICAgICAgIHNsZWVwQXNzZXJ0aW9uID0gMAogICAgfQogICAgbG9nKCJCTEVVbmxvY2tDbWQg6YCA5Ye6IikKfQoKc2lnbmFsKFNJR0lOVCwgU0lHX0lHTikKc2lnbmFsKFNJR1RFUk0sIFNJR19JR04pCmxldCBzaWdpbnRTb3VyY2UgPSBEaXNwYXRjaFNvdXJjZS5tYWtlU2lnbmFsU291cmNlKHNpZ25hbDogU0lHSU5ULCBxdWV1ZTogLm1haW4pCnNpZ2ludFNvdXJjZS5zZXRFdmVudEhhbmRsZXIgeyBsb2coIuaUtuWIsCBTSUdJTlTvvIzpgIDlh7oiKTsgY2xlYW51cCgpOyBleGl0KDApIH0Kc2lnaW50U291cmNlLnJlc3VtZSgpCmxldCBzaWd0ZXJtU291cmNlID0gRGlzcGF0Y2hTb3VyY2UubWFrZVNpZ25hbFNvdXJjZShzaWduYWw6IFNJR1RFUk0sIHF1ZXVlOiAubWFpbikKc2lndGVybVNvdXJjZS5zZXRFdmVudEhhbmRsZXIgeyBsb2coIuaUtuWIsCBTSUdURVJN77yM6YCA5Ye6Iik7IGNsZWFudXAoKTsgZXhpdCgwKSB9CnNpZ3Rlcm1Tb3VyY2UucmVzdW1lKCkKClJ1bkxvb3AubWFpbi5ydW4oKQo=
__SWIFT_SOURCE_END__
