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

# 读取守护进程自己报告的辅助功能权限状态。
#
# 关键：不能用 --ax-status 从本脚本去问！
# TCC 的辅助功能信任**会从父进程继承**：脚本从终端运行时继承了终端的信任，
# 于是它 fork 出来的子进程一律报告「已授权」，而真正由 launchd 启动的守护进程
# 其实并未获得授权。这正是「向导说已授权、手机却报缺少权限」的成因。
#
# 因此以守护进程自己落盘的状态为准。
#
# 返回：0=已授权  1=未授权  2=未知（守护进程尚未报告）
have_accessibility() {
    local status="$APP_SUPPORT/daemon-status.json"
    if [ ! -f "$status" ]; then
        return 2
    fi
    # 用 grep 解析，不用 sed：BSD sed 不支持 \| 交替语法（GNU 扩展），
    # 在 macOS 上会静默匹配失败。
    if grep -q '"axTrusted"[[:space:]]*:[[:space:]]*true' "$status" 2>/dev/null; then
        return 0
    elif grep -q '"axTrusted"[[:space:]]*:[[:space:]]*false' "$status" 2>/dev/null; then
        return 1
    else
        return 2
    fi
}

# 让守护进程重新评估并落盘权限状态
refresh_daemon_status() {
    mkdir -p "$APP_SUPPORT"
    printf 'refresh-ax' > "$APP_SUPPORT/refresh.request" 2>/dev/null || true
    sleep 1
}

# 程序是否已就绪（用于区分「没装」和「权限没给」）
app_ready() {
    [ -x "$APP_BIN" ]
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

    # 能力标记文件。脚本靠它判断二进制是否支持某些查询参数，
    # 而不是去猜二进制内容——Swift 编译器会合并参数字符串，
    # 直接用 grep/strings 查找是不可靠的。
    cat > "$APP_BUNDLE/Contents/Resources/capabilities" <<CAPS
name=BLEUnlockCmd
version=1.1.0
features=ax-status
CAPS

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

    # 确保服务在跑：守护进程启动后才会写出权限状态文件
    write_launch_agent
    stop_service
    start_service
    refresh_daemon_status

    have_accessibility
    local ax=$?
    if [ $ax -eq 0 ]; then
        ok "守护进程已获得「辅助功能」权限"
        return 0
    fi

    warn "需要你在系统设置里手动授权（macOS 的强制要求，脚本无法代劳）："
    echo
    echo "    1. 打开「系统设置 → 隐私与安全性 → 辅助功能」"
    echo "    2. 把下面这个文件拖进列表，或点 ＋ 选择它："
    echo
    echo "       ${APP_BIN}"
    echo
    echo "    注意：要添加的是上面这个路径，而不是「应用程序」里的 BLE Unlock。"
    echo "          两者是不同的程序；授权给 App 不会让后台服务获得权限。"
    echo
    echo "    如果列表里已有一条 BLEUnlockCmd 且开关是打开的却仍无效，"
    echo "    请先用「−」删除它，再重新添加一次。"
    echo
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null
    open -R "$APP_BIN" 2>/dev/null
    printf '%s' "  授权完成后按回车继续…"
    if [ -t 0 ]; then read -r _; else echo; fi

    refresh_daemon_status
    have_accessibility
    ax=$?
    if [ $ax -eq 0 ]; then
        ok "权限已确认生效"
    elif [ $ax -eq 2 ]; then
        warn "守护进程尚未报告状态，请确认服务在运行：$0 restart"
    else
        warn "守护进程仍未获得权限"
        warn "请确认你添加的是：${APP_BIN}"
        warn "重试：$0 accessibility"
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
    if ! app_ready; then
        fail "程序：未编译（请先运行 $0 install）"
    else
        ok "程序：$APP_BIN"
        refresh_daemon_status
        have_accessibility
        local ax=$?
        if [ $ax -eq 0 ]; then
            ok "辅助功能权限：守护进程已授权"
        elif [ $ax -eq 2 ]; then
            warn "辅助功能权限：无法判定（守护进程尚未报告）"
            echo "    请确认服务在运行：$0 restart"
        else
            fail "辅助功能权限：守护进程未授权（解锁不会生效）"
            echo "    需要授权的文件是："
            echo "      $APP_BIN"
            echo "    （不是「应用程序」里的 BLE Unlock —— 那是设置 App，"
            echo "      授权给它不会让后台服务获得权限）"
            echo "    修复：$0 accessibility"
        fi
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
Ly8gQkxFVW5sb2NrQ21kIOKAlCBNYWMgQkxFIOino+mUgeacjeWKoeerrwovLwovLyDkvZznlKjvvJrkvZzkuLogQkxFIOWkluiuvihHQVRUIFNlcnZlcinlub/mkq3vvIzmiYvmnLogQXBwIOi/nuaOpeWQjuWGmeWFpeS4gOadoeW4piBITUFDLVNIQTI1NiDnrb7lkI3nmoQKLy8gICAgICAg5oyH5Luk77yb5qCh6aqM6YCa6L+H5YiZ6LCD55So5LiOIEJMRVVubG9jayDnm7jlkIznmoTmnLrliLboh6rliqjovpPlhaXnmbvlvZXlr4bnoIHmnaXop6PplIHlsY/luZXjgIIKLy8KLy8g57yW6K+R77yac3dpZnRjIC1PIG1haW4uc3dpZnQgLW8gQkxFVW5sb2NrQ21kCi8vIOS+nei1lu+8mkNvcmVCbHVldG9vdGggLyBDcnlwdG9LaXQgLyBDb3JlR3JhcGhpY3MgLyBJT0tpdO+8iOWFqOmDqOS4uuezu+e7n+ahhuaetu+8iQoKaW1wb3J0IEZvdW5kYXRpb24KaW1wb3J0IENvcmVCbHVldG9vdGgKaW1wb3J0IENyeXB0b0tpdAppbXBvcnQgQ29yZUdyYXBoaWNzCmltcG9ydCBEYXJ3aW4KaW1wb3J0IElPS2l0LnB3cl9tZ3QKaW1wb3J0IEFwcGxpY2F0aW9uU2VydmljZXMKCi8vIE1BUks6IC0g5Y2P6K6u5bi46YeP77yI5b+F6aG75LiOIEFuZHJvaWQg56uv5LiA6Ie077yJCgpsZXQga1NlcnZpY2VVVUlEICAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAxLTRBMDAtODAwMC0wMDgwNUY5QjAwMDEiKQpsZXQga0NoYXJDb21tYW5kVVVJRCAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAyLTRBMDAtODAwMC0wMDgwNUY5QjAwMDIiKQpsZXQga0NoYXJTdGF0dXNVVUlEICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAzLTRBMDAtODAwMC0wMDgwNUY5QjAwMDMiKQpsZXQga0NoYXJJbmZvVVVJRCAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDA0LTRBMDAtODAwMC0wMDgwNUY5QjAwMDQiKQoKbGV0IGtNYWdpYzogW1VJbnQ4XSA9IFsweDQyLCAweDU1XSAgICAgICAgICAvLyAiQlUiCmxldCBrVmVyc2lvbjogVUludDggPSAweDAxCmxldCBrQ21kVW5sb2NrOiBVSW50OCA9IDB4MDEKbGV0IGtDbWRMb2NrOiBVSW50OCA9IDB4MDIKbGV0IGtDbWRQaW5nOiBVSW50OCA9IDB4MDMKCmxldCBrUGFja2V0TGVuICA9IDYyICAgICAgICAgICAgICAgICAgICAgICAgLy8gMiBtYWdpYyArIDEgdmVyICsgMSBjbWQgKyA4IHRzICsgMTYgbm9uY2UgKyAzMiBobWFjCmxldCBrSG1hY09mZnNldCA9IDMwICAgICAgICAgICAgICAgICAgICAgICAgLy8gSE1BQyDopobnm5bliY0gMzAg5a2X6IqCCgpsZXQga1RpbWVzdGFtcFNrZXc6IEludDY0ID0gMTIwICAgICAgICAgICAgIC8vIOWFgeiuuOeahOaXtumSn+WBj+W3ru+8iOenku+8iQpsZXQga05vbmNlQ2FjaGVMaW1pdCA9IDUxMgoKLy8gTUFSSzogLSDov5DooYznjq/looPot6/lvoQKLy8KLy8g6buY6K6k5L2/55SoIH4vTGlicmFyeS9BcHBsaWNhdGlvbiBTdXBwb3J0L0JMRVVubG9ja0NtZOOAggovLyDnjq/looPlj5jph48gQkxFVU5MT0NLX0FQUF9TVVBQT1JUIOWPr+imhuebluivpeebruW9le+8iOa1i+ivlS/mspnnrrHnjq/looPnlKjvvInjgIIKCmxldCBrQXBwU3VwcG9ydDogU3RyaW5nID0gewogICAgaWYgbGV0IG92ZXJyaWRlID0gUHJvY2Vzc0luZm8ucHJvY2Vzc0luZm8uZW52aXJvbm1lbnRbIkJMRVVOTE9DS19BUFBfU1VQUE9SVCJdLAogICAgICAgIW92ZXJyaWRlLmlzRW1wdHkgewogICAgICAgIHJldHVybiBvdmVycmlkZQogICAgfQogICAgcmV0dXJuICgifi9MaWJyYXJ5L0FwcGxpY2F0aW9uIFN1cHBvcnQvQkxFVW5sb2NrQ21kIiBhcyBOU1N0cmluZykuZXhwYW5kaW5nVGlsZGVJblBhdGgKfSgpCmxldCBrQ29uZmlnUGF0aCA9IGtBcHBTdXBwb3J0ICsgIi9jb25maWcuanNvbiIKbGV0IGtMb2dQYXRoICAgID0ga0FwcFN1cHBvcnQgKyAiL2JsZS11bmxvY2subG9nIgpsZXQga0tleWNoYWluU2VydmljZSA9ICJibGUtdW5sb2NrLWNtZCIKLy8vIOWuiOaKpOi/m+eoi+aKiuiHquW3seeahCBUQ0Mg5p2D6ZmQ54q25oCB5YaZ5Zyo6L+Z6YeM77yM5L6b6K6+572u5ZCR5a+86K+75Y+W44CCCi8vLwovLy8g5Li65LuA5LmI5LiN55u05o6l6Zeu6L+b56iL77yaVENDIOeahCBBWCDkv6Hku7vkvJrku47niLbov5vnqIvnu6fmib/jgILorr7nva7lkJHlr7zku44gRmluZGVyL+e7iOerrwovLy8g5ZCv5Yqo5pe25pys6Lqr5piv5Y+X5L+h5Lu755qE77yM5a6DIGZvcmsg5Ye65p2l55qE5a2Q6L+b56iL5Lmf5Lya5oql5ZGK44CM5bey5o6I5p2D44CN4oCU4oCUCi8vLyDkvYbnnJ/mraPlubLmtLvnmoTlrojmiqTov5vnqIvnlLEgbGF1bmNoZCDlkK/liqjvvIzkuI3lj5fmraTkv6Hku7vvvIzlrp7pmYXmmK/mnKrmjojmnYPjgIIKLy8vIOWboOatpOW/hemhu+iuqeWuiOaKpOi/m+eoi+iHquW3seaKiuWIpOWumue7k+aenOiQveebmOOAggpsZXQga1N0YXR1c1BhdGggPSBrQXBwU3VwcG9ydCArICIvZGFlbW9uLXN0YXR1cy5qc29uIgovLy8g5aSW6YOo6K+35rGC5Yi35paw5p2D6ZmQ54q25oCB55qE5L+h5Y+35paH5Lu277yI6K6+572u5ZCR5a+85Zyo55So5oi35o6I5p2D5ZCO5YaZ5YWl77yJCmxldCBrUmVmcmVzaFJlcXVlc3RQYXRoID0ga0FwcFN1cHBvcnQgKyAiL3JlZnJlc2gucmVxdWVzdCIKCi8vLyDml6Xlv5fmlofku7bmmK/lkKblj6/nlKjvvIjnm67lvZXkuI3lj6/lhpnml7bpgIDljJbkuLrlj6rovpPlh7rliLAgc3RkZXJy77yJCmxldCBrTG9nRmlsZVdyaXRhYmxlOiBCb29sID0gewogICAgRmlsZU1hbmFnZXIuZGVmYXVsdC5jcmVhdGVGaWxlKGF0UGF0aDoga0xvZ1BhdGgsIGNvbnRlbnRzOiBuaWwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYXR0cmlidXRlczogWy5wb3NpeFBlcm1pc3Npb25zOiAwbzYwMF0pCiAgICByZXR1cm4gRmlsZU1hbmFnZXIuZGVmYXVsdC5pc1dyaXRhYmxlRmlsZShhdFBhdGg6IGtMb2dQYXRoKQp9KCkKCi8vIE1BUks6IC0g5pel5b+XCgpsZXQgbG9nRm9ybWF0dGVyOiBEYXRlRm9ybWF0dGVyID0gewogICAgbGV0IGYgPSBEYXRlRm9ybWF0dGVyKCkKICAgIGYuZGF0ZUZvcm1hdCA9ICJ5eXl5LU1NLWRkIEhIOm1tOnNzIgogICAgcmV0dXJuIGYKfSgpCgovLy8g6K6w5b2V5a6I5oqk6L+b56iL6Ieq6Lqr55qEIFRDQyDmnYPpmZDnirbmgIHvvIzkvpvorr7nva7lkJHlr7zliKTmlq0i55yf5q2j5bmy5rS755qE6L+b56iLIuiDveWQpui+k+WFpeOAggpmdW5jIHdyaXRlRGFlbW9uU3RhdHVzKCkgewogICAgbGV0IHRydXN0ZWQgPSBhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpCiAgICBsZXQgcGF5bG9hZDogW1N0cmluZzogQW55XSA9IFsKICAgICAgICAicGlkIjogSW50KGdldHBpZCgpKSwKICAgICAgICAiYXhUcnVzdGVkIjogdHJ1c3RlZCwKICAgICAgICAidXBkYXRlZEF0IjogSVNPODYwMURhdGVGb3JtYXR0ZXIoKS5zdHJpbmcoZnJvbTogRGF0ZSgpKSwKICAgICAgICAiYnVuZGxlUGF0aCI6IEJ1bmRsZS5tYWluLmJ1bmRsZVBhdGgsCiAgICBdCiAgICBpZiBsZXQgZGF0YSA9IHRyeT8gSlNPTlNlcmlhbGl6YXRpb24uZGF0YSh3aXRoSlNPTk9iamVjdDogcGF5bG9hZCwgb3B0aW9uczogWy5wcmV0dHlQcmludGVkXSkgewogICAgICAgIHRyeT8gZGF0YS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga1N0YXR1c1BhdGgpKQogICAgICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5zZXRBdHRyaWJ1dGVzKFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIG9mSXRlbUF0UGF0aDoga1N0YXR1c1BhdGgpCiAgICB9CiAgICBsb2coIuWuiOaKpOi/m+eoi+adg+mZkOiHquajgO+8mkFYSXNQcm9jZXNzVHJ1c3RlZCA9IFwodHJ1c3RlZCkiKQogICAgaWYgIXRydXN0ZWQgewogICAgICAgIGxvZygiICDimqDvuI8g5pys6L+b56iL5peg5rOV5qih5ouf6ZSu55uY6L6T5YWl77yM6Kej6ZSB5Lya5aSx6LSl44CCIikKICAgICAgICBsb2coIiAgICAg6K+35Zyo44CM57O757uf6K6+572uIOKGkiDpmpDnp4HkuI7lronlhajmgKcg4oaSIOi+heWKqeWKn+iDveOAjeS4reWLvumAiSBCTEVVbmxvY2tDbWTvvJsiKQogICAgICAgIGxvZygiICAgICDoi6XlvIDlhbPlt7LmmK/miZPlvIDnirbmgIHvvIzor7flhYjliKDpmaTor6Xpobnlho3ph43mlrDmt7vliqDvvIjml6fmjojmnYPlj6/og73nu5HlrprliLDml6fniYjmnKzvvInjgIIiKQogICAgfQp9CgpmdW5jIGxvZyhfIG1lc3NhZ2U6IFN0cmluZykgewogICAgbGV0IGxpbmUgPSAiW1wobG9nRm9ybWF0dGVyLnN0cmluZyhmcm9tOiBEYXRlKCkpKV0gXChtZXNzYWdlKVxuIgogICAgRmlsZUhhbmRsZS5zdGFuZGFyZEVycm9yLndyaXRlKGxpbmUuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgIGlmIGtMb2dGaWxlV3JpdGFibGUsIGxldCBoYW5kbGUgPSBGaWxlSGFuZGxlKGZvcldyaXRpbmdBdFBhdGg6IGtMb2dQYXRoKSB7CiAgICAgICAgaGFuZGxlLnNlZWtUb0VuZE9mRmlsZSgpCiAgICAgICAgaGFuZGxlLndyaXRlKGxpbmUuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgICAgICB0cnk/IGhhbmRsZS5jbG9zZSgpCiAgICB9Cn0KCi8vIE1BUks6IC0g6YWN572uCgpzdHJ1Y3QgQ29uZmlnOiBDb2RhYmxlIHsKICAgIHZhciBobWFjS2V5OiBTdHJpbmcgICAgICAgICAgLy8gYmFzZTY0IOe8lueggeeahCAzMiDlrZfoioLpooTlhbHkuqvlr4bpkqUKICAgIHZhciBrZXljaGFpbkFjY291bnQ6IFN0cmluZyAgLy8g55m75b2V5a+G56CB5omA5Zyo55qE6ZKl5YyZ5Liy6LSm5oi35ZCNCiAgICB2YXIgZGV2aWNlTmFtZTogU3RyaW5nICAgICAgIC8vIOW5v+aSreWHuuWOu+eahOiuvuWkh+WQjQp9CgpmdW5jIGxvYWRDb25maWcoKSAtPiBDb25maWc/IHsKICAgIGd1YXJkIGxldCBkYXRhID0gRmlsZU1hbmFnZXIuZGVmYXVsdC5jb250ZW50cyhhdFBhdGg6IGtDb25maWdQYXRoKSBlbHNlIHsgcmV0dXJuIG5pbCB9CiAgICByZXR1cm4gdHJ5PyBKU09ORGVjb2RlcigpLmRlY29kZShDb25maWcuc2VsZiwgZnJvbTogZGF0YSkKfQoKZnVuYyBlbnN1cmVTdXBwb3J0RGlyZWN0b3J5KCkgewogICAgdHJ5PyBGaWxlTWFuYWdlci5kZWZhdWx0LmNyZWF0ZURpcmVjdG9yeShhdFBhdGg6IGtBcHBTdXBwb3J0LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB3aXRoSW50ZXJtZWRpYXRlRGlyZWN0b3JpZXM6IHRydWUsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGF0dHJpYnV0ZXM6IFsucG9zaXhQZXJtaXNzaW9uczogMG83MDBdKQp9CgovLyBNQVJLOiAtIOWvhueggeivu+WPlu+8iGtleWNoYWlu77yJCgpmdW5jIGZldGNoUGFzc3dvcmQoYWNjb3VudDogU3RyaW5nKSAtPiBTdHJpbmc/IHsKICAgIGxldCBwcm9jZXNzID0gUHJvY2VzcygpCiAgICBwcm9jZXNzLmV4ZWN1dGFibGVVUkwgPSBVUkwoZmlsZVVSTFdpdGhQYXRoOiAiL3Vzci9iaW4vc2VjdXJpdHkiKQogICAgcHJvY2Vzcy5hcmd1bWVudHMgPSBbImZpbmQtZ2VuZXJpYy1wYXNzd29yZCIsCiAgICAgICAgICAgICAgICAgICAgICAgICAiLWEiLCBhY2NvdW50LAogICAgICAgICAgICAgICAgICAgICAgICAgIi1zIiwga0tleWNoYWluU2VydmljZSwKICAgICAgICAgICAgICAgICAgICAgICAgICItdyJdCiAgICBsZXQgcGlwZSA9IFBpcGUoKQogICAgcHJvY2Vzcy5zdGFuZGFyZE91dHB1dCA9IHBpcGUKICAgIHByb2Nlc3Muc3RhbmRhcmRFcnJvciA9IEZpbGVIYW5kbGUubnVsbERldmljZQogICAgZG8gewogICAgICAgIHRyeSBwcm9jZXNzLnJ1bigpCiAgICB9IGNhdGNoIHsKICAgICAgICBsb2coIuaXoOazleaJp+ihjCBzZWN1cml0eSDlkb3ku6Q6IFwoZXJyb3IpIikKICAgICAgICByZXR1cm4gbmlsCiAgICB9CiAgICBsZXQgZGF0YSA9IHBpcGUuZmlsZUhhbmRsZUZvclJlYWRpbmcucmVhZERhdGFUb0VuZE9mRmlsZSgpCiAgICBwcm9jZXNzLndhaXRVbnRpbEV4aXQoKQogICAgZ3VhcmQgcHJvY2Vzcy50ZXJtaW5hdGlvblN0YXR1cyA9PSAwIGVsc2UgeyByZXR1cm4gbmlsIH0KICAgIHZhciBwdyA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpID8/ICIiCiAgICAvLyBzZWN1cml0eSAtdyDkvJrpmYTluKbkuIDkuKrmjaLooYwKICAgIHdoaWxlIHB3Lmhhc1N1ZmZpeCgiXG4iKSB8fCBwdy5oYXNTdWZmaXgoIlxyIikgeyBwdy5yZW1vdmVMYXN0KCkgfQogICAgcmV0dXJuIHB3LmlzRW1wdHkgPyBuaWwgOiBwdwp9CgovLyBNQVJLOiAtIOWxj+W5leeKtuaAgSAvIOaYvuekuuWZqOaOp+WItgoKZnVuYyBpc1NjcmVlbkxvY2tlZCgpIC0+IEJvb2wgewogICAgLy8g5YWs5byAIEFQSe+8mkNHU2Vzc2lvbkNvcHlDdXJyZW50RGljdGlvbmFyee+8iFF1YXJ0eiDnp4HmnInkvYbooqvlub/ms5vkvb/nlKjnmoQgc2Vzc2lvbiDlrZflhbjvvIkKICAgIGd1YXJkIGxldCBkaWN0ID0gQ0dTZXNzaW9uQ29weUN1cnJlbnREaWN0aW9uYXJ5KCkgYXM/IFtTdHJpbmc6IEFueV0gZWxzZSB7IHJldHVybiBmYWxzZSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEludCB7IHJldHVybiBsb2NrZWQgPT0gMSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEJvb2wgeyByZXR1cm4gbG9ja2VkIH0KICAgIHJldHVybiBmYWxzZQp9Cgp2YXIgZGlzcGxheUFzc2VydGlvbklEID0gSU9QTUFzc2VydGlvbklEKDApCgpmdW5jIHdha2VEaXNwbGF5KCkgewogICAgSU9QTUFzc2VydGlvbkRlY2xhcmVVc2VyQWN0aXZpdHkoIkJMRVVubG9ja0NtZCIgYXMgQ0ZTdHJpbmcsIGtJT1BNVXNlckFjdGl2ZUxvY2FsLCAmZGlzcGxheUFzc2VydGlvbklEKQp9CgpmdW5jIHNsZWVwRGlzcGxheSgpIHsKICAgIC8vIElPUmVnaXN0cnlFbnRyeUZyb21QYXRoIOmcgOimgSBDIOWtl+espuS4sui3r+W+hAogICAgbGV0IGVudHJ5ID0gSU9SZWdpc3RyeUVudHJ5RnJvbVBhdGgoa0lPTWFzdGVyUG9ydERlZmF1bHQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiSU9TZXJ2aWNlOi9JT1Jlc291cmNlcy9JT0Rpc3BsYXlXcmFuZ2xlciIpCiAgICBpZiBlbnRyeSAhPSAwIHsKICAgICAgICBJT1JlZ2lzdHJ5RW50cnlTZXRDRlByb3BlcnR5KGVudHJ5LCAiSU9SZXF1ZXN0SWRsZSIgYXMgQ0ZTdHJpbmcsIGtDRkJvb2xlYW5UcnVlKQogICAgICAgIElPT2JqZWN0UmVsZWFzZShlbnRyeSkKICAgIH0KfQoKLy8gTUFSSzogLSDlhajlsYDlvIDlhbMKCi8vLyDlronlhajmtYvor5XmqKHlvI/vvJrlrozmlbTotbDkuIDpgY0gQkxFIOaUtuWMheS4juagoemqjO+8jOS9huS4jeecn+eahOazqOWFpeWvhueggQp2YXIgZHJ5UnVuID0gZmFsc2UKCi8vIE1BUks6IC0g6ZSu55uY5LqL5Lu25rOo5YWl77yI6Kej6ZSB55qE5qC45b+D77yJCgpmdW5jIGZha2VLZXlTdHJva2VzKF8gc3RyaW5nOiBTdHJpbmcpIHsKICAgIGlmIGRyeVJ1biB7CiAgICAgICAgbG9nKCJbZHJ5LXJ1bl0g5pys5bqU5rOo5YWlIFwoc3RyaW5nLmNvdW50KSDkuKrlrZfnrKbnmoTlr4bnoIHlubblm57ovabvvIzlt7Lot7Pov4ciKQogICAgICAgIHJldHVybgogICAgfQogICAgZ3VhcmQgbGV0IHNvdXJjZSA9IENHRXZlbnRTb3VyY2Uoc3RhdGVJRDogLmhpZFN5c3RlbVN0YXRlKSBlbHNlIHsKICAgICAgICBsb2coIuaXoOazleWIm+W7uiBDR0V2ZW50U291cmNlIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIGxldCB1bml0cyA9IEFycmF5KHN0cmluZy51dGYxNikKICAgIGxldCBwZXJDaHVuayA9IDIwICAgLy8g5Y2V5Liq6ZSu55uY5LqL5Lu25pyA5aSa5pC65bimIDIwIOS4qiBVVEYtMTYg5a2X56ymCgogICAgdmFyIGluZGV4ID0gMAogICAgd2hpbGUgaW5kZXggPCB1bml0cy5jb3VudCB7CiAgICAgICAgbGV0IGNvdW50ID0gbWluKHBlckNodW5rLCB1bml0cy5jb3VudCAtIGluZGV4KQogICAgICAgIHZhciBidWZmZXIgPSBBcnJheSh1bml0c1tpbmRleCAuLjwgaW5kZXggKyBjb3VudF0pCgogICAgICAgIGd1YXJkIGxldCBkb3duID0gQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDQ5LCBrZXlEb3duOiB0cnVlKSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGRvd24ua2V5Ym9hcmRTZXRVbmljb2RlU3RyaW5nKHN0cmluZ0xlbmd0aDogY291bnQsIHVuaWNvZGVTdHJpbmc6ICZidWZmZXIpCiAgICAgICAgZG93bi5wb3N0KHRhcDogLmNnaGlkRXZlbnRUYXApCgogICAgICAgIENHRXZlbnQoa2V5Ym9hcmRFdmVudFNvdXJjZTogc291cmNlLCB2aXJ0dWFsS2V5OiA0OSwga2V5RG93bjogZmFsc2UpPwogICAgICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgICAgIGluZGV4ICs9IGNvdW50CiAgICB9CgogICAgLy8g5Zue6L2m6ZSu77yIdmlydHVhbEtleSA1MiA9IFJldHVybu+8iQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiB0cnVlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiBmYWxzZSk/CiAgICAgICAgLnBvc3QodGFwOiAuY2doaWRFdmVudFRhcCkKfQoKZnVuYyBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IEJvb2wgPSBmYWxzZSkgLT4gQm9vbCB7CiAgICBsZXQga2V5ID0ga0FYVHJ1c3RlZENoZWNrT3B0aW9uUHJvbXB0LnRha2VVbnJldGFpbmVkVmFsdWUoKSBhcyBTdHJpbmcKICAgIHJldHVybiBBWElzUHJvY2Vzc1RydXN0ZWRXaXRoT3B0aW9ucyhba2V5OiBwcm9tcHRdIGFzIENGRGljdGlvbmFyeSkKfQoKLy8gTUFSSzogLSDop6PplIEgLyDplIHlrpoKCnZhciB1bmxvY2tJbkZsaWdodCA9IGZhbHNlCgovLy8g6Ieq5Yqo6Kej6ZSB77ya5ZSk6YaS5bGP5bmVIC0+IOehruiupOWkhOS6jumUgeWxjyAtPiDms6jlhaXlr4bnoIEKZnVuYyBwZXJmb3JtVW5sb2NrKHJlcGx5OiBAZXNjYXBpbmcgKFN0cmluZykgLT4gVm9pZCkgewogICAgZ3VhcmQgIXVubG9ja0luRmxpZ2h0IGVsc2UgewogICAgICAgIHJlcGx5KCJCVVNZIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIC8vIGRyeS1ydW4g5LiL5LiN5qOA5p+l6L6F5Yqp5Yqf6IO95p2D6ZmQ77yM5Zug5Li65LiN5Lya55yf55qE5rOo5YWl5LqL5Lu2CiAgICBndWFyZCBkcnlSdW4gfHwgYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSBlbHNlIHsKICAgICAgICBsb2coIuino+mUgeWksei0pe+8mue8uuWwkeOAjOi+heWKqeWKn+iDveOAjeadg+mZkCIpCiAgICAgICAgcmVwbHkoIkVSUl9OT19BWCIpCiAgICAgICAgcmV0dXJuCiAgICB9CiAgICBndWFyZCBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpLCBsZXQgcGFzc3dvcmQgPSBmZXRjaFBhc3N3b3JkKGFjY291bnQ6IGNvbmZpZy5rZXljaGFpbkFjY291bnQpIGVsc2UgewogICAgICAgIGxvZygi6Kej6ZSB5aSx6LSl77ya6ZKl5YyZ5Liy5Lit6K+75LiN5Yiw5a+G56CBIikKICAgICAgICByZXBseSgiRVJSX05PX1BXIikKICAgICAgICByZXR1cm4KICAgIH0KCiAgICBpZiBkcnlSdW4gewogICAgICAgIGxvZygiW2RyeS1ydW5dIOagoemqjOmAmui/h++8jOacrOW6lOaJp+ihjOino+mUge+8iOWvhueggSBcKHBhc3N3b3JkLmNvdW50KSDlrZfnrKbvvIkiKQogICAgICAgIHJlcGx5KCJPSyIpCiAgICAgICAgcmV0dXJuCiAgICB9CgogICAgdW5sb2NrSW5GbGlnaHQgPSB0cnVlCiAgICAvLyDliLfmlrDmnYPpmZDnirbmgIHvvJrnlKjmiLflj6/og73liJrlnKjns7vnu5/orr7nva7ph4zmjojmnYPvvIzml6DpnIDph43lkK/mnI3liqEKICAgIHdyaXRlRGFlbW9uU3RhdHVzKCkKICAgIGxvZygi5pS25Yiw6Kej6ZSB5oyH5Luk77yM5byA5aeL5omn6KGMIikKCiAgICB3YWtlRGlzcGxheSgpCgogICAgLy8g5pi+56S65Zmo5ZSk6YaS5ZCO6ZyA6KaB5LiA54K55pe26Ze05omN55yf5q2j54K55Lqu77yM6YeN6K+V5Yeg6L2uCiAgICB2YXIgYXR0ZW1wdCA9IDAKICAgIGxldCBtYXhBdHRlbXB0cyA9IDgKCiAgICBmdW5jIGZpbmlzaChwYXNzd29yZDogU3RyaW5nLCBhdHRlbXB0OiBJbnQpIHsKICAgICAgICBsb2coIuWxj+W5leW3sumUgeWumu+8jOazqOWFpeWvhuegge+8iOesrCBcKGF0dGVtcHQpIOasoeWwneivle+8iSIpCiAgICAgICAgZmFrZUtleVN0cm9rZXMocGFzc3dvcmQpCiAgICAgICAgdW5sb2NrSW5GbGlnaHQgPSBmYWxzZQogICAgICAgIGxvZygi5bey5rOo5YWl5a+G56CB5bm25Zue6L2m77yM6Kej6ZSB5oyH5Luk5a6M5oiQIikKICAgICAgICByZXBseSgiT0siKQogICAgfQoKICAgIGZ1bmMgdGljaygpIHsKICAgICAgICBhdHRlbXB0ICs9IDEKICAgICAgICB3YWtlRGlzcGxheSgpCgogICAgICAgIGlmIGlzU2NyZWVuTG9ja2VkKCkgewogICAgICAgICAgICAvLyDlho3nrYkgMC40cyDorqnlr4bnoIHovpPlhaXmoYbojrflvpfnhKbngrkKICAgICAgICAgICAgbGV0IGN1cnJlbnQgPSBhdHRlbXB0CiAgICAgICAgICAgIERpc3BhdGNoUXVldWUubWFpbi5hc3luY0FmdGVyKGRlYWRsaW5lOiAubm93KCkgKyAwLjQpIHsKICAgICAgICAgICAgICAgIGZpbmlzaChwYXNzd29yZDogcGFzc3dvcmQsIGF0dGVtcHQ6IGN1cnJlbnQpCiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgfQoKICAgICAgICBpZiBhdHRlbXB0ID49IG1heEF0dGVtcHRzIHsKICAgICAgICAgICAgdW5sb2NrSW5GbGlnaHQgPSBmYWxzZQogICAgICAgICAgICBsb2coIuino+mUgeS4reatou+8muWxj+W5leacquWkhOS6jumUgeWumueKtuaAge+8iOWPr+iDveW3sueUseeUqOaIt+aJi+WKqOino+mUge+8iSIpCiAgICAgICAgICAgIHJlcGx5KCJOT1RfTE9DS0VEIikKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgfQogICAgICAgIERpc3BhdGNoUXVldWUubWFpbi5hc3luY0FmdGVyKGRlYWRsaW5lOiAubm93KCkgKyAwLjUsIGV4ZWN1dGU6IHRpY2spCiAgICB9CgogICAgdGljaygpCn0KCmZ1bmMgcGVyZm9ybUxvY2socmVwbHk6IEBlc2NhcGluZyAoU3RyaW5nKSAtPiBWb2lkKSB7CiAgICBpZiBkcnlSdW4gewogICAgICAgIGxvZygiW2RyeS1ydW5dIOacrOW6lOmUgeWumuWxj+W5le+8jOW3sui3s+i/hyIpCiAgICAgICAgcmVwbHkoIk9LIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIGxvZygi5pS25Yiw6ZSB5a6a5oyH5LukIikKICAgIC8vIOmAmui/h+mUgeWxj+engeaciSBBUEkg6ZSB5a6a77yb6Iul5LiN5Y+v55So5YiZ6YCA5Zue5bGP5L+dCiAgICBsZXQgaGFuZGxlID0gZGxvcGVuKCIvU3lzdGVtL0xpYnJhcnkvUHJpdmF0ZUZyYW1ld29ya3MvbG9naW4uZnJhbWV3b3JrL2xvZ2luIiwgUlRMRF9OT1cpCiAgICBpZiBsZXQgaGFuZGxlID0gaGFuZGxlLCBsZXQgc3ltID0gZGxzeW0oaGFuZGxlLCAiU0FDTG9ja1NjcmVlbkltbWVkaWF0ZSIpIHsKICAgICAgICB0eXBlYWxpYXMgTG9ja0ZuID0gQGNvbnZlbnRpb24oYykgKCkgLT4gSW50MzIKICAgICAgICBsZXQgbG9jayA9IHVuc2FmZUJpdENhc3Qoc3ltLCB0bzogTG9ja0ZuLnNlbGYpCiAgICAgICAgbGV0IHJlc3VsdCA9IGxvY2soKQogICAgICAgIGRsY2xvc2UoaGFuZGxlKQogICAgICAgIGxvZygiU0FDTG9ja1NjcmVlbkltbWVkaWF0ZSDov5Tlm54gXChyZXN1bHQpIikKICAgICAgICByZXBseShyZXN1bHQgPT0gMCA/ICJPSyIgOiAiRVJSX0xPQ0siKQogICAgfSBlbHNlIHsKICAgICAgICBsb2coImxvZ2luLmZyYW1ld29yayDkuI3lj6/nlKjvvIzmlLnnlKjlsY/kv53plIHlrpoiKQogICAgICAgIFByb2Nlc3MubGF1bmNoZWRQcm9jZXNzKGxhdW5jaFBhdGg6ICIvdXNyL2Jpbi9vcGVuIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBhcmd1bWVudHM6IFsiLWEiLCAiU2NyZWVuU2F2ZXJFbmdpbmUiXSkKICAgICAgICByZXBseSgiT0tfU1MiKQogICAgfQogICAgc2xlZXBEaXNwbGF5KCkKfQoKLy8gTUFSSzogLSDpmLLph43mlL4KCmZpbmFsIGNsYXNzIE5vbmNlQ2FjaGUgewogICAgcHJpdmF0ZSB2YXIgc2VlbjogW1N0cmluZzogRGF0ZV0gPSBbOl0KICAgIHByaXZhdGUgbGV0IGxvY2sgPSBOU0xvY2soKQoKICAgIC8vLyDov5Tlm54gdHJ1ZSDooajnpLror6Ugbm9uY2Ug5piv5paw55qE77yI5pyq6KKr6YeN5pS+77yJCiAgICBmdW5jIGFjY2VwdChfIG5vbmNlOiBEYXRhKSAtPiBCb29sIHsKICAgICAgICBsZXQga2V5ID0gbm9uY2UuYmFzZTY0RW5jb2RlZFN0cmluZygpCiAgICAgICAgbG9jay5sb2NrKCkKICAgICAgICBkZWZlciB7IGxvY2sudW5sb2NrKCkgfQogICAgICAgIGxldCBub3cgPSBEYXRlKCkKICAgICAgICBzZWVuID0gc2Vlbi5maWx0ZXIgeyBub3cudGltZUludGVydmFsU2luY2UoJDAudmFsdWUpIDwgMzAwIH0KICAgICAgICBpZiBzZWVuW2tleV0gIT0gbmlsIHsgcmV0dXJuIGZhbHNlIH0KICAgICAgICBpZiBzZWVuLmNvdW50ID49IGtOb25jZUNhY2hlTGltaXQgewogICAgICAgICAgICBpZiBsZXQgb2xkZXN0ID0gc2Vlbi5taW4oYnk6IHsgJDAudmFsdWUgPCAkMS52YWx1ZSB9KT8ua2V5IHsgc2Vlbi5yZW1vdmVWYWx1ZShmb3JLZXk6IG9sZGVzdCkgfQogICAgICAgIH0KICAgICAgICBzZWVuW2tleV0gPSBub3cKICAgICAgICByZXR1cm4gdHJ1ZQogICAgfQp9CgpsZXQgbm9uY2VDYWNoZSA9IE5vbmNlQ2FjaGUoKQoKLy8gTUFSSzogLSDmlbDmja7ljIXmoKHpqowKCmVudW0gVmVyaWZ5UmVzdWx0IHsKICAgIGNhc2Ugb2soY29tbWFuZDogVUludDgpCiAgICBjYXNlIGZhaWxlZChTdHJpbmcpCn0KCmZ1bmMgdmVyaWZ5UGFja2V0KF8gZGF0YTogRGF0YSwga2V5OiBTeW1tZXRyaWNLZXkpIC0+IFZlcmlmeVJlc3VsdCB7CiAgICBndWFyZCBkYXRhLmNvdW50ID49IGtQYWNrZXRMZW4gZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfTEVOIikgfQogICAgbGV0IGJ5dGVzID0gW1VJbnQ4XShkYXRhKQoKICAgIGd1YXJkIGJ5dGVzWzBdID09IGtNYWdpY1swXSwgYnl0ZXNbMV0gPT0ga01hZ2ljWzFdIGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX01BR0lDIikgfQogICAgZ3VhcmQgYnl0ZXNbMl0gPT0ga1ZlcnNpb24gZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfVkVSIikgfQoKICAgIGxldCBub3cgPSBJbnQ2NChEYXRlKCkudGltZUludGVydmFsU2luY2UxOTcwKQogICAgdmFyIHRzOiBJbnQ2NCA9IDAKICAgIGZvciBpIGluIDAuLjw4IHsgdHMgPSAodHMgPDwgOCkgfCBJbnQ2NChieXRlc1s0ICsgaV0pIH0KICAgIGd1YXJkIGFicyhub3cgLSB0cykgPD0ga1RpbWVzdGFtcFNrZXcgZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfVElNRSIpIH0KCiAgICBsZXQgbm9uY2UgPSBEYXRhKGJ5dGVzWzEyLi48MjhdKQogICAgZ3VhcmQgbm9uY2VDYWNoZS5hY2NlcHQobm9uY2UpIGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX1JFUExBWSIpIH0KCiAgICBsZXQgbWVzc2FnZSA9IERhdGEoYnl0ZXNbMC4uPGtIbWFjT2Zmc2V0XSkKICAgIGxldCBleHBlY3RlZCA9IERhdGEoSE1BQzxTSEEyNTY+LmF1dGhlbnRpY2F0aW9uQ29kZShmb3I6IG1lc3NhZ2UsIHVzaW5nOiBrZXkpKQogICAgbGV0IHJlY2VpdmVkID0gRGF0YShieXRlc1trSG1hY09mZnNldC4uPGtQYWNrZXRMZW5dKQogICAgLy8g5bi46YeP5pe26Ze05q+U6L6DCiAgICBndWFyZCBleHBlY3RlZC5jb3VudCA9PSByZWNlaXZlZC5jb3VudCBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9ITUFDIikgfQogICAgdmFyIGRpZmY6IFVJbnQ4ID0gMAogICAgZm9yIGkgaW4gMC4uPGV4cGVjdGVkLmNvdW50IHsgZGlmZiB8PSBleHBlY3RlZFtpXSBeIHJlY2VpdmVkW2ldIH0KICAgIGd1YXJkIGRpZmYgPT0gMCBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9ITUFDIikgfQoKICAgIHJldHVybiAub2soY29tbWFuZDogYnl0ZXNbM10pCn0KCi8vIE1BUks6IC0gQkxFIOWkluiuvgoKZmluYWwgY2xhc3MgUGVyaXBoZXJhbFNlcnZlcjogTlNPYmplY3QsIENCUGVyaXBoZXJhbE1hbmFnZXJEZWxlZ2F0ZSB7CiAgICBwcml2YXRlIHZhciBtYW5hZ2VyOiBDQlBlcmlwaGVyYWxNYW5hZ2VyIQogICAgcHJpdmF0ZSB2YXIgY29tbWFuZENoYXI6IENCTXV0YWJsZUNoYXJhY3RlcmlzdGljIQogICAgcHJpdmF0ZSB2YXIgc3RhdHVzQ2hhcjogQ0JNdXRhYmxlQ2hhcmFjdGVyaXN0aWMhCiAgICBwcml2YXRlIHZhciBrZXk6IFN5bW1ldHJpY0tleSEKICAgIHByaXZhdGUgdmFyIGRldmljZU5hbWU6IFN0cmluZyA9ICJCTEVVbmxvY2stTWFjIgogICAgcHJpdmF0ZSB2YXIgYWR2ZXJ0aXNlVGltZXI6IFRpbWVyPwogICAgcHJpdmF0ZSB2YXIgc3RhdHVzVmFsdWUgPSAiUkVBRFkiCgogICAgZnVuYyBzdGFydChrZXk6IFN5bW1ldHJpY0tleSwgZGV2aWNlTmFtZTogU3RyaW5nKSB7CiAgICAgICAgc2VsZi5rZXkgPSBrZXkKICAgICAgICBzZWxmLmRldmljZU5hbWUgPSBkZXZpY2VOYW1lCiAgICAgICAgbWFuYWdlciA9IENCUGVyaXBoZXJhbE1hbmFnZXIoZGVsZWdhdGU6IHNlbGYsIHF1ZXVlOiBuaWwpCiAgICB9CgogICAgcHJpdmF0ZSBmdW5jIGJ1aWxkU2VydmljZSgpIHsKICAgICAgICBjb21tYW5kQ2hhciA9IENCTXV0YWJsZUNoYXJhY3RlcmlzdGljKHR5cGU6IGtDaGFyQ29tbWFuZFVVSUQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwcm9wZXJ0aWVzOiBbLndyaXRlLCAud3JpdGVXaXRob3V0UmVzcG9uc2VdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdmFsdWU6IG5pbCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBlcm1pc3Npb25zOiBbLndyaXRlYWJsZV0pCgogICAgICAgIC8vIOazqOaEj++8muW4piAubm90aWZ5Ly5yZWFkIOeahOeJueW+geS4jeiDvemihOe9rue8k+WtmOWAvO+8iENvcmVCbHVldG9vdGgg5Lya5oqbCiAgICAgICAgLy8gIkNoYXJhY3RlcmlzdGljcyB3aXRoIGNhY2hlZCB2YWx1ZXMgbXVzdCBiZSByZWFkLW9ubHki77yJ77yMCiAgICAgICAgLy8g5Zug5q2k6L+Z6YeMIHZhbHVlIOW/hemhu+aYryBuaWzvvIzor7vlj5bml7blnKggZGlkUmVjZWl2ZVJlYWQg6YeM5Yqo5oCB6L+U5Zue44CCCiAgICAgICAgc3RhdHVzQ2hhciA9IENCTXV0YWJsZUNoYXJhY3RlcmlzdGljKHR5cGU6IGtDaGFyU3RhdHVzVVVJRCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcHJvcGVydGllczogWy5yZWFkLCAubm90aWZ5XSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdmFsdWU6IG5pbCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcGVybWlzc2lvbnM6IFsucmVhZGFibGVdKQoKICAgICAgICAvLyDlj6ror7vkuJTlgLzlm7rlrprnmoTnibnlvoHlj6/ku6XpooTnva7nvJPlrZjlgLzvvIzlr7nmiYvmnLrnq6/mm7TnnIHkuIDmrKHkuqTkupIKICAgICAgICBsZXQgaW5mbyA9ICJCTEVVbmxvY2tDbWQgdjE7XChkZXZpY2VOYW1lKSIKICAgICAgICBsZXQgaW5mb0NoYXIgPSBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyh0eXBlOiBrQ2hhckluZm9VVUlELAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3BlcnRpZXM6IFsucmVhZF0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgdmFsdWU6IGluZm8uZGF0YSh1c2luZzogLnV0ZjgpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBlcm1pc3Npb25zOiBbLnJlYWRhYmxlXSkKCiAgICAgICAgbGV0IHNlcnZpY2UgPSBDQk11dGFibGVTZXJ2aWNlKHR5cGU6IGtTZXJ2aWNlVVVJRCwgcHJpbWFyeTogdHJ1ZSkKICAgICAgICBzZXJ2aWNlLmNoYXJhY3RlcmlzdGljcyA9IFtjb21tYW5kQ2hhciwgc3RhdHVzQ2hhciwgaW5mb0NoYXJdCiAgICAgICAgbWFuYWdlci5hZGQoc2VydmljZSkKICAgIH0KCiAgICBwcml2YXRlIGZ1bmMgc3RhcnRBZHZlcnRpc2luZygpIHsKICAgICAgICBndWFyZCBtYW5hZ2VyLnN0YXRlID09IC5wb3dlcmVkT24gZWxzZSB7IHJldHVybiB9CiAgICAgICAgZ3VhcmQgIW1hbmFnZXIuaXNBZHZlcnRpc2luZyBlbHNlIHsgcmV0dXJuIH0KICAgICAgICBtYW5hZ2VyLnN0YXJ0QWR2ZXJ0aXNpbmcoWwogICAgICAgICAgICBDQkFkdmVydGlzZW1lbnREYXRhU2VydmljZVVVSURzS2V5OiBba1NlcnZpY2VVVUlEXSwKICAgICAgICAgICAgQ0JBZHZlcnRpc2VtZW50RGF0YUxvY2FsTmFtZUtleTogZGV2aWNlTmFtZSwKICAgICAgICBdKQogICAgfQoKICAgIGZ1bmMgc2V0U3RhdHVzKF8gdGV4dDogU3RyaW5nKSB7CiAgICAgICAgc3RhdHVzVmFsdWUgPSB0ZXh0CiAgICAgICAgLy8g5rOo5oSP77ya5LiN6KaB57uZIHN0YXR1c0NoYXIudmFsdWUg6LWL5YC844CC5bimIC5ub3RpZnkg55qE54m55b6B5LiA5pem6KKr6LWL5LqI57yT5a2Y5YC877yMCiAgICAgICAgLy8g5LmL5ZCOIG1hbmFnZXIuYWRkKHNlcnZpY2UpIOS8muaKmyAiQ2hhcmFjdGVyaXN0aWNzIHdpdGggY2FjaGVkIHZhbHVlcyBtdXN0IGJlIHJlYWQtb25seSLjgIIKICAgICAgICAvLyDor7vlj5bnlLEgZGlkUmVjZWl2ZVJlYWQg5Yqo5oCB6L+U5Zue77yM5o6o6YCB6LWwIHVwZGF0ZVZhbHVl44CCCiAgICAgICAgZ3VhcmQgbWFuYWdlci5zdGF0ZSA9PSAucG93ZXJlZE9uLCBsZXQgY2hhcmFjdGVyaXN0aWMgPSBzdGF0dXNDaGFyIGVsc2UgeyByZXR1cm4gfQogICAgICAgIGlmICFtYW5hZ2VyLnVwZGF0ZVZhbHVlKHRleHQuZGF0YSh1c2luZzogLnV0ZjgpISwgZm9yOiBjaGFyYWN0ZXJpc3RpYywgb25TdWJzY3JpYmVkQ2VudHJhbHM6IG5pbCkgewogICAgICAgICAgICAvLyDpmJ/liJflt7Lmu6HvvIznrYkgcGVyaXBoZXJhbE1hbmFnZXJJc1JlYWR5IOaXtuihpeWPkQogICAgICAgICAgICBwZW5kaW5nU3RhdHVzID0gdGV4dAogICAgICAgIH0KICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyRGlkVXBkYXRlU3RhdGUoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyKSB7CiAgICAgICAgc3dpdGNoIHBlcmlwaGVyYWwuc3RhdGUgewogICAgICAgIGNhc2UgLnBvd2VyZWRPbjoKICAgICAgICAgICAgbG9nKCLok53niZnlt7LlsLHnu6rvvIzms6jlhowgR0FUVCDmnI3liqEiKQogICAgICAgICAgICBidWlsZFNlcnZpY2UoKQogICAgICAgICAgICBzdGFydEFkdmVydGlzaW5nKCkKICAgICAgICAgICAgLy8g5a6a5pyf6YeN5paw5bm/5pKt77yM6YG/5YWN6ZSB5bGPL+ezu+e7n+S8keecoOWQjuW5v+aSreiiq+WBnOaOiQogICAgICAgICAgICBhZHZlcnRpc2VUaW1lcj8uaW52YWxpZGF0ZSgpCiAgICAgICAgICAgIGFkdmVydGlzZVRpbWVyID0gVGltZXIuc2NoZWR1bGVkVGltZXIod2l0aFRpbWVJbnRlcnZhbDogMjAsIHJlcGVhdHM6IHRydWUpIHsgW3dlYWsgc2VsZl0gXyBpbgogICAgICAgICAgICAgICAgc2VsZj8uc3RhcnRBZHZlcnRpc2luZygpCiAgICAgICAgICAgIH0KICAgICAgICAgICAgUnVuTG9vcC5tYWluLmFkZChhZHZlcnRpc2VUaW1lciEsIGZvck1vZGU6IC5jb21tb24pCiAgICAgICAgICAgIHNldFN0YXR1cygiUkVBRFkiKQogICAgICAgIGNhc2UgLnBvd2VyZWRPZmY6CiAgICAgICAgICAgIGxvZygi6JOd54mZ5bey5YWz6Zet77yM562J5b6F6YeN5paw5byA5ZCvIikKICAgICAgICBjYXNlIC51bmF1dGhvcml6ZWQ6CiAgICAgICAgICAgIGxvZygi6JOd54mZ5p2D6ZmQ6KKr5ouS57ud77yM6K+35Zyo44CM57O757uf6K6+572uIOKGkiDpmpDnp4HkuI7lronlhajmgKcg4oaSIOiTneeJmeOAjeS4reaOiOadgyIpCiAgICAgICAgZGVmYXVsdDoKICAgICAgICAgICAgYnJlYWsKICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlckRpZFN0YXJ0QWR2ZXJ0aXNpbmcoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLCBlcnJvcjogRXJyb3I/KSB7CiAgICAgICAgaWYgbGV0IGVycm9yID0gZXJyb3IgewogICAgICAgICAgICBsb2coIuW5v+aSreWksei0pTogXChlcnJvci5sb2NhbGl6ZWREZXNjcmlwdGlvbikiKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvZygi5q2j5Zyo5bm/5pKt77yM562J5b6F5omL5py66L+e5o6l77yI6K6+5aSH5ZCNIFwoZGV2aWNlTmFtZSnvvIkiKQogICAgICAgIH0KICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwgZGlkQWRkIHNlcnZpY2U6IENCU2VydmljZSwgZXJyb3I6IEVycm9yPykgewogICAgICAgIGlmIGxldCBlcnJvciA9IGVycm9yIHsKICAgICAgICAgICAgbG9nKCLmt7vliqDmnI3liqHlpLHotKU6IFwoZXJyb3IubG9jYWxpemVkRGVzY3JpcHRpb24pIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBsb2coIkdBVFQg5pyN5Yqh5bey5bCx57uq77yIU2VydmljZSBcKGtTZXJ2aWNlVVVJRC51dWlkU3RyaW5nKe+8iSIpCiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXIoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLCBjZW50cmFsOiBDQkNlbnRyYWwsIGRpZFN1YnNjcmliZVRvIGNoYXJhY3RlcmlzdGljOiBDQkNoYXJhY3RlcmlzdGljKSB7CiAgICAgICAgbG9nKCLmiYvmnLrlt7LorqLpmIXnirbmgIHnibnlvoE6IFwoY2VudHJhbC5pZGVudGlmaWVyLnV1aWRTdHJpbmcpIikKICAgICAgICBzZXRTdGF0dXMoIkNPTk5FQ1RFRCIpCiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsIGNlbnRyYWw6IENCQ2VudHJhbCwgZGlkVW5zdWJzY3JpYmVGcm9tIGNoYXJhY3RlcmlzdGljOiBDQkNoYXJhY3RlcmlzdGljKSB7CiAgICAgICAgbG9nKCLmiYvmnLrlj5bmtojorqLpmIXnirbmgIHnibnlvoEiKQogICAgfQoKICAgIHByaXZhdGUgdmFyIHBlbmRpbmdTdGF0dXM6IFN0cmluZz8KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VySXNSZWFkeSh0b1VwZGF0ZVN1YnNjcmliZXJzIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIpIHsKICAgICAgICAvLyDkuIrkuIDmrKEgdXBkYXRlVmFsdWUg5Zug5Y+R6YCB6Zif5YiX5ruh6ICM5aSx6LSl77yM6L+Z6YeM6KGl5Y+RCiAgICAgICAgZ3VhcmQgbGV0IHRleHQgPSBwZW5kaW5nU3RhdHVzLCBtYW5hZ2VyLnN0YXRlID09IC5wb3dlcmVkT24sIGxldCBjaGFyYWN0ZXJpc3RpYyA9IHN0YXR1c0NoYXIgZWxzZSB7IHJldHVybiB9CiAgICAgICAgcGVuZGluZ1N0YXR1cyA9IG5pbAogICAgICAgIG1hbmFnZXIudXBkYXRlVmFsdWUodGV4dC5kYXRhKHVzaW5nOiAudXRmOCkhLCBmb3I6IGNoYXJhY3RlcmlzdGljLCBvblN1YnNjcmliZWRDZW50cmFsczogbmlsKQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXIoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLAogICAgICAgICAgICAgICAgICAgICAgICAgICBkaWRSZWNlaXZlV3JpdGUgcmVxdWVzdHM6IFtDQkFUVFJlcXVlc3RdKSB7CiAgICAgICAgZm9yIHJlcXVlc3QgaW4gcmVxdWVzdHMgewogICAgICAgICAgICBndWFyZCByZXF1ZXN0LmNoYXJhY3RlcmlzdGljLnV1aWQgPT0ga0NoYXJDb21tYW5kVVVJRCBlbHNlIHsgY29udGludWUgfQogICAgICAgICAgICBsZXQgZGF0YSA9IHJlcXVlc3QudmFsdWUgPz8gRGF0YSgpCiAgICAgICAgICAgIGxvZygi5pS25Yiw5YaZ5YWlIFwoZGF0YS5jb3VudCkg5a2X6IqCIikKCiAgICAgICAgICAgIC8vIOaXoOiuuuagoemqjOe7k+aenOWmguS9lemDveimgeW6lOetlO+8m+W4puW6lOetlOWGmeS4jeWbnuS8muiuqeaJi+acuuerr+WNoeS9jwogICAgICAgICAgICBwZXJpcGhlcmFsLnJlc3BvbmQodG86IHJlcXVlc3QsIHdpdGhSZXN1bHQ6IC5zdWNjZXNzKQoKICAgICAgICAgICAgbGV0IHJlc3VsdCA9IHZlcmlmeVBhY2tldChkYXRhLCBrZXk6IGtleSkKICAgICAgICAgICAgc3dpdGNoIHJlc3VsdCB7CiAgICAgICAgICAgIGNhc2UgLmZhaWxlZChsZXQgcmVhc29uKToKICAgICAgICAgICAgICAgIGxvZygi5qCh6aqM5aSx6LSlOiBcKHJlYXNvbikiKQogICAgICAgICAgICAgICAgc2V0U3RhdHVzKHJlYXNvbikKCiAgICAgICAgICAgIGNhc2UgLm9rKGxldCBjb21tYW5kKToKICAgICAgICAgICAgICAgIHN3aXRjaCBjb21tYW5kIHsKICAgICAgICAgICAgICAgIGNhc2Uga0NtZFVubG9jazoKICAgICAgICAgICAgICAgICAgICBzZXRTdGF0dXMoIlVOTE9DS0lORyIpCiAgICAgICAgICAgICAgICAgICAgcGVyZm9ybVVubG9jayB7IHN0YXR1cyBpbgogICAgICAgICAgICAgICAgICAgICAgICBzZWxmLnNldFN0YXR1cyhzdGF0dXMpCiAgICAgICAgICAgICAgICAgICAgICAgIGxvZygi6Kej6ZSB57uT5p6cOiBcKHN0YXR1cykiKQogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGNhc2Uga0NtZExvY2s6CiAgICAgICAgICAgICAgICAgICAgc2V0U3RhdHVzKCJMT0NLSU5HIikKICAgICAgICAgICAgICAgICAgICBwZXJmb3JtTG9jayB7IHN0YXR1cyBpbgogICAgICAgICAgICAgICAgICAgICAgICBzZWxmLnNldFN0YXR1cyhzdGF0dXMpCiAgICAgICAgICAgICAgICAgICAgICAgIGxvZygi6ZSB5a6a57uT5p6cOiBcKHN0YXR1cykiKQogICAgICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgICAgIGNhc2Uga0NtZFBpbmc6CiAgICAgICAgICAgICAgICAgICAgbG9nKCLmlLbliLAgUElORyIpCiAgICAgICAgICAgICAgICAgICAgc2V0U3RhdHVzKCJQT05HIikKICAgICAgICAgICAgICAgIGRlZmF1bHQ6CiAgICAgICAgICAgICAgICAgICAgbG9nKCLmnKrnn6XmjIfku6QgMHhcKFN0cmluZyhjb21tYW5kLCByYWRpeDogMTYpKSIpCiAgICAgICAgICAgICAgICAgICAgc2V0U3RhdHVzKCJFUlJfQ01EIikKICAgICAgICAgICAgICAgIH0KICAgICAgICAgICAgfQogICAgICAgIH0KICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwKICAgICAgICAgICAgICAgICAgICAgICAgICAgZGlkUmVjZWl2ZVJlYWQgcmVxdWVzdDogQ0JBVFRSZXF1ZXN0KSB7CiAgICAgICAgaWYgcmVxdWVzdC5jaGFyYWN0ZXJpc3RpYy51dWlkID09IGtDaGFyU3RhdHVzVVVJRCB7CiAgICAgICAgICAgIGxldCBkYXRhID0gc3RhdHVzVmFsdWUuZGF0YSh1c2luZzogLnV0ZjgpIQogICAgICAgICAgICBpZiByZXF1ZXN0Lm9mZnNldCA+IGRhdGEuY291bnQgewogICAgICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuaW52YWxpZE9mZnNldCkKICAgICAgICAgICAgICAgIHJldHVybgogICAgICAgICAgICB9CiAgICAgICAgICAgIHJlcXVlc3QudmFsdWUgPSBkYXRhLnN1YmRhdGEoaW46IHJlcXVlc3Qub2Zmc2V0Li48ZGF0YS5jb3VudCkKICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuc3VjY2VzcykKICAgICAgICB9IGVsc2UgaWYgcmVxdWVzdC5jaGFyYWN0ZXJpc3RpYy51dWlkID09IGtDaGFySW5mb1VVSUQgewogICAgICAgICAgICBsZXQgZGF0YSA9ICJCTEVVbmxvY2tDbWQgdjE7XChkZXZpY2VOYW1lKSIuZGF0YSh1c2luZzogLnV0ZjgpIQogICAgICAgICAgICByZXF1ZXN0LnZhbHVlID0gZGF0YQogICAgICAgICAgICBwZXJpcGhlcmFsLnJlc3BvbmQodG86IHJlcXVlc3QsIHdpdGhSZXN1bHQ6IC5zdWNjZXNzKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLmF0dHJpYnV0ZU5vdEZvdW5kKQogICAgICAgIH0KICAgIH0KfQoKLy8gTUFSSzogLSDlhaXlj6MKCmZ1bmMgcHJpbnRVc2FnZSgpIHsKICAgIHByaW50KCIiIgogICAgQkxFVW5sb2NrQ21kIOKAlCDnlKjmiYvmnLrpgJrov4fok53niZnop6PplIHov5nlj7AgTWFjCgogICAg55So5rOVOiBCTEVVbmxvY2tDbWQgW+mAiemhuV0KCiAgICAgIC0tcHJpbnQtdG9rZW4gICAgICAgIOaJk+WNsOmFjeWvueS7pOeJjO+8iOWcqOaJi+acuiBBcHAg5Lit5aGr5YaZ6L+Z5Liq5YC877yJCiAgICAgIC0tc2V0LWtleSA8YmFzZTY0PiAgIOWGmeWFpeaMh+WumueahOmFjeWvueWvhumSpQogICAgICAtLWRldmljZS1uYW1lIDzlkI0+ICAg5bm/5pKt55qE6K6+5aSH5ZCNCiAgICAgIC0tYWRkLWFjY2Vzc2liaWxpdHkgIOaJk+W8gOOAjOi+heWKqeWKn+iDveOAjeaOiOadg+aPkOekugogICAgICAtLWNoZWNrICAgICAgICAgICAgICDoh6rmo4DvvJrmiZPljbDmnYPpmZDjgIHpkqXljJnkuLLkuI7phY3nva7nirbmgIEKICAgICAgLS1kcnktcnVuICAgICAgICAgICAg5a6J5YWo5rWL6K+V5qih5byP77ya6LWw5a6MIEJMRSDmlLbljIXkuI7moKHpqozvvIzkvYbkuI3nnJ/nmoTop6PplIEKICAgICAgLS1zaG93LXRva2VuICAgICAgICAg5omT5Y2w6YWN5a+55Luk54mM77yI5pyq5a6J6KOF5pe26Ieq5Yqo55Sf5oiQ5LiA5Liq5Li05pe25a+G6ZKl77yJCiAgICAgIC0tc2VsZnRlc3QgPGhleD4gICAgIOWNj+iuruiHquajgO+8muWvuee7meWumueahOWNgeWFrei/m+WItua2iOaBr+i+k+WHuiBITUFDLVNIQTI1NgogICAgICAtLXZlcnNpb24gICAgICAgICAgICDmmL7npLrniYjmnKwKICAgICIiIikKfQoKZW5zdXJlU3VwcG9ydERpcmVjdG9yeSgpCgpsZXQgYXJncyA9IEFycmF5KENvbW1hbmRMaW5lLmFyZ3VtZW50cy5kcm9wRmlyc3QoKSkKCmlmIGFyZ3MuY29udGFpbnMoIi0tdmVyc2lvbiIpIHsKICAgIHByaW50KCJCTEVVbmxvY2tDbWQgMS4wLjAiKQogICAgZXhpdCgwKQp9CgovLyDljY/orq7pl63njq/oh6rmo4DvvJrkuI3kvp3otZbok53niZnvvIznm7TmjqXotbAi5pS25YyFIC0+IOagoemqjCAtPiDmiafooYwi5YWo5rWB56iLCmlmIGFyZ3MuY29udGFpbnMoIi0tc2VsZnRlc3QtcHJvdG9jb2wiKSB7CiAgICBkcnlSdW4gPSB0cnVlCiAgICB2YXIgZmFpbGVkID0gMAoKICAgIGZ1bmMgZXhwZWN0KF8gbGFiZWw6IFN0cmluZywgXyBvazogQm9vbCwgXyBkZXRhaWw6IFN0cmluZyA9ICIiKSB7CiAgICAgICAgaWYgb2sgewogICAgICAgICAgICBwcmludCgiICDinJMgXChsYWJlbCkiKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIHByaW50KCIgIOKclyBcKGxhYmVsKSAgXChkZXRhaWwpIikKICAgICAgICAgICAgZmFpbGVkICs9IDEKICAgICAgICB9CiAgICB9CgogICAgLy8g55So5Li05pe25a+G6ZKl5p6E6YCg5rWL6K+V5YyFCiAgICB2YXIga2V5Qnl0ZXMgPSBbVUludDhdKHJlcGVhdGluZzogMCwgY291bnQ6IDMyKQogICAgZm9yIGkgaW4gMC4uPDMyIHsga2V5Qnl0ZXNbaV0gPSBVSW50OChpKSB9CiAgICBsZXQgdGVzdEtleSA9IFN5bW1ldHJpY0tleShkYXRhOiBEYXRhKGtleUJ5dGVzKSkKCiAgICBmdW5jIG1ha2VQYWNrZXQoY29tbWFuZDogVUludDgsIHRpbWVzdGFtcDogSW50NjQgPSBJbnQ2NChEYXRlKCkudGltZUludGVydmFsU2luY2UxOTcwKSwKICAgICAgICAgICAgICAgICAgICBub25jZTogRGF0YT8gPSBuaWwsIHRhbXBlcjogQm9vbCA9IGZhbHNlKSAtPiBEYXRhIHsKICAgICAgICB2YXIgbWVzc2FnZSA9IERhdGEoWzB4NDIsIDB4NTUsIDB4MDEsIGNvbW1hbmRdKQogICAgICAgIHZhciB0cyA9IFVJbnQ2NChiaXRQYXR0ZXJuOiB0aW1lc3RhbXApLmJpZ0VuZGlhbgogICAgICAgIHdpdGhVbnNhZmVCeXRlcyhvZjogJnRzKSB7IG1lc3NhZ2UuYXBwZW5kKGNvbnRlbnRzT2Y6ICQwKSB9CiAgICAgICAgdmFyIG4gPSBub25jZSA/PyBEYXRhKCgwLi48MTYpLm1hcCB7IF8gaW4gVUludDgucmFuZG9tKGluOiAwLi4uMjU1KSB9KQogICAgICAgIGlmIG4uY291bnQgIT0gMTYgeyBuID0gRGF0YShyZXBlYXRpbmc6IDAsIGNvdW50OiAxNikgfQogICAgICAgIG1lc3NhZ2UuYXBwZW5kKG4pCiAgICAgICAgbWVzc2FnZS5hcHBlbmQoY29udGVudHNPZjogWzB4MDAsIDB4MDBdKQogICAgICAgIHZhciB0YWcgPSBEYXRhKEhNQUM8U0hBMjU2Pi5hdXRoZW50aWNhdGlvbkNvZGUoZm9yOiBtZXNzYWdlLCB1c2luZzogdGVzdEtleSkpCiAgICAgICAgaWYgdGFtcGVyIHsgdGFnWzBdIF49IDB4RkYgfQogICAgICAgIHJldHVybiBtZXNzYWdlICsgdGFnCiAgICB9CgogICAgcHJpbnQoIj09IOaKpeaWh+agoemqjCA9PSIpCgogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2spLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rKGxldCBjKTogZXhwZWN0KCLlkIjms5Xop6PplIHljIXpgJrov4fmoKHpqowiLCBjID09IGtDbWRVbmxvY2ssICLlkb3ku6Q9XChjKSIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIuWQiOazleino+mUgeWMhemAmui/h+agoemqjCIsIGZhbHNlLCByKQogICAgfQoKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kUGluZyksIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2sobGV0IGMpOiBleHBlY3QoIlBJTkcg5YyF6YCa6L+H5qCh6aqMIiwgYyA9PSBrQ21kUGluZywgIuWRveS7pD1cKGMpIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgiUElORyDljIXpgJrov4fmoKHpqowiLCBmYWxzZSwgcikKICAgIH0KCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jaywgdGFtcGVyOiB0cnVlKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLnr6HmlLnnmoQgSE1BQyDlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIuevoeaUueeahCBITUFDIOiiq+aLkue7nSIsIHIgPT0gIkVSUl9ITUFDIiwgcikKICAgIH0KCiAgICBsZXQgd3JvbmdLZXkgPSBTeW1tZXRyaWNLZXkoZGF0YTogRGF0YShyZXBlYXRpbmc6IDB4QUIsIGNvdW50OiAzMikpCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jayksIGtleTogd3JvbmdLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIumUmeivr+WvhumSpeW/hemhu+iiq+aLkue7nSIsIGZhbHNlLCAi5bGF54S26YCa6L+H5LqGIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi6ZSZ6K+v5a+G6ZKl6KKr5ouS57udIiwgciA9PSAiRVJSX0hNQUMiLCByKQogICAgfQoKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQoRGF0YShbMHg0MiwgMHg1NSwgMHgwMV0pLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIui/h+efreeahOWMheW/hemhu+iiq+aLkue7nSIsIGZhbHNlLCAi5bGF54S26YCa6L+H5LqGIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi6L+H55+t55qE5YyF6KKr5ouS57udIiwgciA9PSAiRVJSX0xFTiIsIHIpCiAgICB9CgogICAgdmFyIGJhZE1hZ2ljID0gbWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrKQogICAgYmFkTWFnaWNbMF0gPSAweDAwCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KGJhZE1hZ2ljLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIumUmeivr+mtlOaVsOW/hemhu+iiq+aLkue7nSIsIGZhbHNlLCAi5bGF54S26YCa6L+H5LqGIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi6ZSZ6K+v6a2U5pWw6KKr5ouS57udIiwgciA9PSAiRVJSX01BR0lDIiwgcikKICAgIH0KCiAgICBsZXQgc3RhbGUgPSBJbnQ2NChEYXRlKCkudGltZUludGVydmFsU2luY2UxOTcwKSAtIDYwMAogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2ssIHRpbWVzdGFtcDogc3RhbGUpLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIui/h+acn+aXtumXtOaIs+W/hemhu+iiq+aLkue7nSIsIGZhbHNlLCAi5bGF54S26YCa6L+H5LqGIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi6L+H5pyf5pe26Ze05oiz6KKr5ouS57udIiwgciA9PSAiRVJSX1RJTUUiLCByKQogICAgfQoKICAgIHByaW50KCkKICAgIHByaW50KCI9PSDpmLLph43mlL4gPT0iKQogICAgbGV0IGZpeGVkTm9uY2UgPSBEYXRhKHJlcGVhdGluZzogMHg1QSwgY291bnQ6IDE2KQogICAgbGV0IHAxID0gbWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrLCBub25jZTogZml4ZWROb25jZSkKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQocDEsIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi5ZCM5LiAIG5vbmNlIOmmluasoemAmui/hyIsIHRydWUpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIuWQjOS4gCBub25jZSDpppbmrKHpgJrov4ciLCBmYWxzZSwgcikKICAgIH0KICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQocDEsIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi5ZCM5LiAIG5vbmNlIOmHjeaUvuW/hemhu+iiq+aLkue7nSIsIGZhbHNlLCAi5bGF54S26YCa6L+H5LqGIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi5ZCM5LiAIG5vbmNlIOmHjeaUvuiiq+aLkue7nSIsIHIgPT0gIkVSUl9SRVBMQVkiLCByKQogICAgfQoKICAgIHByaW50KCkKICAgIHByaW50KCI9PSDop6PplIHmtYHnqIvvvIhkcnktcnVu77yM5LiN5Lya55yf55qE5rOo5YWl5a+G56CB77yJPT0iKQogICAgLy8g6YCg5LiA5Liq5Li05pe26YWN572u77yM5oyH5ZCR5LiA5Liq5LiN5a2Y5Zyo55qE6ZKl5YyZ5Liy6LSm5oi377yM6aKE5pyf5b6X5YiwIEVSUl9OT19QVwogICAgbGV0IHRlbXBDb25maWcgPSBDb25maWcoaG1hY0tleTogRGF0YShrZXlCeXRlcykuYmFzZTY0RW5jb2RlZFN0cmluZygpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAga2V5Y2hhaW5BY2NvdW50OiAiX19ibGV1bmxvY2tfc2VsZnRlc3Rfbm9uZXhpc3RlbnRfXyIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZXZpY2VOYW1lOiAiU0VMRlRFU1QiKQogICAgbGV0IGVuYyA9IEpTT05FbmNvZGVyKCkKICAgIGVuYy5vdXRwdXRGb3JtYXR0aW5nID0gWy5wcmV0dHlQcmludGVkLCAuc29ydGVkS2V5c10KICAgIHRyeT8gZW5jLmVuY29kZSh0ZW1wQ29uZmlnKS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga0NvbmZpZ1BhdGgpKQoKICAgIHZhciB1bmxvY2tSZXN1bHQgPSAiIgogICAgbGV0IHNlbSA9IERpc3BhdGNoU2VtYXBob3JlKHZhbHVlOiAwKQogICAgcGVyZm9ybVVubG9jayB7IHN0YXR1cyBpbgogICAgICAgIHVubG9ja1Jlc3VsdCA9IHN0YXR1cwogICAgICAgIHNlbS5zaWduYWwoKQogICAgfQogICAgXyA9IHNlbS53YWl0KHRpbWVvdXQ6IC5ub3coKSArIDIwKQogICAgZXhwZWN0KCLnvLrlsJHpkqXljJnkuLLlr4bnoIHml7bov5Tlm54gRVJSX05PX1BXIiwgdW5sb2NrUmVzdWx0ID09ICJFUlJfTk9fUFciLCAi5a6e6ZmFIFwodW5sb2NrUmVzdWx0KSIpCgogICAgcHJpbnQoKQogICAgaWYgZmFpbGVkID09IDAgewogICAgICAgIHByaW50KCLnu5Pmnpw6IOWFqOmDqOmAmui/hyDinJMiKQogICAgICAgIGV4aXQoMCkKICAgIH0gZWxzZSB7CiAgICAgICAgcHJpbnQoIue7k+aenDogXChmYWlsZWQpIOmhueWksei0pSDinJciKQogICAgICAgIGV4aXQoMSkKICAgIH0KfQoKLy8g5Y2P6K6u6Ieq5qOA77ya55So5Zu65a6a5rWL6K+V5a+G6ZKl5a+557uZ5a6a55qE5Y2B5YWt6L+b5Yi25raI5oGv6K6h566XIEhNQUPvvIzkvpvot6jor63oqIDmr5Tlr7nkvb/nlKgKaWYgbGV0IGlkeCA9IGFyZ3MuZmlyc3RJbmRleChvZjogIi0tc2VsZnRlc3QiKSwgaWR4ICsgMSA8IGFyZ3MuY291bnQgewogICAgbGV0IGhleFN0cmluZyA9IGFyZ3NbaWR4ICsgMV0KICAgIHZhciBtZXNzYWdlID0gRGF0YSgpCiAgICB2YXIgaSA9IGhleFN0cmluZy5zdGFydEluZGV4CiAgICB3aGlsZSBpIDwgaGV4U3RyaW5nLmVuZEluZGV4IHsKICAgICAgICBndWFyZCBsZXQgbmV4dCA9IGhleFN0cmluZy5pbmRleChpLCBvZmZzZXRCeTogMiwgbGltaXRlZEJ5OiBoZXhTdHJpbmcuZW5kSW5kZXgpIGVsc2UgeyBicmVhayB9CiAgICAgICAgbGV0IGJ5dGVTdHJpbmcgPSBoZXhTdHJpbmdbaS4uPG5leHRdCiAgICAgICAgZ3VhcmQgbGV0IGJ5dGUgPSBVSW50OChieXRlU3RyaW5nLCByYWRpeDogMTYpIGVsc2UgewogICAgICAgICAgICBGaWxlSGFuZGxlLnN0YW5kYXJkRXJyb3Iud3JpdGUoIuaXoOaViOeahOWNgeWFrei/m+WItui+k+WFpVxuIi5kYXRhKHVzaW5nOiAudXRmOCkhKQogICAgICAgICAgICBleGl0KDIpCiAgICAgICAgfQogICAgICAgIG1lc3NhZ2UuYXBwZW5kKGJ5dGUpCiAgICAgICAgaSA9IG5leHQKICAgIH0KICAgIC8vIOS4jiBBbmRyb2lkIOerryBWZXJpZnlQcm90b2NvbC5qYXZhIOS9v+eUqOWujOWFqOebuOWQjOeahOa1i+ivleWvhumSpe+8mjB4MDAsMHgwMSwuLi4sMHgxZgogICAgdmFyIGtleUJ5dGVzID0gW1VJbnQ4XSgpCiAgICBmb3IgbiBpbiAwLi48MzIgeyBrZXlCeXRlcy5hcHBlbmQoVUludDgobikpIH0KICAgIGxldCB0ZXN0S2V5ID0gU3ltbWV0cmljS2V5KGRhdGE6IERhdGEoa2V5Qnl0ZXMpKQogICAgbGV0IHRhZyA9IERhdGEoSE1BQzxTSEEyNTY+LmF1dGhlbnRpY2F0aW9uQ29kZShmb3I6IG1lc3NhZ2UsIHVzaW5nOiB0ZXN0S2V5KSkKICAgIHByaW50KHRhZy5tYXAgeyBTdHJpbmcoZm9ybWF0OiAiJTAyeCIsICQwKSB9LmpvaW5lZCgpKQogICAgZXhpdCgwKQp9CgppZiBhcmdzLmNvbnRhaW5zKCItLXByaW50LXRva2VuIikgewogICAgZ3VhcmQgbGV0IGNvbmZpZyA9IGxvYWRDb25maWcoKSBlbHNlIHsKICAgICAgICBwcmludCgi5bCa5pyq5Yid5aeL5YyW6YWN572u77yM6K+35YWI6L+Q6KGM5a6J6KOF6ISa5pys44CCIikKICAgICAgICBleGl0KDEpCiAgICB9CiAgICBwcmludChjb25maWcuaG1hY0tleSkKICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1hZGQtYWNjZXNzaWJpbGl0eSIpIHsKICAgIGxldCBvayA9IGFjY2Vzc2liaWxpdHlHcmFudGVkKHByb21wdDogdHJ1ZSkKICAgIHByaW50KG9rID8gIuW3suiOt+W+l+i+heWKqeWKn+iDveadg+mZkOOAgiIgOiAi5bey5by55Ye65o6I5p2D6K+35rGC77yM6K+35Zyo44CM57O757uf6K6+572uIOKGkiDpmpDnp4HkuI7lronlhajmgKcg4oaSIOi+heWKqeWKn+iDveOAjeS4reWLvumAiSBCTEVVbmxvY2tDbWTjgIIiKQogICAgZXhpdCgwKQp9CgovLyDnlLHlrojmiqTov5vnqIvoh6rlt7Hlj5HotbfjgIzovoXliqnlip/og73jgI3mjojmnYPor7fmsYLjgIIKLy8g55SoIHByb21wdDp0cnVlIOiuqeezu+e7n+W8ueWHuuaOiOadg+W8leWvvOW5tuaKiuiusOW9lee7keWumuWIsOacrOS6jOi/m+WItuOAggppZiBhcmdzLmNvbnRhaW5zKCItLXJlcXVlc3QtYWNjZXNzaWJpbGl0eSIpIHsKICAgIGxldCBrZXkgPSBrQVhUcnVzdGVkQ2hlY2tPcHRpb25Qcm9tcHQudGFrZVVucmV0YWluZWRWYWx1ZSgpIGFzIFN0cmluZwogICAgbGV0IHRydXN0ZWQgPSBBWElzUHJvY2Vzc1RydXN0ZWRXaXRoT3B0aW9ucyhba2V5OiB0cnVlXSBhcyBDRkRpY3Rpb25hcnkpCiAgICBpZiB0cnVzdGVkIHsKICAgICAgICBwcmludCgi5bey5o6I5p2D77yM5peg6ZyA5YaN5pON5L2c44CCIikKICAgIH0gZWxzZSB7CiAgICAgICAgcHJpbnQoIuW3suW8ueWHuuezu+e7n+aOiOadg+W8leWvvOOAgiIpCiAgICAgICAgcHJpbnQoIuWmguaenOezu+e7n+iuvue9rumHjOayoeacieiHquWKqOWHuueOsOadoeebru+8jOivt+WcqOOAjOi+heWKqeWKn+iDveOAjeWIl+ihqOS4reeCuSDvvIsg5re75Yqg77yaIikKICAgICAgICBwcmludChDb21tYW5kTGluZS5hcmd1bWVudHNbMF0pCiAgICAgICAgcHJpbnQoIiIpCiAgICAgICAgcHJpbnQoIuazqOaEj++8muWmguaenOWIl+ihqOmHjOW3suaciSBCTEVVbmxvY2tDbWQg5LiU5byA5YWz5piv5omT5byA55qE77yM5L2G5a+56ZKp5peg5pWI77yMIikKICAgICAgICBwcmludCgi6K+35YWI55So44CM4oiS44CN5Yig6Zmk5a6D77yM5YaN6YeN5paw5re75Yqg5LiA5qyh4oCU4oCU5pen5o6I5p2D5Y+v6IO957uR5a6a5LqG5pen54mI5pys55qE56iL5bqP44CCIikKICAgIH0KICAgIGV4aXQodHJ1c3RlZCA/IDAgOiAxKQp9CgovLyDpgJrnn6XmraPlnKjov5DooYznmoTlrojmiqTov5vnqIvliLfmlrDmnYPpmZDnirbmgIHmlofku7bjgIIKLy8g55So5oi35Zyo44CM57O757uf6K6+572u44CN6YeM5Yia5Yu+6YCJ5a6M5pe277yM6ZyA6KaB55So6L+Z5Liq56uL5Yi75pu05pawIGRhZW1vbi1zdGF0dXMuanNvbu+8jAovLyDlkKbliJnopoHnrYnliLDkuIvkuIDmrKHop6PplIHmiY3kvJrliLfmlrDjgIIKaWYgYXJncy5jb250YWlucygiLS1heC1yZWZyZXNoIikgewogICAgbGV0IHBheWxvYWQ6IFtTdHJpbmc6IFN0cmluZ10gPSBbImFjdGlvbiI6ICJyZWZyZXNoLWF4Il0KICAgIGlmIGxldCBkYXRhID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5kYXRhKHdpdGhKU09OT2JqZWN0OiBwYXlsb2FkKSB7CiAgICAgICAgdHJ5PyBkYXRhLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrUmVmcmVzaFJlcXVlc3RQYXRoKSkKICAgIH0KICAgIGV4aXQoMCkKfQoKLy8g5a6M5pW06K+K5pat77ya5oqKIui/meS4quWPr+aJp+ihjOaWh+S7tuiHquW3sSLnnIvliLDnmoTmnYPpmZDjgIHpkqXljJnkuLLjgIHplIHlsY/nirbmgIHlhajpg6jmiZPljbDlh7rmnaXjgIIKLy8g5LiOIC0tY2hlY2sg55qE5Yy65Yir5piv5a6D5ZCM5pe25oql5ZGK5pu057uG55qE5Yik5a6a5L6d5o2u77yM5L6/5LqO5Yy65YiG5pivIuadg+mZkOayoee7meWvuSIKLy8g6L+Y5pivIuWIq+eahOeOr+iKguWHuumXrumimCLjgIIKaWYgYXJncy5jb250YWlucygiLS1kaWFnIikgewogICAgbGV0IGJ1bmRsZUlEID0gQnVuZGxlLm1haW4uYnVuZGxlSWRlbnRpZmllciA/PyAiKOaXoCkiCiAgICBsZXQgZXhlID0gQ29tbWFuZExpbmUuYXJndW1lbnRzWzBdCiAgICBwcmludCgi5Y+v5omn6KGM5paH5Lu2IDogXChleGUpIikKICAgIHByaW50KCJCdW5kbGUgSUQgIDogXChidW5kbGVJRCkiKQogICAgcHJpbnQoIkJ1bmRsZSDot6/lvoQ6IFwoQnVuZGxlLm1haW4uYnVuZGxlUGF0aCkiKQogICAgcHJpbnQoIiIpCiAgICBsZXQgdHJ1c3RlZCA9IGFjY2Vzc2liaWxpdHlHcmFudGVkKCkKICAgIHByaW50KCJBWElzUHJvY2Vzc1RydXN0ZWQgOiBcKHRydXN0ZWQpIikKICAgIHByaW50KCIgIOKGkiDov5nkuIDpobnmmK8gVENDIOWvueacrOS6jOi/m+WItueahOWIpOWumu+8jOS4juOAjOezu+e7n+iuvue9ruOAjemHjOaYvuekuueahOS4gOiHtCIpCiAgICBwcmludCgiIikKICAgIGlmIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgewogICAgICAgIHByaW50KCLphY3nva4gICAgICAgOiDmraPluLjvvIjorr7lpIflkI0gXChjb25maWcuZGV2aWNlTmFtZSnvvIkiKQogICAgICAgIGlmIGxldCBwdyA9IGZldGNoUGFzc3dvcmQoYWNjb3VudDogY29uZmlnLmtleWNoYWluQWNjb3VudCkgewogICAgICAgICAgICBwcmludCgi6ZKl5YyZ5Liy5a+G56CBIDog5Y+v6K+75Y+W77yIXChwdy5jb3VudCkg5a2X56ym77yJIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBwcmludCgi6ZKl5YyZ5Liy5a+G56CBIDog6K+75Y+W5aSx6LSlIikKICAgICAgICB9CiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLphY3nva4gICAgICAgOiDnvLrlpLEiKQogICAgfQogICAgcHJpbnQoIuaYr+WQpumUgeWxjyAgIDogXChpc1NjcmVlbkxvY2tlZCgpID8gIuaYryIgOiAi5ZCmIikiKQogICAgcHJpbnQoIiIpCiAgICBwcmludCgi6Iul5LiK6Z2iIEFYSXNQcm9jZXNzVHJ1c3RlZCDkuLogZmFsc2XvvIzkvYbjgIzns7vnu5/orr7nva4g4oaSIOi+heWKqeWKn+iDveOAjemHjOW8gOWFs+aYr+aJk+W8gOeahO+8jCIpCiAgICBwcmludCgi6K+05piO6K+l6aG55o6I5p2D57uR5a6a55qE5piv5pen54mI5pys5LqM6L+b5Yi244CC6K+35Zyo6K+l5YiX6KGo6YeM5Yig6ZmkIEJMRVVubG9ja0NtZO+8jCIpCiAgICBwcmludCgi54S25ZCO6YeN5paw6L+Q6KGM6K6+572u5ZCR5a+85re75Yqg5LiA5qyh44CCIikKICAgIGV4aXQodHJ1c3RlZCA/IDAgOiAxKQp9CgovLyDkvpvlronoo4XohJrmnKzmn6Xor6LmnYPpmZDnirbmgIHjgILlv4XpobvnlLEgQXBwIGJ1bmRsZSDlhoXov5nkuKrlj6/miafooYzmlofku7boh6rlt7HmiqXlkYrvvIwKLy8g5Zug5Li644CM6L6F5Yqp5Yqf6IO944CN5p2D6ZmQ5piv5oyJ5LqM6L+b5Yi277yIVENDIOS4u+S9k++8ieaOiOS6iOeahO+8muWPpue8luS4gOS4quaOoua1i+Wwj+eoi+W6j+WOu+afpe+8jAovLyDlvpfliLDnmoTmmK/pgqPkuKrnqIvluo/oh6rlt7HnmoTmnYPpmZDvvIzkvJrmsLjov5zmmK/jgIzmnKrmjojmnYPjgI3igJTigJTov5nmraPmmK/kuYvliY3nmoTor6/miqXmnaXmupDjgIIKaWYgYXJncy5jb250YWlucygiLS1heC1zdGF0dXMiKSB7CiAgICBleGl0KGFjY2Vzc2liaWxpdHlHcmFudGVkKCkgPyAwIDogMSkKfQoKaWYgYXJncy5jb250YWlucygiLS1jaGVjayIpIHsKICAgIGd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICAgICAgcHJpbnQoIumFjee9rjog57y65aSx77yIXChrQ29uZmlnUGF0aCnvvIkiKQogICAgICAgIGV4aXQoMSkKICAgIH0KICAgIHByaW50KCLphY3nva46IOato+W4uCIpCiAgICBwcmludCgi6K6+5aSH5ZCNOiBcKGNvbmZpZy5kZXZpY2VOYW1lKSIpCiAgICBwcmludCgi6ZKl5YyZ5Liy6LSm5oi3OiBcKGNvbmZpZy5rZXljaGFpbkFjY291bnQpIikKICAgIHByaW50KCLovoXliqnlip/og73mnYPpmZA6IFwoYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSA/ICLlt7LmjojmnYMiIDogIuacquaOiOadg++8iOino+mUgeS8muWksei0pe+8iSIpIikKICAgIGlmIGxldCBwdyA9IGZldGNoUGFzc3dvcmQoYWNjb3VudDogY29uZmlnLmtleWNoYWluQWNjb3VudCkgewogICAgICAgIHByaW50KCLnmbvlvZXlr4bnoIE6IOW3suWtmOWFpemSpeWMmeS4su+8iFwocHcuY291bnQpIOS4quWtl+espu+8iSIpCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLnmbvlvZXlr4bnoIE6IOacquaJvuWIsCIpCiAgICB9CiAgICBwcmludCgi5b2T5YmN5piv5ZCm6ZSB5bGPOiBcKGlzU2NyZWVuTG9ja2VkKCkgPyAi5pivIiA6ICLlkKYiKSIpCiAgICBwcmludCgiIikKICAgIHByaW50KCLilIDilIAg5a6I5oqk6L+b56iL5a6e6ZmF54q25oCB77yI5Yaz5a6a6Kej6ZSB6IO95ZCm5oiQ5Yqf77yJ4pSA4pSAIikKICAgIC8vIOazqOaEj++8muacrOi/m+eoi+S7jue7iOerr+WQr+WKqOaXtuWPr+iDvee7p+aJv+S6hue7iOerr+eahCBBWCDkv6Hku7vvvIzlm6DmraTkuIrpnaLpgqPkuIDpobkKICAgIC8vIOacquW/heS7o+ihqOecn+ato+W5sua0u+eahOWuiOaKpOi/m+eoi+OAguecn+WunueKtuaAgeS7peWuiOaKpOi/m+eoi+iHquW3seiQveebmOeahOWGheWuueS4uuWHhuOAggogICAgaWYgbGV0IGRhdGEgPSBGaWxlTWFuYWdlci5kZWZhdWx0LmNvbnRlbnRzKGF0UGF0aDoga1N0YXR1c1BhdGgpLAogICAgICAgbGV0IG9iaiA9IHRyeT8gSlNPTlNlcmlhbGl6YXRpb24uanNvbk9iamVjdCh3aXRoOiBkYXRhKSBhcz8gW1N0cmluZzogQW55XSB7CiAgICAgICAgbGV0IGF4ID0gKG9ialsiYXhUcnVzdGVkIl0gYXM/IEJvb2wpID8/IGZhbHNlCiAgICAgICAgbGV0IHBpZCA9IG9ialsicGlkIl0gYXM/IEludCA/PyAtMQogICAgICAgIGxldCBhdCA9IG9ialsidXBkYXRlZEF0Il0gYXM/IFN0cmluZyA/PyAiPyIKICAgICAgICBwcmludCgi5a6I5oqk6L+b56iLIEFYIOadg+mZkDogXChheCA/ICLlt7LmjojmnYMg4pyTIiA6ICLmnKrmjojmnYMg4pyXIikiKQogICAgICAgIHByaW50KCIgIOiusOW9leaXtumXtDogXChhdCkgIFBJRDogXChwaWQpIikKICAgICAgICBpZiAhYXggewogICAgICAgICAgICBwcmludCgiICDihpIg6Kej6ZSB5Lya5aSx6LSl44CC6K+35Zyo44CM57O757uf6K6+572uIOKGkiDpmpDnp4HkuI7lronlhajmgKcg4oaSIOi+heWKqeWKn+iDveOAjSIpCiAgICAgICAgICAgIHByaW50KCIgICAgIOS4reWLvumAiSBCTEVVbmxvY2tDbWTvvJvoi6XlvIDlhbPlt7LmiZPlvIDvvIzor7flhYjliKDpmaTor6Xpobnlho3ph43mlrDmt7vliqDjgIIiKQogICAgICAgIH0KICAgIH0gZWxzZSB7CiAgICAgICAgcHJpbnQoIuWuiOaKpOi/m+eoiyBBWCDmnYPpmZA6IOacquefpe+8iOWuiOaKpOi/m+eoi+WwmuacquWGmei/h+eKtuaAge+8jOWPr+iDveacqui/kOihjO+8iSIpCiAgICB9CiAgICBleGl0KDApCn0KCi8vIC0tc2V0LWtleQppZiBsZXQgaWR4ID0gYXJncy5maXJzdEluZGV4KG9mOiAiLS1zZXQta2V5IiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIGxldCBuZXdLZXkgPSBhcmdzW2lkeCArIDFdCiAgICBndWFyZCBEYXRhKGJhc2U2NEVuY29kZWQ6IG5ld0tleSk/LmNvdW50ID09IDMyIGVsc2UgewogICAgICAgIHByaW50KCLplJnor6/vvJrlr4bpkqXlv4XpobvmmK8gMzIg5a2X6IqC55qEIGJhc2U2NCDnvJbnoIHlrZfnrKbkuLLjgIIiKQogICAgICAgIGV4aXQoMSkKICAgIH0KICAgIHZhciBjb25maWcgPSBsb2FkQ29uZmlnKCkgPz8gQ29uZmlnKGhtYWNLZXk6IG5ld0tleSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtleWNoYWluQWNjb3VudDogTlNVc2VyTmFtZSgpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZGV2aWNlTmFtZTogSG9zdC5jdXJyZW50KCkubG9jYWxpemVkTmFtZSA/PyAiTWFjIikKICAgIGNvbmZpZy5obWFjS2V5ID0gbmV3S2V5CiAgICBsZXQgZW5jb2RlciA9IEpTT05FbmNvZGVyKCkKICAgIGVuY29kZXIub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuY29kZXIuZW5jb2RlKGNvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5zZXRBdHRyaWJ1dGVzKFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdLCBvZkl0ZW1BdFBhdGg6IGtDb25maWdQYXRoKQogICAgcHJpbnQoIuW3suabtOaWsOmFjeWvueWvhumSpe+8jOivt+WcqOaJi+acuiBBcHAg5Lit5ZCM5q2l5L+u5pS544CCIikKICAgIGV4aXQoMCkKfQoKLy8gLS1zaG93LXRva2Vu77ya5omT5Y2w5b2T5YmN5a+G6ZKl77yb5pyq5a6J6KOF5pe255Sf5oiQ5LiA5Liq5Li05pe25a+G6ZKl77yI6YWN5ZCIIC0tZHJ5LXJ1biDmtYvor5XnlKjvvIkKaWYgYXJncy5jb250YWlucygiLS1zaG93LXRva2VuIikgewogICAgaWYgbGV0IGNvbmZpZyA9IGxvYWRDb25maWcoKSB7CiAgICAgICAgcHJpbnQoY29uZmlnLmhtYWNLZXkpCiAgICB9IGVsc2UgewogICAgICAgIHZhciBieXRlcyA9IFtVSW50OF0ocmVwZWF0aW5nOiAwLCBjb3VudDogMzIpCiAgICAgICAgZm9yIGkgaW4gMC4uPDMyIHsgYnl0ZXNbaV0gPSBVSW50OC5yYW5kb20oaW46IDAuLi4yNTUpIH0KICAgICAgICBwcmludChEYXRhKGJ5dGVzKS5iYXNlNjRFbmNvZGVkU3RyaW5nKCkpCiAgICB9CiAgICBleGl0KDApCn0KCmlmIGFyZ3MuY29udGFpbnMoIi0tZHJ5LXJ1biIpIHsKICAgIGRyeVJ1biA9IHRydWUKfQoKLy8g5rWL6K+V5qih5byP5LiU5rKh5pyJ5q2j5byP6YWN572u5pe277yM55So5Li05pe25a+G6ZKlICsg5Li05pe26LSm5oi377yM5pa55L6/5Zyo5pyq5a6J6KOF55qE5py65Zmo5LiK6aqM6K+BCmlmIGRyeVJ1biAmJiBsb2FkQ29uZmlnKCkgPT0gbmlsIHsKICAgIHZhciBieXRlcyA9IFtVSW50OF0ocmVwZWF0aW5nOiAwLCBjb3VudDogMzIpCiAgICBmb3IgaSBpbiAwLi48MzIgeyBieXRlc1tpXSA9IFVJbnQ4LnJhbmRvbShpbjogMC4uLjI1NSkgfQogICAgbGV0IHRlbXBDb25maWcgPSBDb25maWcoaG1hY0tleTogRGF0YShieXRlcykuYmFzZTY0RW5jb2RlZFN0cmluZygpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAga2V5Y2hhaW5BY2NvdW50OiBOU1VzZXJOYW1lKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZXZpY2VOYW1lOiAiQkxFVW5sb2NrLURSWVJVTiIpCiAgICBsZXQgZW5jb2RlciA9IEpTT05FbmNvZGVyKCkKICAgIGVuY29kZXIub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuY29kZXIuZW5jb2RlKHRlbXBDb25maWcpLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrQ29uZmlnUGF0aCkpCiAgICB0cnk/IEZpbGVNYW5hZ2VyLmRlZmF1bHQuc2V0QXR0cmlidXRlcyhbLnBvc2l4UGVybWlzc2lvbnM6IDBvNjAwXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIG9mSXRlbUF0UGF0aDoga0NvbmZpZ1BhdGgpCiAgICBsb2coImRyeS1ydW7vvJrlt7LnlJ/miJDkuLTml7bphY3nva4gXChrQ29uZmlnUGF0aCkiKQp9CgpndWFyZCBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIGVsc2UgewogICAgcHJpbnQoIumUmeivr++8muaJvuS4jeWIsOmFjee9ruaWh+S7tiBcKGtDb25maWdQYXRoKSIpCiAgICBwcmludCgi6K+35YWI6L+Q6KGMIG1hYy1ibGUtdW5sb2NrLnNoIGluc3RhbGwg5a6M5oiQ5Yid5aeL5YyW44CCIikKICAgIGV4aXQoMSkKfQoKZ3VhcmQgbGV0IGtleURhdGEgPSBEYXRhKGJhc2U2NEVuY29kZWQ6IGNvbmZpZy5obWFjS2V5KSwga2V5RGF0YS5jb3VudCA9PSAzMiBlbHNlIHsKICAgIHByaW50KCLplJnor6/vvJrphY3nva7mlofku7bkuK3nmoQgaG1hY0tleSDml6DmlYjjgIIiKQogICAgZXhpdCgxKQp9CgppZiBsZXQgaWR4ID0gYXJncy5maXJzdEluZGV4KG9mOiAiLS1kZXZpY2UtbmFtZSIpLCBpZHggKyAxIDwgYXJncy5jb3VudCB7CiAgICB2YXIgdXBkYXRlZCA9IGNvbmZpZwogICAgdXBkYXRlZC5kZXZpY2VOYW1lID0gYXJnc1tpZHggKyAxXQogICAgbGV0IGVuY29kZXIgPSBKU09ORW5jb2RlcigpCiAgICBlbmNvZGVyLm91dHB1dEZvcm1hdHRpbmcgPSBbLnByZXR0eVByaW50ZWQsIC5zb3J0ZWRLZXlzXQogICAgdHJ5PyBlbmNvZGVyLmVuY29kZSh1cGRhdGVkKS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga0NvbmZpZ1BhdGgpKQogICAgcHJpbnQoIuiuvuWkh+WQjeW3suabtOaWsOS4uiBcKHVwZGF0ZWQuZGV2aWNlTmFtZSkiKQogICAgZXhpdCgwKQp9CgpsZXQgc3ltbWV0cmljS2V5ID0gU3ltbWV0cmljS2V5KGRhdGE6IGtleURhdGEpCgppZiAhYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSB7CiAgICBsb2coIuitpuWRiu+8muWwmuacquiOt+W+l+OAjOi+heWKqeWKn+iDveOAjeadg+mZkO+8jOino+mUgeS4jeS8mueUn+aViOOAgiIpCiAgICBsb2coIuivt+i/kOihjO+8mkJMRVVubG9ja0NtZCAtLWFkZC1hY2Nlc3NpYmlsaXR5IikKfQoKbG9nKCLlkK/liqggQkxFVW5sb2NrQ21k77yM6K6+5aSH5ZCN44CMXChjb25maWcuZGV2aWNlTmFtZSnjgI0iKQoKLy8g5oqK5pys6L+b56iL77yI5a6I5oqk6L+b56iL77yJ6Ieq6Lqr55qE5p2D6ZmQ5Yik5a6a6JC955uY77yM5L6b6K6+572u5ZCR5a+86K+75Y+W44CCCi8vIOi/meS4gOmhueaJjeaYr+WGs+WumiLop6PplIHog73lkKbmiJDlip8i55qE55yf5a6e54q25oCB44CCCndyaXRlRGFlbW9uU3RhdHVzKCkKCmxldCBzZXJ2ZXIgPSBQZXJpcGhlcmFsU2VydmVyKCkKc2VydmVyLnN0YXJ0KGtleTogc3ltbWV0cmljS2V5LCBkZXZpY2VOYW1lOiBjb25maWcuZGV2aWNlTmFtZSkKCi8vIOmYsuatouezu+e7n+epuumXsuS8keecoO+8muS8keecoOS8muWBnOaOieiTneeJmeW5v+aSre+8jOaJi+acuuWwseWGjeS5n+i/nuS4jeS4iuS6hgp2YXIgc2xlZXBBc3NlcnRpb24gPSBJT1BNQXNzZXJ0aW9uSUQoMCkKbGV0IGFzc2VydGlvblJlc3VsdCA9IElPUE1Bc3NlcnRpb25DcmVhdGVXaXRoTmFtZShrSU9QTUFzc2VydGlvblR5cGVOb0lkbGVTbGVlcCBhcyBDRlN0cmluZywKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIElPUE1Bc3NlcnRpb25MZXZlbChrSU9QTUFzc2VydGlvbkxldmVsT24pLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIkJMRVVubG9ja0NtZCDkv53mjIHok53niZnlj6/ov57mjqUiIGFzIENGU3RyaW5nLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgJnNsZWVwQXNzZXJ0aW9uKQppZiBhc3NlcnRpb25SZXN1bHQgPT0ga0lPUmV0dXJuU3VjY2VzcyB7CiAgICBsb2coIuW3sumYu+atouezu+e7n+epuumXsuS8keecoO+8jOS7peS/neaMgeiTneeJmeWPr+i/nuaOpe+8iOaYvuekuuWZqOS7jeS8muato+W4uOaBr+Wxj++8iSIpCn0gZWxzZSB7CiAgICBsb2coIuitpuWRiu+8muaXoOazleWIm+W7uumYsuS8keecoOaWreiogO+8jOezu+e7n+S8keecoOWQjuiTneeJmeWwhuaWreW8gCIpCn0KCi8vIOi/m+eoi+mAgOWHuuaXtumHiuaUvuaWreiogApmdW5jIGNsZWFudXAoKSB7CiAgICBpZiBzbGVlcEFzc2VydGlvbiAhPSAwIHsKICAgICAgICBJT1BNQXNzZXJ0aW9uUmVsZWFzZShzbGVlcEFzc2VydGlvbikKICAgICAgICBzbGVlcEFzc2VydGlvbiA9IDAKICAgIH0KICAgIGxvZygiQkxFVW5sb2NrQ21kIOmAgOWHuiIpCn0KCnNpZ25hbChTSUdJTlQsIFNJR19JR04pCnNpZ25hbChTSUdURVJNLCBTSUdfSUdOKQpsZXQgc2lnaW50U291cmNlID0gRGlzcGF0Y2hTb3VyY2UubWFrZVNpZ25hbFNvdXJjZShzaWduYWw6IFNJR0lOVCwgcXVldWU6IC5tYWluKQpzaWdpbnRTb3VyY2Uuc2V0RXZlbnRIYW5kbGVyIHsgbG9nKCLmlLbliLAgU0lHSU5U77yM6YCA5Ye6Iik7IGNsZWFudXAoKTsgZXhpdCgwKSB9CnNpZ2ludFNvdXJjZS5yZXN1bWUoKQpsZXQgc2lndGVybVNvdXJjZSA9IERpc3BhdGNoU291cmNlLm1ha2VTaWduYWxTb3VyY2Uoc2lnbmFsOiBTSUdURVJNLCBxdWV1ZTogLm1haW4pCnNpZ3Rlcm1Tb3VyY2Uuc2V0RXZlbnRIYW5kbGVyIHsgbG9nKCLmlLbliLAgU0lHVEVSTe+8jOmAgOWHuiIpOyBjbGVhbnVwKCk7IGV4aXQoMCkgfQpzaWd0ZXJtU291cmNlLnJlc3VtZSgpCgovLyDnm5Hop4bliLfmlrDor7fmsYLvvJrorr7nva7lkJHlr7zlnKjnlKjmiLflrozmiJDmjojmnYPlkI7lhpnlhaXor6Xmlofku7bvvIwKLy8g5a6I5oqk6L+b56iL5o2u5q2k56uL5Yi75Yi35pawIGRhZW1vbi1zdGF0dXMuanNvbu+8jOaXoOmcgOmHjeWQr+acjeWKoeOAggpsZXQgcmVmcmVzaFRpbWVyID0gVGltZXIuc2NoZWR1bGVkVGltZXIod2l0aFRpbWVJbnRlcnZhbDogMS4wLCByZXBlYXRzOiB0cnVlKSB7IF8gaW4KICAgIGxldCBmbSA9IEZpbGVNYW5hZ2VyLmRlZmF1bHQKICAgIGd1YXJkIGZtLmZpbGVFeGlzdHMoYXRQYXRoOiBrUmVmcmVzaFJlcXVlc3RQYXRoKSBlbHNlIHsgcmV0dXJuIH0KICAgIHRyeT8gZm0ucmVtb3ZlSXRlbShhdFBhdGg6IGtSZWZyZXNoUmVxdWVzdFBhdGgpCiAgICBsb2coIuaUtuWIsOadg+mZkOWIt+aWsOivt+axgiIpCiAgICB3cml0ZURhZW1vblN0YXR1cygpCiAgICBsb2coIuadg+mZkOeKtuaAgeW3suabtOaWsO+8jOaJi+acuuerr+S8mueri+WNs+eci+WIsOacgOaWsOe7k+aenCIpCn0KUnVuTG9vcC5tYWluLmFkZChyZWZyZXNoVGltZXIsIGZvck1vZGU6IC5jb21tb24pCgpSdW5Mb29wLm1haW4ucnVuKCkK
__SWIFT_SOURCE_END__
