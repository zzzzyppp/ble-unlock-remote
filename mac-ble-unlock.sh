#!/bin/bash
#
# mac-ble-unlock.sh — 在 Mac 上安装/运行蓝牙解锁服务
#
# 用法:
#   ./mac-ble-unlock.sh install      安装（编译 + 配置 + 注册开机自启）
#   ./mac-ble-unlock.sh token        显示配对令牌（在手机 App 里填写）
#   ./mac-ble-unlock.sh set-password 把登录密码存入钥匙串
#   ./mac-ble-unlock.sh passwords list    查看已保存的多个密码
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

# 该版本的服务端是否支持 --passwords 子命令。
# 不支持时直接调用会被当成启动参数而**常驻运行**，留下孤儿进程。
service_supports_passwords() {
    local caps="$APP_BUNDLE/Contents/Resources/capabilities"
    [ -f "$caps" ] && grep -q 'passwords' "$caps" 2>/dev/null
}

cmd_passwords() {
    [ -x "$APP_BIN" ] || die "尚未安装，请先运行：$0 install"
    if ! service_supports_passwords; then
        warn "当前服务端版本不支持多密码管理。"
        echo "  请重新运行安装包（或 $0 install）升级后再试。"
        exit 1
    fi
    shift   # 去掉 "passwords"
    "$APP_BIN" --passwords "$@"
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
    passwords)     cmd_passwords "$@" ;;
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
Ly8gQkxFVW5sb2NrQ21kIOKAlCBNYWMgQkxFIOino+mUgeacjeWKoeerrwovLwovLyDkvZznlKjvvJrkvZzkuLogQkxFIOWkluiuvihHQVRUIFNlcnZlcinlub/mkq3vvIzmiYvmnLogQXBwIOi/nuaOpeWQjuWGmeWFpeS4gOadoeW4piBITUFDLVNIQTI1NiDnrb7lkI3nmoQKLy8gICAgICAg5oyH5Luk77yb5qCh6aqM6YCa6L+H5YiZ6LCD55So5LiOIEJMRVVubG9jayDnm7jlkIznmoTmnLrliLboh6rliqjovpPlhaXnmbvlvZXlr4bnoIHmnaXop6PplIHlsY/luZXjgIIKLy8KLy8g57yW6K+R77yac3dpZnRjIC1PIG1haW4uc3dpZnQgLW8gQkxFVW5sb2NrQ21kCi8vIOS+nei1lu+8mkNvcmVCbHVldG9vdGggLyBDcnlwdG9LaXQgLyBDb3JlR3JhcGhpY3MgLyBJT0tpdO+8iOWFqOmDqOS4uuezu+e7n+ahhuaetu+8iQoKaW1wb3J0IEZvdW5kYXRpb24KaW1wb3J0IENvcmVCbHVldG9vdGgKaW1wb3J0IENyeXB0b0tpdAppbXBvcnQgQ29yZUdyYXBoaWNzCmltcG9ydCBEYXJ3aW4KaW1wb3J0IElPS2l0LnB3cl9tZ3QKaW1wb3J0IEFwcGxpY2F0aW9uU2VydmljZXMKCi8vIE1BUks6IC0g5Y2P6K6u5bi46YeP77yI5b+F6aG75LiOIEFuZHJvaWQg56uv5LiA6Ie077yJCgpsZXQga1NlcnZpY2VVVUlEICAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAxLTRBMDAtODAwMC0wMDgwNUY5QjAwMDEiKQpsZXQga0NoYXJDb21tYW5kVVVJRCAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAyLTRBMDAtODAwMC0wMDgwNUY5QjAwMDIiKQpsZXQga0NoYXJTdGF0dXNVVUlEICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAzLTRBMDAtODAwMC0wMDgwNUY5QjAwMDMiKQpsZXQga0NoYXJJbmZvVVVJRCAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDA0LTRBMDAtODAwMC0wMDgwNUY5QjAwMDQiKQoKbGV0IGtNYWdpYzogW1VJbnQ4XSA9IFsweDQyLCAweDU1XSAgICAgICAgICAvLyAiQlUiCmxldCBrVmVyc2lvbjogVUludDggPSAweDAxCmxldCBrQ21kVW5sb2NrOiBVSW50OCA9IDB4MDEKbGV0IGtDbWRMb2NrOiBVSW50OCA9IDB4MDIKbGV0IGtDbWRQaW5nOiBVSW50OCA9IDB4MDMKLy8vIOaMh+WumueUqOesrOWHoOS4quWvhueggeino+mUge+8iOaJi+acuuerr+mAieaLqSLloavlhYXlk6rkuKrlr4bnoIEi77yJCmxldCBrQ21kVW5sb2NrRnJvbTogVUludDggPSAweDA0CgpsZXQga1BhY2tldExlbiAgPSA2MiAgICAgICAgICAgICAgICAgICAgICAgIC8vIDIgbWFnaWMgKyAxIHZlciArIDEgY21kICsgOCB0cyArIDE2IG5vbmNlICsgMzIgaG1hYwpsZXQga0htYWNPZmZzZXQgPSAzMCAgICAgICAgICAgICAgICAgICAgICAgIC8vIEhNQUMg6KaG55uW5YmNIDMwIOWtl+iKggovLy8g5a2X6IqCIDI477ya5a+G56CB5bqP5Y+377yIMCDln7rvvInjgILku4Uga0NtZFVubG9ja0Zyb20g5L2/55So77yb5L2N5LqOIEhNQUMg6KaG55uW6IyD5Zu05YaF77yM6ZW/5bqm5LiN5Y+Y44CCCmxldCBrSW5kZXhPZmZzZXQgPSAyOAovLy8g5a2X6IqCIDI577ya5piv5ZCm6Lez6L+HIumUgeWxj+agoemqjCLjgIIKLy8vCi8vLyDmiYvmnLrnq6/jgIzloavlhYXlr4bnoIHjgI3mmK/kurrlt6XmmI7noa7kuIvovr7nmoTmjIfku6TvvIzkuI3pnIDopoHlho3liKTmlq3lsY/luZXmmK/lkKblpITkuo7plIHlrprnirbmgIHigJTigJQKLy8vIOeUqOaIt+WwseaYr+imgeeOsOWcqOaKiui/meS6m+Wtl+espumAgei/m+WOu+OAgue9riAxIOaXtiBNYWMg5Lya55u05o6l5rOo5YWl77yM5LiN5Zug5pyq6ZSB5bGP6ICM5Lit5q2i44CCCi8vLyDlkIzmoLfkvY3kuo4gSE1BQyDopobnm5bojIPlm7TlhoXjgIIKbGV0IGtGb3JjZU9mZnNldCA9IDI5CgpsZXQga1RpbWVzdGFtcFNrZXc6IEludDY0ID0gMTIwICAgICAgICAgICAgIC8vIOWFgeiuuOeahOaXtumSn+WBj+W3ru+8iOenku+8iQpsZXQga05vbmNlQ2FjaGVMaW1pdCA9IDUxMgoKLy8gTUFSSzogLSDov5DooYznjq/looPot6/lvoQKLy8KLy8g6buY6K6k5L2/55SoIH4vTGlicmFyeS9BcHBsaWNhdGlvbiBTdXBwb3J0L0JMRVVubG9ja0NtZOOAggovLyDnjq/looPlj5jph48gQkxFVU5MT0NLX0FQUF9TVVBQT1JUIOWPr+imhuebluivpeebruW9le+8iOa1i+ivlS/mspnnrrHnjq/looPnlKjvvInjgIIKCmxldCBrQXBwU3VwcG9ydDogU3RyaW5nID0gewogICAgaWYgbGV0IG92ZXJyaWRlID0gUHJvY2Vzc0luZm8ucHJvY2Vzc0luZm8uZW52aXJvbm1lbnRbIkJMRVVOTE9DS19BUFBfU1VQUE9SVCJdLAogICAgICAgIW92ZXJyaWRlLmlzRW1wdHkgewogICAgICAgIHJldHVybiBvdmVycmlkZQogICAgfQogICAgcmV0dXJuICgifi9MaWJyYXJ5L0FwcGxpY2F0aW9uIFN1cHBvcnQvQkxFVW5sb2NrQ21kIiBhcyBOU1N0cmluZykuZXhwYW5kaW5nVGlsZGVJblBhdGgKfSgpCmxldCBrQ29uZmlnUGF0aCA9IGtBcHBTdXBwb3J0ICsgIi9jb25maWcuanNvbiIKbGV0IGtMb2dQYXRoICAgID0ga0FwcFN1cHBvcnQgKyAiL2JsZS11bmxvY2subG9nIgovLy8g6ZKl5YyZ5Liy5pyN5Yqh5ZCN44CC5Y+v55So546v5aKD5Y+Y6YeP6KaG55uW77yM5L6/5LqO6Ieq5Yqo5YyW5rWL6K+V55So54us56uL5p2h55uu6aqM6K+B44CCCmxldCBrS2V5Y2hhaW5TZXJ2aWNlOiBTdHJpbmcgPSB7CiAgICBpZiBsZXQgbyA9IFByb2Nlc3NJbmZvLnByb2Nlc3NJbmZvLmVudmlyb25tZW50WyJCTEVVTkxPQ0tfS0VZQ0hBSU5fU0VSVklDRSJdLCAhby5pc0VtcHR5IHsKICAgICAgICByZXR1cm4gbwogICAgfQogICAgcmV0dXJuICJibGUtdW5sb2NrLWNtZCIKfSgpCi8vLyDlrojmiqTov5vnqIvmioroh6rlt7HnmoQgVENDIOadg+mZkOeKtuaAgeWGmeWcqOi/memHjO+8jOS+m+iuvue9ruWQkeWvvOivu+WPluOAggovLy8KLy8vIOS4uuS7gOS5iOS4jeebtOaOpemXrui/m+eoi++8mlRDQyDnmoQgQVgg5L+h5Lu75Lya5LuO54i26L+b56iL57un5om/44CC6K6+572u5ZCR5a+85LuOIEZpbmRlci/nu4jnq68KLy8vIOWQr+WKqOaXtuacrOi6q+aYr+WPl+S/oeS7u+eahO+8jOWugyBmb3JrIOWHuuadpeeahOWtkOi/m+eoi+S5n+S8muaKpeWRiuOAjOW3suaOiOadg+OAjeKAlOKAlAovLy8g5L2G55yf5q2j5bmy5rS755qE5a6I5oqk6L+b56iL55SxIGxhdW5jaGQg5ZCv5Yqo77yM5LiN5Y+X5q2k5L+h5Lu777yM5a6e6ZmF5piv5pyq5o6I5p2D44CCCi8vLyDlm6DmraTlv4XpobvorqnlrojmiqTov5vnqIvoh6rlt7HmiorliKTlrprnu5PmnpzokL3nm5jjgIIKbGV0IGtTdGF0dXNQYXRoID0ga0FwcFN1cHBvcnQgKyAiL2RhZW1vbi1zdGF0dXMuanNvbiIKLy8vIOWklumDqOivt+axguWIt+aWsOadg+mZkOeKtuaAgeeahOS/oeWPt+aWh+S7tu+8iOiuvue9ruWQkeWvvOWcqOeUqOaIt+aOiOadg+WQjuWGmeWFpe+8iQpsZXQga1JlZnJlc2hSZXF1ZXN0UGF0aCA9IGtBcHBTdXBwb3J0ICsgIi9yZWZyZXNoLnJlcXVlc3QiCgovLy8g5pel5b+X5paH5Lu25piv5ZCm5Y+v55So77yI55uu5b2V5LiN5Y+v5YaZ5pe26YCA5YyW5Li65Y+q6L6T5Ye65YiwIHN0ZGVycu+8iQpsZXQga0xvZ0ZpbGVXcml0YWJsZTogQm9vbCA9IHsKICAgIEZpbGVNYW5hZ2VyLmRlZmF1bHQuY3JlYXRlRmlsZShhdFBhdGg6IGtMb2dQYXRoLCBjb250ZW50czogbmlsLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGF0dHJpYnV0ZXM6IFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdKQogICAgcmV0dXJuIEZpbGVNYW5hZ2VyLmRlZmF1bHQuaXNXcml0YWJsZUZpbGUoYXRQYXRoOiBrTG9nUGF0aCkKfSgpCgovLyBNQVJLOiAtIOaXpeW/lwoKbGV0IGxvZ0Zvcm1hdHRlcjogRGF0ZUZvcm1hdHRlciA9IHsKICAgIGxldCBmID0gRGF0ZUZvcm1hdHRlcigpCiAgICBmLmRhdGVGb3JtYXQgPSAieXl5eS1NTS1kZCBISDptbTpzcyIKICAgIHJldHVybiBmCn0oKQoKLy8vIOiusOW9leWuiOaKpOi/m+eoi+iHqui6q+eahCBUQ0Mg5p2D6ZmQ54q25oCB77yM5L6b6K6+572u5ZCR5a+85Yik5patIuecn+ato+W5sua0u+eahOi/m+eoiyLog73lkKbovpPlhaXjgIIKZnVuYyB3cml0ZURhZW1vblN0YXR1cygpIHsKICAgIGxldCB0cnVzdGVkID0gYWNjZXNzaWJpbGl0eUdyYW50ZWQoKQogICAgbGV0IHBheWxvYWQ6IFtTdHJpbmc6IEFueV0gPSBbCiAgICAgICAgInBpZCI6IEludChnZXRwaWQoKSksCiAgICAgICAgImF4VHJ1c3RlZCI6IHRydXN0ZWQsCiAgICAgICAgInVwZGF0ZWRBdCI6IElTTzg2MDFEYXRlRm9ybWF0dGVyKCkuc3RyaW5nKGZyb206IERhdGUoKSksCiAgICAgICAgImJ1bmRsZVBhdGgiOiBCdW5kbGUubWFpbi5idW5kbGVQYXRoLAogICAgXQogICAgaWYgbGV0IGRhdGEgPSB0cnk/IEpTT05TZXJpYWxpemF0aW9uLmRhdGEod2l0aEpTT05PYmplY3Q6IHBheWxvYWQsIG9wdGlvbnM6IFsucHJldHR5UHJpbnRlZF0pIHsKICAgICAgICB0cnk/IGRhdGEud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtTdGF0dXNQYXRoKSkKICAgICAgICB0cnk/IEZpbGVNYW5hZ2VyLmRlZmF1bHQuc2V0QXR0cmlidXRlcyhbLnBvc2l4UGVybWlzc2lvbnM6IDBvNjAwXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBvZkl0ZW1BdFBhdGg6IGtTdGF0dXNQYXRoKQogICAgfQogICAgbG9nKCLlrojmiqTov5vnqIvmnYPpmZDoh6rmo4DvvJpBWElzUHJvY2Vzc1RydXN0ZWQgPSBcKHRydXN0ZWQpIikKICAgIGlmICF0cnVzdGVkIHsKICAgICAgICBsb2coIiAg4pqg77iPIOacrOi/m+eoi+aXoOazleaooeaLn+mUruebmOi+k+WFpe+8jOino+mUgeS8muWksei0peOAgiIpCiAgICAgICAgbG9nKCIgICAgIOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDovoXliqnlip/og73jgI3kuK3li77pgIkgQkxFVW5sb2NrQ21k77ybIikKICAgICAgICBsb2coIiAgICAg6Iul5byA5YWz5bey5piv5omT5byA54q25oCB77yM6K+35YWI5Yig6Zmk6K+l6aG55YaN6YeN5paw5re75Yqg77yI5pen5o6I5p2D5Y+v6IO957uR5a6a5Yiw5pen54mI5pys77yJ44CCIikKICAgIH0KfQoKZnVuYyBsb2coXyBtZXNzYWdlOiBTdHJpbmcpIHsKICAgIGxldCBsaW5lID0gIltcKGxvZ0Zvcm1hdHRlci5zdHJpbmcoZnJvbTogRGF0ZSgpKSldIFwobWVzc2FnZSlcbiIKICAgIEZpbGVIYW5kbGUuc3RhbmRhcmRFcnJvci53cml0ZShsaW5lLmRhdGEodXNpbmc6IC51dGY4KSEpCiAgICBpZiBrTG9nRmlsZVdyaXRhYmxlLCBsZXQgaGFuZGxlID0gRmlsZUhhbmRsZShmb3JXcml0aW5nQXRQYXRoOiBrTG9nUGF0aCkgewogICAgICAgIGhhbmRsZS5zZWVrVG9FbmRPZkZpbGUoKQogICAgICAgIGhhbmRsZS53cml0ZShsaW5lLmRhdGEodXNpbmc6IC51dGY4KSEpCiAgICAgICAgdHJ5PyBoYW5kbGUuY2xvc2UoKQogICAgfQp9CgovLyBNQVJLOiAtIOmFjee9rgoKc3RydWN0IENvbmZpZzogQ29kYWJsZSB7CiAgICB2YXIgaG1hY0tleTogU3RyaW5nICAgICAgICAgIC8vIGJhc2U2NCDnvJbnoIHnmoQgMzIg5a2X6IqC6aKE5YWx5Lqr5a+G6ZKlCiAgICB2YXIga2V5Y2hhaW5BY2NvdW50OiBTdHJpbmcgIC8vIOeZu+W9leWvhueggeaJgOWcqOeahOmSpeWMmeS4sui0puaIt+WQjQogICAgdmFyIGRldmljZU5hbWU6IFN0cmluZyAgICAgICAvLyDlub/mkq3lh7rljrvnmoTorr7lpIflkI0KfQoKZnVuYyBsb2FkQ29uZmlnKCkgLT4gQ29uZmlnPyB7CiAgICBndWFyZCBsZXQgZGF0YSA9IEZpbGVNYW5hZ2VyLmRlZmF1bHQuY29udGVudHMoYXRQYXRoOiBrQ29uZmlnUGF0aCkgZWxzZSB7IHJldHVybiBuaWwgfQogICAgcmV0dXJuIHRyeT8gSlNPTkRlY29kZXIoKS5kZWNvZGUoQ29uZmlnLnNlbGYsIGZyb206IGRhdGEpCn0KCmZ1bmMgZW5zdXJlU3VwcG9ydERpcmVjdG9yeSgpIHsKICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5jcmVhdGVEaXJlY3RvcnkoYXRQYXRoOiBrQXBwU3VwcG9ydCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgd2l0aEludGVybWVkaWF0ZURpcmVjdG9yaWVzOiB0cnVlLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBhdHRyaWJ1dGVzOiBbLnBvc2l4UGVybWlzc2lvbnM6IDBvNzAwXSkKfQoKLy8gTUFSSzogLSDlr4bnoIHor7vlj5bvvIhrZXljaGFpbu+8iQoKLy8vIOaKiue7k+aenOaMiSBKU09OIOi+k+WHuu+8jOS+v+S6juiuvue9ruWQkeWvvOino+aekO+8iOmBv+WFjeS4pOerr+WQhOWGmeS4gOWll+mAu+i+ke+8iQpmdW5jIHByaW50SlNPTihfIHBheWxvYWQ6IFtTdHJpbmc6IEFueV0pIHsKICAgIGlmIGxldCBkYXRhID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5kYXRhKHdpdGhKU09OT2JqZWN0OiBwYXlsb2FkLCBvcHRpb25zOiBbLnNvcnRlZEtleXNdKSwKICAgICAgIGxldCB0ZXh0ID0gU3RyaW5nKGRhdGE6IGRhdGEsIGVuY29kaW5nOiAudXRmOCkgewogICAgICAgIHByaW50KHRleHQpCiAgICB9Cn0KCi8vIE1BUks6IC0g5aSa5a+G56CB5a2Y5YKoCi8vCi8vIOavj+WPsOiuvuWkh+WPr+S7peS/neWtmOWkmuS4queZu+W9leWvhuegge+8iOS+i+WmguWImuaUuei/h+WvhueggeOAgeaIluWQjOaXtueUqOWkmuS4qui0puaIt++8ieOAggovLyDop6PplIHml7bmjInpobrluo/pgJDkuKrlsJ3or5XvvIznm7TliLDlsY/luZXop6PlvIDkuLrmraLjgIIKLy8KLy8g5a2Y5YKo5qC85byP77ya6ZKl5YyZ5Liy6YeM5pS+5LiA5LiqIEpTT04g5pWw57uE44CC6L+Z5qC35Y2V5Liq5p2h55uu5bCx6IO96KOF5LiL5YWo6YOo5a+G56CB77yMCi8vIOS5n+WkqeeEtuWFvOWuuSLlj6rmnInkuIDkuKrlr4bnoIEi55qE5pen5qC85byP4oCU4oCU6K+75Y+W5pe26Iul6Kej5p6Q5aSx6LSl5bCx5b2T5L2c5Y2V5Liq5piO5paH5a+G56CB44CCCgovLy8g6K+75Y+W5YWo6YOo5a+G56CB44CC6aG65bqP5Y2z5bCd6K+V6aG65bqP44CCCmZ1bmMgZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogU3RyaW5nKSAtPiBbU3RyaW5nXSB7CiAgICBndWFyZCBsZXQgcmF3ID0gcmVhZEtleWNoYWluUGFzc3dvcmQoYWNjb3VudDogYWNjb3VudCkgZWxzZSB7IHJldHVybiBbXSB9CgogICAgLy8g5paw5qC85byP77yaSlNPTiDmlbDnu4TjgIIKICAgIC8vIOazqOaEj++8muWPquimgeino+aekOaIkOWKn+WwseS7peWug+S4uuWHhu+8jOWNs+S9v+e7k+aenOaYr+epuuaVsOe7hOKAlOKAlAogICAgLy8g5ZCm5YiZ44CMW13jgI3kvJrooqvlvZPmiJDkuIDkuKrkuKTlrZfnrKbnmoTlr4bnoIHvvIjmm77ouKnov4fov5nkuKrlnZHvvInjgIIKICAgIGlmIGxldCBkYXRhID0gcmF3LmRhdGEodXNpbmc6IC51dGY4KSwKICAgICAgIGxldCBhcnIgPSB0cnk/IEpTT05TZXJpYWxpemF0aW9uLmpzb25PYmplY3Qod2l0aDogZGF0YSkgYXM/IFtTdHJpbmddIHsKICAgICAgICByZXR1cm4gYXJyLmZpbHRlciB7ICEkMC5pc0VtcHR5IH0ubWFwKG5vcm1hbGl6ZVBhc3N3b3JkKQogICAgfQoKICAgIC8vIOaXp+agvOW8j++8muWNleS4quaYjuaWh+WvhueggQogICAgcmV0dXJuIHJhdy5pc0VtcHR5ID8gW10gOiBbbm9ybWFsaXplUGFzc3dvcmQocmF3KV0KfQoKLy8vIOWGmeWbnuWFqOmDqOWvhueggeOAguWni+e7iOWGmSBKU09OIOaVsOe7hO+8jOS+v+S6juaXpeWQjuWinuWIoOOAggpAZGlzY2FyZGFibGVSZXN1bHQKZnVuYyBzdG9yZVBhc3N3b3JkcyhfIHBhc3N3b3JkczogW1N0cmluZ10sIGFjY291bnQ6IFN0cmluZykgLT4gQm9vbCB7CiAgICBsZXQgbGlzdCA9IHBhc3N3b3Jkcy5maWx0ZXIgeyAhJDAuaXNFbXB0eSB9Lm1hcChub3JtYWxpemVQYXNzd29yZCkKICAgIGd1YXJkIGxldCBkYXRhID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5kYXRhKHdpdGhKU09OT2JqZWN0OiBsaXN0LCBvcHRpb25zOiBbXSksCiAgICAgICAgICBsZXQganNvbiA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpIGVsc2UgewogICAgICAgIGxvZygi5a+G56CB5bqP5YiX5YyW5aSx6LSlIikKICAgICAgICByZXR1cm4gZmFsc2UKICAgIH0KICAgIHJldHVybiB3cml0ZUtleWNoYWluUGFzc3dvcmQoanNvbiwgYWNjb3VudDogYWNjb3VudCkKfQoKLy8vIOaYr+WQpuimgeaxgui3s+i/h+mUgeWxj+agoemqjO+8iOWtl+iKgiAyOSDpnZ4gMO+8iQpmdW5jIGV4dHJhY3RGb3JjZUZsYWcoXyBieXRlczogW1VJbnQ4XSkgLT4gQm9vbCB7CiAgICBndWFyZCBieXRlcy5jb3VudCA+IGtGb3JjZU9mZnNldCwgYnl0ZXNbM10gPT0ga0NtZFVubG9ja0Zyb20gZWxzZSB7IHJldHVybiBmYWxzZSB9CiAgICByZXR1cm4gYnl0ZXNba0ZvcmNlT2Zmc2V0XSAhPSAwCn0KCi8vLyDku47miqXmlofkuK3lj5blh7rlr4bnoIHluo/lj7fjgIIKLy8vCi8vLyDlj6rmnInjgIzmjIflrprlr4bnoIHop6PplIHjgI3vvIhrQ21kVW5sb2NrRnJvbe+8ieS8mueUqOWIsOWtl+iKgiAyOOOAggovLy8g5YW25LuW5oyH5Luk6K+l5a2X6IqC5Li6IDDvvIzov5nph4zov5Tlm54gbmls77yM6YG/5YWN6KKr6K+v5b2T5oiQIuesrCAwIOS4quWvhueggSLjgIIKZnVuYyBleHRyYWN0UGFzc3dvcmRJbmRleChfIGJ5dGVzOiBbVUludDhdKSAtPiBVSW50OD8gewogICAgZ3VhcmQgYnl0ZXMuY291bnQgPiBrSW5kZXhPZmZzZXQsIGJ5dGVzWzNdID09IGtDbWRVbmxvY2tGcm9tIGVsc2UgeyByZXR1cm4gbmlsIH0KICAgIHJldHVybiBieXRlc1trSW5kZXhPZmZzZXRdCn0KCi8vLyDmiornrKwgaW5kZXgg5Liq5a+G56CB5o+Q5Yiw5pyA5YmN6Z2i77yM5YW25L2Z5L+d5oyB55u45a+56aG65bqP44CCCi8vLyDluo/lj7fotornlYzml7bljp/moLfov5Tlm57vvIzkuI3mipvplJnigJTigJTosIPnlKjmlrnmja7mraTlm57pgIDliLDpu5jorqTpobrluo/jgIIKZnVuYyBwcm9tb3RlUGFzc3dvcmQoXyBsaXN0OiBbU3RyaW5nXSwgdG9Gcm9udCBpbmRleDogSW50KSAtPiBbU3RyaW5nXSB7CiAgICBndWFyZCBpbmRleCA+IDAsIGluZGV4IDwgbGlzdC5jb3VudCBlbHNlIHsgcmV0dXJuIGxpc3QgfQogICAgdmFyIG91dCA9IGxpc3QKICAgIGxldCBwaWNrZWQgPSBvdXQucmVtb3ZlKGF0OiBpbmRleCkKICAgIG91dC5pbnNlcnQocGlja2VkLCBhdDogMCkKICAgIHJldHVybiBvdXQKfQoKLy8vIOWFvOWuueaXp+aOpeWPo++8mui/lOWbnuesrOS4gOS4quWvhueggQpmdW5jIGZldGNoUGFzc3dvcmQoYWNjb3VudDogU3RyaW5nKSAtPiBTdHJpbmc/IHsKICAgIGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IGFjY291bnQpLmZpcnN0Cn0KCmZ1bmMgcmVhZEtleWNoYWluUGFzc3dvcmQoYWNjb3VudDogU3RyaW5nKSAtPiBTdHJpbmc/IHsKICAgIGxldCBwcm9jZXNzID0gUHJvY2VzcygpCiAgICBwcm9jZXNzLmV4ZWN1dGFibGVVUkwgPSBVUkwoZmlsZVVSTFdpdGhQYXRoOiAiL3Vzci9iaW4vc2VjdXJpdHkiKQogICAgcHJvY2Vzcy5hcmd1bWVudHMgPSBbImZpbmQtZ2VuZXJpYy1wYXNzd29yZCIsCiAgICAgICAgICAgICAgICAgICAgICAgICAiLWEiLCBhY2NvdW50LAogICAgICAgICAgICAgICAgICAgICAgICAgIi1zIiwga0tleWNoYWluU2VydmljZSwKICAgICAgICAgICAgICAgICAgICAgICAgICItdyJdCiAgICBsZXQgcGlwZSA9IFBpcGUoKQogICAgcHJvY2Vzcy5zdGFuZGFyZE91dHB1dCA9IHBpcGUKICAgIHByb2Nlc3Muc3RhbmRhcmRFcnJvciA9IEZpbGVIYW5kbGUubnVsbERldmljZQogICAgZG8gewogICAgICAgIHRyeSBwcm9jZXNzLnJ1bigpCiAgICB9IGNhdGNoIHsKICAgICAgICBsb2coIuaXoOazleaJp+ihjCBzZWN1cml0eSDlkb3ku6Q6IFwoZXJyb3IpIikKICAgICAgICByZXR1cm4gbmlsCiAgICB9CiAgICBsZXQgZGF0YSA9IHBpcGUuZmlsZUhhbmRsZUZvclJlYWRpbmcucmVhZERhdGFUb0VuZE9mRmlsZSgpCiAgICBwcm9jZXNzLndhaXRVbnRpbEV4aXQoKQogICAgZ3VhcmQgcHJvY2Vzcy50ZXJtaW5hdGlvblN0YXR1cyA9PSAwIGVsc2UgeyByZXR1cm4gbmlsIH0KICAgIHZhciBwdyA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpID8/ICIiCiAgICAvLyBzZWN1cml0eSAtdyDkvJrpmYTluKbkuIDkuKrmjaLooYwKICAgIHdoaWxlIHB3Lmhhc1N1ZmZpeCgiXG4iKSB8fCBwdy5oYXNTdWZmaXgoIlxyIikgeyBwdy5yZW1vdmVMYXN0KCkgfQogICAgZ3VhcmQgIXB3LmlzRW1wdHkgZWxzZSB7IHJldHVybiBuaWwgfQogICAgcmV0dXJuIGRlY29kZUhleElmTmVlZGVkKHB3KQp9CgovLy8gYHNlY3VyaXR5IC13YCDlr7kqKumdniBBU0NJSSoqIOeahOWvhueggeS8mui+k+WHuuWNgeWFrei/m+WItuS4suiAjOS4jeaYr+WOn+aWhwovLy8g77yI5L6L5aaC44CM5Lit5paH5a+G56CB44CN5Lya6K+75oiQICJlNGI4YWRlNjk2ODdlNWFmODZlN2EwODEi77yJ44CCCi8vLyDov5nph4zmiorlroPov5jljp/jgIIKLy8vCi8vLyDliKTlrprmnaHku7bliLvmhI/kv53lrojvvIzpgb/lhY3or6/kvKQi5pys5p2l5bCx5piv5Y2B5YWt6L+b5Yi2IueahCBBU0NJSSDlr4bnoIHvvJoKLy8vIOWPquacieaVtOS4suaYr+WQiOazleWNgeWFrei/m+WItuOAgemVv+W6puS4uuWBtuaVsO+8jCoq5LiU6Kej56CB5ZCO5ZCr6Z2eIEFTQ0lJIOWtl+espioq5pe25omN6L+Y5Y6f44CCCi8vLyDnuq8gQVNDSUkg55qE5a+G56CB6Kej56CB5ZCO5LuN5pivIEFTQ0lJ77yM5Zug5q2k5LiN5Lya6KKr6K+v5pS544CCCmZ1bmMgZGVjb2RlSGV4SWZOZWVkZWQoXyB2YWx1ZTogU3RyaW5nKSAtPiBTdHJpbmcgewogICAgbGV0IGhleERpZ2l0cyA9IENoYXJhY3RlclNldChjaGFyYWN0ZXJzSW46ICIwMTIzNDU2Nzg5YWJjZGVmQUJDREVGIikKICAgIGd1YXJkIHZhbHVlLmNvdW50ID49IDIsIHZhbHVlLmNvdW50ICUgMiA9PSAwLAogICAgICAgICAgdmFsdWUudW5pY29kZVNjYWxhcnMuYWxsU2F0aXNmeSh7IGhleERpZ2l0cy5jb250YWlucygkMCkgfSkgZWxzZSB7CiAgICAgICAgcmV0dXJuIHZhbHVlCiAgICB9CiAgICB2YXIgYnl0ZXM6IFtVSW50OF0gPSBbXQogICAgYnl0ZXMucmVzZXJ2ZUNhcGFjaXR5KHZhbHVlLmNvdW50IC8gMikKICAgIHZhciBpZHggPSB2YWx1ZS5zdGFydEluZGV4CiAgICB3aGlsZSBpZHggPCB2YWx1ZS5lbmRJbmRleCB7CiAgICAgICAgbGV0IG5leHQgPSB2YWx1ZS5pbmRleChpZHgsIG9mZnNldEJ5OiAyKQogICAgICAgIGd1YXJkIGxldCBieXRlID0gVUludDgodmFsdWVbaWR4Li48bmV4dF0sIHJhZGl4OiAxNikgZWxzZSB7IHJldHVybiB2YWx1ZSB9CiAgICAgICAgYnl0ZXMuYXBwZW5kKGJ5dGUpCiAgICAgICAgaWR4ID0gbmV4dAogICAgfQogICAgZ3VhcmQgbGV0IGRlY29kZWQgPSBTdHJpbmcoYnl0ZXM6IGJ5dGVzLCBlbmNvZGluZzogLnV0ZjgpIGVsc2UgeyByZXR1cm4gdmFsdWUgfQogICAgLy8g5Y+q5pyJ6Kej56CB57uT5p6c5ZCr6Z2eIEFTQ0lJIOaXtuaJjeiupOWumuaYryBoZXgg57yW56CB77ybCiAgICAvLyDlkKbliJnkv53nlZnljp/mlofvvIzpgb/lhY3miorlvaLlpoIgImRlYWRiZWVmIiDnmoTlr4bnoIHmlLnmjonjgIIKICAgIGd1YXJkIGRlY29kZWQudW5pY29kZVNjYWxhcnMuY29udGFpbnMod2hlcmU6IHsgJDAudmFsdWUgPiAxMjcgfSkgZWxzZSB7IHJldHVybiB2YWx1ZSB9CiAgICBsb2coIumSpeWMmeS4sui/lOWbnueahOaYr+WNgeWFrei/m+WItue8luegge+8jOW3sui/mOWOn+S4uuWOn+aWh++8iFwodmFsdWUuY291bnQpIOKGkiBcKGRlY29kZWQuY291bnQpIOWtl+espu+8iSIpCiAgICByZXR1cm4gZGVjb2RlZAp9CgovLy8g57uf5LiA6KeE6IyD5YyW5b2i5byP44CCCi8vLwovLy8gbWFjT1Mg6ZKl5YyZ5Liy5Lya5oqK6Z2eIEFTQ0lJIOWtl+espuWtmOaIkCBORkTvvIjliIbop6PlvI/vvIzDqSA9IGUgKyDnu4TlkIjph43pn7PvvInvvIwKLy8vIOiAjOi+k+WFpeW+gOW+gOaYryBORkPvvIjpooTnu4TlkIjvvInjgILkuKTnp43lvaLlvI/muLLmn5Pnm7jlkIzjgIFORkMg5b2S5LiA5ZCO55u4562J77yMCi8vLyDkvYbnoIHngrnkuI3lkIzkvJrorqnlrZfnrKbkuLLmr5TovoPlh7rnjrDlgYflpLHotKXjgILov5nph4znu5/kuIDmiJAgTkZD77yM6K6p5a2Y5Y+W56Gu5a6a44CCCmZ1bmMgbm9ybWFsaXplUGFzc3dvcmQoXyBzOiBTdHJpbmcpIC0+IFN0cmluZyB7CiAgICBzLnByZWNvbXBvc2VkU3RyaW5nV2l0aENhbm9uaWNhbE1hcHBpbmcKfQoKLy8vIOeUqCBzZWN1cml0eSDlkb3ku6TlhpnlhaXpkqXljJnkuLLvvIgtVSDooajnpLrlrZjlnKjliJnljp/lnLDmm7TmlrDvvIkKZnVuYyB3cml0ZUtleWNoYWluUGFzc3dvcmQoXyB2YWx1ZTogU3RyaW5nLCBhY2NvdW50OiBTdHJpbmcpIC0+IEJvb2wgewogICAgbGV0IHIgPSBydW5Qcm9jZXNzKCIvdXNyL2Jpbi9zZWN1cml0eSIsCiAgICAgICAgICAgICAgICAgICAgICAgWyJhZGQtZ2VuZXJpYy1wYXNzd29yZCIsICItVSIsCiAgICAgICAgICAgICAgICAgICAgICAgICItYSIsIGFjY291bnQsCiAgICAgICAgICAgICAgICAgICAgICAgICItcyIsIGtLZXljaGFpblNlcnZpY2UsCiAgICAgICAgICAgICAgICAgICAgICAgICItbCIsICJCTEVVbmxvY2tDbWQiLAogICAgICAgICAgICAgICAgICAgICAgICAiLXciLCB2YWx1ZV0pCiAgICBpZiByLmNvZGUgIT0gMCB7CiAgICAgICAgbGV0IGRldGFpbCA9IHIuZXJyLnRyaW1taW5nQ2hhcmFjdGVycyhpbjogLndoaXRlc3BhY2VzQW5kTmV3bGluZXMpCiAgICAgICAgbG9nKCLlhpnlhaXpkqXljJnkuLLlpLHotKXvvJrpgIDlh7rnoIEgXChyLmNvZGUpIiArIChkZXRhaWwuaXNFbXB0eSA/ICIiIDogIu+8mlwoZGV0YWlsKSIpKQogICAgICAgIHJldHVybiBmYWxzZQogICAgfQogICAgcmV0dXJuIHRydWUKfQoKLy8vIOaJp+ihjOWklumDqOWRveS7pOW5tuWQjOaXtui/lOWbniBzdGRlcnLvvIzkvr/kuo7or4rmlq0KZnVuYyBydW5Qcm9jZXNzKF8gcGF0aDogU3RyaW5nLCBfIGFyZ3M6IFtTdHJpbmddKSAtPiAoY29kZTogSW50MzIsIG91dDogU3RyaW5nLCBlcnI6IFN0cmluZykgewogICAgbGV0IHAgPSBQcm9jZXNzKCkKICAgIHAuZXhlY3V0YWJsZVVSTCA9IFVSTChmaWxlVVJMV2l0aFBhdGg6IHBhdGgpCiAgICBwLmFyZ3VtZW50cyA9IGFyZ3MKICAgIGxldCBvdXRQaXBlID0gUGlwZSgpCiAgICBsZXQgZXJyUGlwZSA9IFBpcGUoKQogICAgcC5zdGFuZGFyZE91dHB1dCA9IG91dFBpcGUKICAgIHAuc3RhbmRhcmRFcnJvciA9IGVyclBpcGUKICAgIGRvIHsgdHJ5IHAucnVuKCkgfSBjYXRjaCB7CiAgICAgICAgcmV0dXJuICgtMSwgIiIsIGVycm9yLmxvY2FsaXplZERlc2NyaXB0aW9uKQogICAgfQogICAgbGV0IG91dERhdGEgPSBvdXRQaXBlLmZpbGVIYW5kbGVGb3JSZWFkaW5nLnJlYWREYXRhVG9FbmRPZkZpbGUoKQogICAgbGV0IGVyckRhdGEgPSBlcnJQaXBlLmZpbGVIYW5kbGVGb3JSZWFkaW5nLnJlYWREYXRhVG9FbmRPZkZpbGUoKQogICAgcC53YWl0VW50aWxFeGl0KCkKICAgIHJldHVybiAocC50ZXJtaW5hdGlvblN0YXR1cywKICAgICAgICAgICAgU3RyaW5nKGRhdGE6IG91dERhdGEsIGVuY29kaW5nOiAudXRmOCkgPz8gIiIsCiAgICAgICAgICAgIFN0cmluZyhkYXRhOiBlcnJEYXRhLCBlbmNvZGluZzogLnV0ZjgpID8/ICIiKQp9CgovLyBNQVJLOiAtIOWxj+W5leeKtuaAgSAvIOaYvuekuuWZqOaOp+WItgoKZnVuYyBpc1NjcmVlbkxvY2tlZCgpIC0+IEJvb2wgewogICAgLy8g5YWs5byAIEFQSe+8mkNHU2Vzc2lvbkNvcHlDdXJyZW50RGljdGlvbmFyee+8iFF1YXJ0eiDnp4HmnInkvYbooqvlub/ms5vkvb/nlKjnmoQgc2Vzc2lvbiDlrZflhbjvvIkKICAgIGd1YXJkIGxldCBkaWN0ID0gQ0dTZXNzaW9uQ29weUN1cnJlbnREaWN0aW9uYXJ5KCkgYXM/IFtTdHJpbmc6IEFueV0gZWxzZSB7IHJldHVybiBmYWxzZSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEludCB7IHJldHVybiBsb2NrZWQgPT0gMSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEJvb2wgeyByZXR1cm4gbG9ja2VkIH0KICAgIHJldHVybiBmYWxzZQp9Cgp2YXIgZGlzcGxheUFzc2VydGlvbklEID0gSU9QTUFzc2VydGlvbklEKDApCgpmdW5jIHdha2VEaXNwbGF5KCkgewogICAgSU9QTUFzc2VydGlvbkRlY2xhcmVVc2VyQWN0aXZpdHkoIkJMRVVubG9ja0NtZCIgYXMgQ0ZTdHJpbmcsIGtJT1BNVXNlckFjdGl2ZUxvY2FsLCAmZGlzcGxheUFzc2VydGlvbklEKQp9CgpmdW5jIHNsZWVwRGlzcGxheSgpIHsKICAgIC8vIElPUmVnaXN0cnlFbnRyeUZyb21QYXRoIOmcgOimgSBDIOWtl+espuS4sui3r+W+hAogICAgbGV0IGVudHJ5ID0gSU9SZWdpc3RyeUVudHJ5RnJvbVBhdGgoa0lPTWFzdGVyUG9ydERlZmF1bHQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiSU9TZXJ2aWNlOi9JT1Jlc291cmNlcy9JT0Rpc3BsYXlXcmFuZ2xlciIpCiAgICBpZiBlbnRyeSAhPSAwIHsKICAgICAgICBJT1JlZ2lzdHJ5RW50cnlTZXRDRlByb3BlcnR5KGVudHJ5LCAiSU9SZXF1ZXN0SWRsZSIgYXMgQ0ZTdHJpbmcsIGtDRkJvb2xlYW5UcnVlKQogICAgICAgIElPT2JqZWN0UmVsZWFzZShlbnRyeSkKICAgIH0KfQoKLy8gTUFSSzogLSDlhajlsYDlvIDlhbMKCi8vLyDlronlhajmtYvor5XmqKHlvI/vvJrlrozmlbTotbDkuIDpgY0gQkxFIOaUtuWMheS4juagoemqjO+8jOS9huS4jeecn+eahOazqOWFpeWvhueggQp2YXIgZHJ5UnVuID0gZmFsc2UKCi8vIE1BUks6IC0g6ZSu55uY5LqL5Lu25rOo5YWl77yI6Kej6ZSB55qE5qC45b+D77yJCgovLy8g5Y+R6YCB5LiA5Liq5Y2V54us55qE5oyJ6ZSu77yI55So6Jma5ouf6ZSu56CB77yJ77yM5L6L5aaCIEVzYyDnlKjmnaXmuIXnqbrlr4bnoIHovpPlhaXmoYYKZnVuYyBzZW5kS2V5KF8gdmlydHVhbEtleTogQ0dLZXlDb2RlKSB7CiAgICBpZiBkcnlSdW4geyByZXR1cm4gfQogICAgZ3VhcmQgbGV0IHNvdXJjZSA9IENHRXZlbnRTb3VyY2Uoc3RhdGVJRDogLmhpZFN5c3RlbVN0YXRlKSBlbHNlIHsgcmV0dXJuIH0KICAgIENHRXZlbnQoa2V5Ym9hcmRFdmVudFNvdXJjZTogc291cmNlLCB2aXJ0dWFsS2V5OiB2aXJ0dWFsS2V5LCBrZXlEb3duOiB0cnVlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IHZpcnR1YWxLZXksIGtleURvd246IGZhbHNlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQp9CgpmdW5jIGZha2VLZXlTdHJva2VzKF8gc3RyaW5nOiBTdHJpbmcpIHsKICAgIGlmIGRyeVJ1biB7CiAgICAgICAgbG9nKCJbZHJ5LXJ1bl0g5pys5bqU5rOo5YWlIFwoc3RyaW5nLmNvdW50KSDkuKrlrZfnrKbnmoTlr4bnoIHlubblm57ovabvvIzlt7Lot7Pov4ciKQogICAgICAgIHJldHVybgogICAgfQogICAgZ3VhcmQgbGV0IHNvdXJjZSA9IENHRXZlbnRTb3VyY2Uoc3RhdGVJRDogLmhpZFN5c3RlbVN0YXRlKSBlbHNlIHsKICAgICAgICBsb2coIuaXoOazleWIm+W7uiBDR0V2ZW50U291cmNlIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIGxldCB1bml0cyA9IEFycmF5KHN0cmluZy51dGYxNikKICAgIGxldCBwZXJDaHVuayA9IDIwICAgLy8g5Y2V5Liq6ZSu55uY5LqL5Lu25pyA5aSa5pC65bimIDIwIOS4qiBVVEYtMTYg5a2X56ymCgogICAgdmFyIGluZGV4ID0gMAogICAgd2hpbGUgaW5kZXggPCB1bml0cy5jb3VudCB7CiAgICAgICAgbGV0IGNvdW50ID0gbWluKHBlckNodW5rLCB1bml0cy5jb3VudCAtIGluZGV4KQogICAgICAgIHZhciBidWZmZXIgPSBBcnJheSh1bml0c1tpbmRleCAuLjwgaW5kZXggKyBjb3VudF0pCgogICAgICAgIGd1YXJkIGxldCBkb3duID0gQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDQ5LCBrZXlEb3duOiB0cnVlKSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGRvd24ua2V5Ym9hcmRTZXRVbmljb2RlU3RyaW5nKHN0cmluZ0xlbmd0aDogY291bnQsIHVuaWNvZGVTdHJpbmc6ICZidWZmZXIpCiAgICAgICAgZG93bi5wb3N0KHRhcDogLmNnaGlkRXZlbnRUYXApCgogICAgICAgIENHRXZlbnQoa2V5Ym9hcmRFdmVudFNvdXJjZTogc291cmNlLCB2aXJ0dWFsS2V5OiA0OSwga2V5RG93bjogZmFsc2UpPwogICAgICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgICAgIGluZGV4ICs9IGNvdW50CiAgICB9CgogICAgLy8g5Zue6L2m6ZSu77yIdmlydHVhbEtleSA1MiA9IFJldHVybu+8iQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiB0cnVlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiBmYWxzZSk/CiAgICAgICAgLnBvc3QodGFwOiAuY2doaWRFdmVudFRhcCkKfQoKZnVuYyBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IEJvb2wgPSBmYWxzZSkgLT4gQm9vbCB7CiAgICBsZXQga2V5ID0ga0FYVHJ1c3RlZENoZWNrT3B0aW9uUHJvbXB0LnRha2VVbnJldGFpbmVkVmFsdWUoKSBhcyBTdHJpbmcKICAgIHJldHVybiBBWElzUHJvY2Vzc1RydXN0ZWRXaXRoT3B0aW9ucyhba2V5OiBwcm9tcHRdIGFzIENGRGljdGlvbmFyeSkKfQoKLy8gTUFSSzogLSDop6PplIEgLyDplIHlrpoKCnZhciB1bmxvY2tJbkZsaWdodCA9IGZhbHNlCgovLy8g6Ieq5Yqo6Kej6ZSB77ya5ZSk6YaS5bGP5bmVIC0+IOehruiupOWkhOS6jumUgeWxjyAtPiDms6jlhaXlr4bnoIEKLy8vIC0gUGFyYW1ldGVyczoKLy8vICAgLSBwcmVmZXJyZWRJbmRleDog5LyY5YWI5bCd6K+V56ys5Yeg5Liq5a+G56CB77yIMCDln7rvvInjgILkuLogbmlsIOaXtuaMieS/neWtmOmhuuW6j+OAggovLy8gICAgIOaJi+acuuerr+WPr+S7peaMh+WumiLnlKjlk6rkuKrlr4bnoIHop6PplIEi77yb6Iul5oyH5a6a55qE5bqP5Y+36LaK55WM5oiW6K+l5a+G56CB5LiN5a+577yMCi8vLyAgICAg5Lya6Ieq5Yqo5Zue6YCA5Yiw5oyJ5Y6f6aG65bqP57un57ut5bCd6K+V5YW25L2Z5a+G56CB44CCCi8vLyAgIC0gZm9yY2U6IOi3s+i/hyLplIHlsY/moKHpqowi44CCCi8vLyAgICAg5omL5py656uv44CM5aGr5YWF5a+G56CB44CN5piv5Lq65bel5piO56Gu5LiL6L6+55qE5oyH5Luk4oCU4oCU55So5oi35bCx5piv6KaB546w5Zyo5oqK5a2X56ym6YCB6L+b5Y6777yMCi8vLyAgICAg5LiN6ZyA6KaB77yI5Lmf5LiN5bqU6K+l77yJ5YaN5Yik5pat5bGP5bmV5piv5ZCm5aSE5LqO6ZSB5a6a54q25oCB44CC5Li6IHRydWUg5pe255u05o6l5rOo5YWl77yMCi8vLyAgICAg5LiN562J5b6F6ZSB5bGP44CB5LiN6L2u6K+i5ZSk6YaS44CCCmZ1bmMgcGVyZm9ybVVubG9jayhwcmVmZXJyZWRJbmRleDogVUludDg/ID0gbmlsLAogICAgICAgICAgICAgICAgICAgZm9yY2U6IEJvb2wgPSBmYWxzZSwKICAgICAgICAgICAgICAgICAgIHJlcGx5OiBAZXNjYXBpbmcgKFN0cmluZykgLT4gVm9pZCkgewogICAgZ3VhcmQgIXVubG9ja0luRmxpZ2h0IGVsc2UgewogICAgICAgIHJlcGx5KCJCVVNZIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIC8vIGRyeS1ydW4g5LiL5LiN5qOA5p+l6L6F5Yqp5Yqf6IO95p2D6ZmQ77yM5Zug5Li65LiN5Lya55yf55qE5rOo5YWl5LqL5Lu2CiAgICBndWFyZCBkcnlSdW4gfHwgYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSBlbHNlIHsKICAgICAgICBsb2coIuino+mUgeWksei0pe+8mue8uuWwkeOAjOi+heWKqeWKn+iDveOAjeadg+mZkCIpCiAgICAgICAgcmVwbHkoIkVSUl9OT19BWCIpCiAgICAgICAgcmV0dXJuCiAgICB9CiAgICBndWFyZCBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIGVsc2UgewogICAgICAgIGxvZygi6Kej6ZSB5aSx6LSl77ya6YWN572u57y65aSxIikKICAgICAgICByZXBseSgiRVJSX0NPTkZJRyIpCiAgICAgICAgcmV0dXJuCiAgICB9CgogICAgbGV0IHNhdmVkID0gZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogY29uZmlnLmtleWNoYWluQWNjb3VudCkKICAgIGd1YXJkICFzYXZlZC5pc0VtcHR5IGVsc2UgewogICAgICAgIGxvZygi6Kej6ZSB5aSx6LSl77ya6ZKl5YyZ5Liy5Lit6K+75LiN5Yiw5a+G56CBIikKICAgICAgICByZXBseSgiRVJSX05PX1BXIikKICAgICAgICByZXR1cm4KICAgIH0KCiAgICAvLyDmiYvmnLrlj6/ku6XmjIflrprkvJjlhYjnlKjlk6rkuKrlr4bnoIHvvJrmioror6Xlr4bnoIHmj5DliLDmnIDliY3pnaLvvIwKICAgIC8vIOWFtuS9meS/neaMgeWOn+mhuuW6j+S9nOS4uuWbnumAgOKAlOKAlOi/meagt+aMh+WumueahOWvhueggeS4jeWvueaXtuS7jeiDveiHquWKqOivleWIsOWvueeahOOAggogICAgdmFyIHBhc3N3b3JkcyA9IHNhdmVkCiAgICBpZiBsZXQgaWR4ID0gcHJlZmVycmVkSW5kZXggewogICAgICAgIGxldCBpID0gSW50KGlkeCkKICAgICAgICBpZiBpID49IDAgJiYgaSA8IHNhdmVkLmNvdW50IHsKICAgICAgICAgICAgcGFzc3dvcmRzID0gcHJvbW90ZVBhc3N3b3JkKHNhdmVkLCB0b0Zyb250OiBpKQogICAgICAgICAgICBsb2coIuaJi+acuuaMh+WumuS8mOWFiOS9v+eUqOesrCBcKGkgKyAxKSDkuKrlr4bnoIHvvIjlhbEgXChzYXZlZC5jb3VudCkg5Liq77yJIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBsb2coIuaJi+acuuaMh+WumueahOWvhueggeW6j+WPtyBcKGkgKyAxKSDotornlYzvvIjlhbEgXChzYXZlZC5jb3VudCkg5Liq77yJ77yM5oyJ6buY6K6k6aG65bqP5bCd6K+VIikKICAgICAgICB9CiAgICB9CgogICAgaWYgZHJ5UnVuIHsKICAgICAgICBsb2coIltkcnktcnVuXSDmoKHpqozpgJrov4fvvIzlhbEgXChwYXNzd29yZHMuY291bnQpIOS4quWvhuegge+8jOacrOW6lOmAkOS4quWwneivlSIKICAgICAgICAgICAgKyAoZm9yY2UgPyAi77yI5by65Yi25aGr5YWF77yM6Lez6L+H6ZSB5bGP5qCh6aqM77yJIiA6ICIiKSkKICAgICAgICByZXBseSgiT0siKQogICAgICAgIHJldHVybgogICAgfQoKICAgIHVubG9ja0luRmxpZ2h0ID0gdHJ1ZQogICAgd3JpdGVEYWVtb25TdGF0dXMoKQoKICAgIGlmIGZvcmNlIHsKICAgICAgICAvLyDlvLrliLbloavlhYXvvJrkuI3liKTmlq3mmK/lkKbplIHlsY/vvIznm7TmjqXmiorpgInkuK3nmoTlr4bnoIHms6jlhaXlubblm57ovabjgIIKICAgICAgICAvLyDov5nmnaHot6/lvoTlj6rlgZrkuIDmrKHvvIzkuI3pgJDkuKrlm57pgIDigJTigJTkurrlt6XmjIflrprnlKjlk6rkuKrlsLHnlKjlk6rkuKrjgIIKICAgICAgICAvLwogICAgICAgIC8vIOazqOaEj++8mmZvcmNlIOWPr+iDveS4jeW4puW6j+WPt++8iOaJi+acuuWPquimgeaxgiLot7Pov4fmoKHpqowi77yJ77yMCiAgICAgICAgLy8g5q2k5pe2IHBhc3N3b3Jkc1swXSDlsLHmmK/kv53lrZjpobrluo/ph4znmoTnrKzkuIDkuKrvvIzljbPpu5jorqTlr4bnoIHjgIIKICAgICAgICBsZXQgY2hvc2VuID0gcGFzc3dvcmRzWzBdCiAgICAgICAgbG9nKCLmlLbliLDlvLrliLbloavlhYXmjIfku6TvvIjot7Pov4fplIHlsY/moKHpqozvvIzlhbEgXChwYXNzd29yZHMuY291bnQpIOS4quWvhuegge+8iSIpCiAgICAgICAgLy8g5bGP5bmV6Iul5Zyo5oGv5bGP54q25oCB77yM6L6T5YWl5qGG5pS25LiN5Yiw5oyJ6ZSu77yM5Zug5q2k5LuN5YWI54K55Lqu5bGP5bmVCiAgICAgICAgd2FrZURpc3BsYXkoKQogICAgICAgIERpc3BhdGNoUXVldWUubWFpbi5hc3luY0FmdGVyKGRlYWRsaW5lOiAubm93KCkgKyAwLjM1KSB7CiAgICAgICAgICAgIGxvZygi5rOo5YWlIFwoY2hvc2VuLmNvdW50KSDkuKrlrZfnrKblubblm57ovaYiKQogICAgICAgICAgICBmYWtlS2V5U3Ryb2tlcyhjaG9zZW4pCiAgICAgICAgICAgIHVubG9ja0luRmxpZ2h0ID0gZmFsc2UKICAgICAgICAgICAgcmVwbHkoIk9LIikKICAgICAgICB9CiAgICAgICAgcmV0dXJuCiAgICB9CgogICAgbG9nKCLmlLbliLDop6PplIHmjIfku6TvvIzlvIDlp4vmiafooYzvvIhcKHBhc3N3b3Jkcy5jb3VudCkg5Liq5a+G56CB5b6F5bCd6K+V77yJIikKCiAgICB3YWtlRGlzcGxheSgpCgogICAgLy8g5pi+56S65Zmo5ZSk6YaS5ZCO6ZyA6KaB5LiA54K55pe26Ze05omN55yf5q2j54K55Lqu77yM6YeN6K+V5Yeg6L2uCiAgICB2YXIgd2FrZUF0dGVtcHQgPSAwCiAgICBsZXQgbWF4V2FrZUF0dGVtcHRzID0gOAogICAgLy8vIOavj+S4quWvhueggeazqOWFpeWQju+8jOetieW+heWkmuS5heWGjeWIpOaWreaYr+WQpuino+mUgeaIkOWKnwogICAgbGV0IHNldHRsZURlbGF5ID0gMS4yCgogICAgLy8vIOino+mUgeaIkOWKn+aUtuWwvgogICAgZnVuYyBzdWNjZWVkZWQoYWZ0ZXIgdHJpZWQ6IEludCkgewogICAgICAgIHVubG9ja0luRmxpZ2h0ID0gZmFsc2UKICAgICAgICBpZiB0cmllZCA9PSAwIHsKICAgICAgICAgICAgbG9nKCLlt7Lms6jlhaXlr4bnoIHlubblm57ovabvvIzop6PplIHmjIfku6TlrozmiJAiKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvZygi56ysIFwodHJpZWQgKyAxKSDkuKrlr4bnoIHnlJ/mlYjvvIzop6PplIHmjIfku6TlrozmiJAiKQogICAgICAgIH0KICAgICAgICByZXBseSgiT0siKQogICAgfQoKICAgIC8vLyDkvp3mrKHlsJ3or5Xmr4/kuKrlr4bnoIHvvJvlhajpg6jlpLHotKXliJnlm57miqUKICAgIGZ1bmMgdHJ5UGFzc3dvcmQoYXQgaW5kZXg6IEludCkgewogICAgICAgIGd1YXJkIGluZGV4IDwgcGFzc3dvcmRzLmNvdW50IGVsc2UgewogICAgICAgICAgICB1bmxvY2tJbkZsaWdodCA9IGZhbHNlCiAgICAgICAgICAgIGxvZygi5bey5bCd6K+V5YWo6YOoIFwocGFzc3dvcmRzLmNvdW50KSDkuKrlr4bnoIHvvIzlsY/luZXku43mnKrop6PplIEiKQogICAgICAgICAgICByZXBseSgiRVJSX0FMTF9QVyIpCiAgICAgICAgICAgIHJldHVybgogICAgICAgIH0KCiAgICAgICAgbGV0IGlzTGFzdCA9IChpbmRleCA9PSBwYXNzd29yZHMuY291bnQgLSAxKQogICAgICAgIGxvZygi5rOo5YWl56ysIFwoaW5kZXggKyAxKS9cKHBhc3N3b3Jkcy5jb3VudCkg5Liq5a+G56CB77yIXChwYXNzd29yZHNbaW5kZXhdLmNvdW50KSDlrZfnrKbvvIkiKQoKICAgICAgICAvLyDlsJ3or5XliY3lhYjmuIXnqbrovpPlhaXmoYbvvJrkuIrkuIDkuKrlr4bnoIHoi6XplJnor6/vvIzlrZfmrrXph4zlj6/og73mrovnlZnlhoXlrrnjgIIKICAgICAgICAvLyDnlKggRXNjIOa4heepuuavlOmAkOWtl+espuWIoOmZpOWPr+mdoOOAggogICAgICAgIGlmIGluZGV4ID4gMCB7CiAgICAgICAgICAgIHNlbmRLZXkoMHgzNSkgICAvLyBFc2MKICAgICAgICAgICAgVGhyZWFkLnNsZWVwKGZvclRpbWVJbnRlcnZhbDogMC4yNSkKICAgICAgICB9CgogICAgICAgIGZha2VLZXlTdHJva2VzKHBhc3N3b3Jkc1tpbmRleF0pCgogICAgICAgIERpc3BhdGNoUXVldWUubWFpbi5hc3luY0FmdGVyKGRlYWRsaW5lOiAubm93KCkgKyBzZXR0bGVEZWxheSkgewogICAgICAgICAgICBpZiAhaXNTY3JlZW5Mb2NrZWQoKSB7CiAgICAgICAgICAgICAgICBzdWNjZWVkZWQoYWZ0ZXI6IGluZGV4KQogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgaWYgIWlzTGFzdCB7IGxvZygiICDor6Xlr4bnoIHml6DmlYjvvIznu6fnu63lsJ3or5XkuIvkuIDkuKoiKSB9CiAgICAgICAgICAgICAgICB0cnlQYXNzd29yZChhdDogaW5kZXggKyAxKQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgdGljaygpIHsKICAgICAgICB3YWtlQXR0ZW1wdCArPSAxCiAgICAgICAgd2FrZURpc3BsYXkoKQoKICAgICAgICBpZiBpc1NjcmVlbkxvY2tlZCgpIHsKICAgICAgICAgICAgLy8g5YaN562JIDAuNHMg6K6p5a+G56CB6L6T5YWl5qGG6I635b6X54Sm54K5CiAgICAgICAgICAgIERpc3BhdGNoUXVldWUubWFpbi5hc3luY0FmdGVyKGRlYWRsaW5lOiAubm93KCkgKyAwLjQpIHsKICAgICAgICAgICAgICAgIHRyeVBhc3N3b3JkKGF0OiAwKQogICAgICAgICAgICB9CiAgICAgICAgICAgIHJldHVybgogICAgICAgIH0KCiAgICAgICAgaWYgd2FrZUF0dGVtcHQgPj0gbWF4V2FrZUF0dGVtcHRzIHsKICAgICAgICAgICAgdW5sb2NrSW5GbGlnaHQgPSBmYWxzZQogICAgICAgICAgICBsb2coIuino+mUgeS4reatou+8muWxj+W5leacquWkhOS6jumUgeWumueKtuaAge+8iOWPr+iDveW3sueUseeUqOaIt+aJi+WKqOino+mUge+8iSIpCiAgICAgICAgICAgIHJlcGx5KCJOT1RfTE9DS0VEIikKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgfQogICAgICAgIERpc3BhdGNoUXVldWUubWFpbi5hc3luY0FmdGVyKGRlYWRsaW5lOiAubm93KCkgKyAwLjUsIGV4ZWN1dGU6IHRpY2spCiAgICB9CgogICAgdGljaygpCn0KCmZ1bmMgcGVyZm9ybUxvY2socmVwbHk6IEBlc2NhcGluZyAoU3RyaW5nKSAtPiBWb2lkKSB7CiAgICBpZiBkcnlSdW4gewogICAgICAgIGxvZygiW2RyeS1ydW5dIOacrOW6lOmUgeWumuWxj+W5le+8jOW3sui3s+i/hyIpCiAgICAgICAgcmVwbHkoIk9LIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIGxvZygi5pS25Yiw6ZSB5a6a5oyH5LukIikKICAgIC8vIOmAmui/h+mUgeWxj+engeaciSBBUEkg6ZSB5a6a77yb6Iul5LiN5Y+v55So5YiZ6YCA5Zue5bGP5L+dCiAgICBsZXQgaGFuZGxlID0gZGxvcGVuKCIvU3lzdGVtL0xpYnJhcnkvUHJpdmF0ZUZyYW1ld29ya3MvbG9naW4uZnJhbWV3b3JrL2xvZ2luIiwgUlRMRF9OT1cpCiAgICBpZiBsZXQgaGFuZGxlID0gaGFuZGxlLCBsZXQgc3ltID0gZGxzeW0oaGFuZGxlLCAiU0FDTG9ja1NjcmVlbkltbWVkaWF0ZSIpIHsKICAgICAgICB0eXBlYWxpYXMgTG9ja0ZuID0gQGNvbnZlbnRpb24oYykgKCkgLT4gSW50MzIKICAgICAgICBsZXQgbG9jayA9IHVuc2FmZUJpdENhc3Qoc3ltLCB0bzogTG9ja0ZuLnNlbGYpCiAgICAgICAgbGV0IHJlc3VsdCA9IGxvY2soKQogICAgICAgIGRsY2xvc2UoaGFuZGxlKQogICAgICAgIGxvZygiU0FDTG9ja1NjcmVlbkltbWVkaWF0ZSDov5Tlm54gXChyZXN1bHQpIikKICAgICAgICByZXBseShyZXN1bHQgPT0gMCA/ICJPSyIgOiAiRVJSX0xPQ0siKQogICAgfSBlbHNlIHsKICAgICAgICBsb2coImxvZ2luLmZyYW1ld29yayDkuI3lj6/nlKjvvIzmlLnnlKjlsY/kv53plIHlrpoiKQogICAgICAgIFByb2Nlc3MubGF1bmNoZWRQcm9jZXNzKGxhdW5jaFBhdGg6ICIvdXNyL2Jpbi9vcGVuIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBhcmd1bWVudHM6IFsiLWEiLCAiU2NyZWVuU2F2ZXJFbmdpbmUiXSkKICAgICAgICByZXBseSgiT0tfU1MiKQogICAgfQogICAgc2xlZXBEaXNwbGF5KCkKfQoKLy8gTUFSSzogLSDpmLLph43mlL4KCmZpbmFsIGNsYXNzIE5vbmNlQ2FjaGUgewogICAgcHJpdmF0ZSB2YXIgc2VlbjogW1N0cmluZzogRGF0ZV0gPSBbOl0KICAgIHByaXZhdGUgbGV0IGxvY2sgPSBOU0xvY2soKQoKICAgIC8vLyDov5Tlm54gdHJ1ZSDooajnpLror6Ugbm9uY2Ug5piv5paw55qE77yI5pyq6KKr6YeN5pS+77yJCiAgICBmdW5jIGFjY2VwdChfIG5vbmNlOiBEYXRhKSAtPiBCb29sIHsKICAgICAgICBsZXQga2V5ID0gbm9uY2UuYmFzZTY0RW5jb2RlZFN0cmluZygpCiAgICAgICAgbG9jay5sb2NrKCkKICAgICAgICBkZWZlciB7IGxvY2sudW5sb2NrKCkgfQogICAgICAgIGxldCBub3cgPSBEYXRlKCkKICAgICAgICBzZWVuID0gc2Vlbi5maWx0ZXIgeyBub3cudGltZUludGVydmFsU2luY2UoJDAudmFsdWUpIDwgMzAwIH0KICAgICAgICBpZiBzZWVuW2tleV0gIT0gbmlsIHsgcmV0dXJuIGZhbHNlIH0KICAgICAgICBpZiBzZWVuLmNvdW50ID49IGtOb25jZUNhY2hlTGltaXQgewogICAgICAgICAgICBpZiBsZXQgb2xkZXN0ID0gc2Vlbi5taW4oYnk6IHsgJDAudmFsdWUgPCAkMS52YWx1ZSB9KT8ua2V5IHsgc2Vlbi5yZW1vdmVWYWx1ZShmb3JLZXk6IG9sZGVzdCkgfQogICAgICAgIH0KICAgICAgICBzZWVuW2tleV0gPSBub3cKICAgICAgICByZXR1cm4gdHJ1ZQogICAgfQp9CgpsZXQgbm9uY2VDYWNoZSA9IE5vbmNlQ2FjaGUoKQoKLy8gTUFSSzogLSDmlbDmja7ljIXmoKHpqowKCmVudW0gVmVyaWZ5UmVzdWx0IHsKICAgIC8vLyBjb21tYW5kIOaMh+S7pO+8m2luZGV4IOS4uuWtl+iKgiAyOCDnmoTlr4bnoIHluo/lj7fvvJtmb3JjZSDkuLrlrZfoioIgMjkg55qE6Lez6L+H6ZSB5bGP5qCh6aqM5qCH5b+XCiAgICBjYXNlIG9rKGNvbW1hbmQ6IFVJbnQ4LCBpbmRleDogVUludDg/LCBmb3JjZTogQm9vbCkKICAgIGNhc2UgZmFpbGVkKFN0cmluZykKfQoKZnVuYyB2ZXJpZnlQYWNrZXQoXyBkYXRhOiBEYXRhLCBrZXk6IFN5bW1ldHJpY0tleSkgLT4gVmVyaWZ5UmVzdWx0IHsKICAgIGd1YXJkIGRhdGEuY291bnQgPj0ga1BhY2tldExlbiBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9MRU4iKSB9CiAgICBsZXQgYnl0ZXMgPSBbVUludDhdKGRhdGEpCgogICAgZ3VhcmQgYnl0ZXNbMF0gPT0ga01hZ2ljWzBdLCBieXRlc1sxXSA9PSBrTWFnaWNbMV0gZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfTUFHSUMiKSB9CiAgICBndWFyZCBieXRlc1syXSA9PSBrVmVyc2lvbiBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9WRVIiKSB9CgogICAgbGV0IG5vdyA9IEludDY0KERhdGUoKS50aW1lSW50ZXJ2YWxTaW5jZTE5NzApCiAgICB2YXIgdHM6IEludDY0ID0gMAogICAgZm9yIGkgaW4gMC4uPDggeyB0cyA9ICh0cyA8PCA4KSB8IEludDY0KGJ5dGVzWzQgKyBpXSkgfQogICAgZ3VhcmQgYWJzKG5vdyAtIHRzKSA8PSBrVGltZXN0YW1wU2tldyBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9USU1FIikgfQoKICAgIGxldCBub25jZSA9IERhdGEoYnl0ZXNbMTIuLjwyOF0pCiAgICBndWFyZCBub25jZUNhY2hlLmFjY2VwdChub25jZSkgZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfUkVQTEFZIikgfQoKICAgIGxldCBtZXNzYWdlID0gRGF0YShieXRlc1swLi48a0htYWNPZmZzZXRdKQogICAgbGV0IGV4cGVjdGVkID0gRGF0YShITUFDPFNIQTI1Nj4uYXV0aGVudGljYXRpb25Db2RlKGZvcjogbWVzc2FnZSwgdXNpbmc6IGtleSkpCiAgICBsZXQgcmVjZWl2ZWQgPSBEYXRhKGJ5dGVzW2tIbWFjT2Zmc2V0Li48a1BhY2tldExlbl0pCiAgICAvLyDluLjph4/ml7bpl7Tmr5TovoMKICAgIGd1YXJkIGV4cGVjdGVkLmNvdW50ID09IHJlY2VpdmVkLmNvdW50IGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX0hNQUMiKSB9CiAgICB2YXIgZGlmZjogVUludDggPSAwCiAgICBmb3IgaSBpbiAwLi48ZXhwZWN0ZWQuY291bnQgeyBkaWZmIHw9IGV4cGVjdGVkW2ldIF4gcmVjZWl2ZWRbaV0gfQogICAgZ3VhcmQgZGlmZiA9PSAwIGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX0hNQUMiKSB9CgogICAgcmV0dXJuIC5vayhjb21tYW5kOiBieXRlc1szXSwKICAgICAgICAgICAgICAgaW5kZXg6IGV4dHJhY3RQYXNzd29yZEluZGV4KGJ5dGVzKSwKICAgICAgICAgICAgICAgZm9yY2U6IGV4dHJhY3RGb3JjZUZsYWcoYnl0ZXMpKQp9CgovLyBNQVJLOiAtIEJMRSDlpJborr4KCmZpbmFsIGNsYXNzIFBlcmlwaGVyYWxTZXJ2ZXI6IE5TT2JqZWN0LCBDQlBlcmlwaGVyYWxNYW5hZ2VyRGVsZWdhdGUgewogICAgcHJpdmF0ZSB2YXIgbWFuYWdlcjogQ0JQZXJpcGhlcmFsTWFuYWdlciEKICAgIHByaXZhdGUgdmFyIGNvbW1hbmRDaGFyOiBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyEKICAgIHByaXZhdGUgdmFyIHN0YXR1c0NoYXI6IENCTXV0YWJsZUNoYXJhY3RlcmlzdGljIQogICAgcHJpdmF0ZSB2YXIga2V5OiBTeW1tZXRyaWNLZXkhCiAgICBwcml2YXRlIHZhciBkZXZpY2VOYW1lOiBTdHJpbmcgPSAiQkxFVW5sb2NrLU1hYyIKICAgIHByaXZhdGUgdmFyIGFkdmVydGlzZVRpbWVyOiBUaW1lcj8KICAgIHByaXZhdGUgdmFyIHN0YXR1c1ZhbHVlID0gIlJFQURZIgoKICAgIGZ1bmMgc3RhcnQoa2V5OiBTeW1tZXRyaWNLZXksIGRldmljZU5hbWU6IFN0cmluZykgewogICAgICAgIHNlbGYua2V5ID0ga2V5CiAgICAgICAgc2VsZi5kZXZpY2VOYW1lID0gZGV2aWNlTmFtZQogICAgICAgIG1hbmFnZXIgPSBDQlBlcmlwaGVyYWxNYW5hZ2VyKGRlbGVnYXRlOiBzZWxmLCBxdWV1ZTogbmlsKQogICAgfQoKICAgIHByaXZhdGUgZnVuYyBidWlsZFNlcnZpY2UoKSB7CiAgICAgICAgY29tbWFuZENoYXIgPSBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyh0eXBlOiBrQ2hhckNvbW1hbmRVVUlELAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcHJvcGVydGllczogWy53cml0ZSwgLndyaXRlV2l0aG91dFJlc3BvbnNlXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBuaWwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwZXJtaXNzaW9uczogWy53cml0ZWFibGVdKQoKICAgICAgICAvLyDms6jmhI/vvJrluKYgLm5vdGlmeS8ucmVhZCDnmoTnibnlvoHkuI3og73pooTnva7nvJPlrZjlgLzvvIhDb3JlQmx1ZXRvb3RoIOS8muaKmwogICAgICAgIC8vICJDaGFyYWN0ZXJpc3RpY3Mgd2l0aCBjYWNoZWQgdmFsdWVzIG11c3QgYmUgcmVhZC1vbmx5Iu+8ie+8jAogICAgICAgIC8vIOWboOatpOi/memHjCB2YWx1ZSDlv4XpobvmmK8gbmls77yM6K+75Y+W5pe25ZyoIGRpZFJlY2VpdmVSZWFkIOmHjOWKqOaAgei/lOWbnuOAggogICAgICAgIHN0YXR1c0NoYXIgPSBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyh0eXBlOiBrQ2hhclN0YXR1c1VVSUQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3BlcnRpZXM6IFsucmVhZCwgLm5vdGlmeV0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBuaWwsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHBlcm1pc3Npb25zOiBbLnJlYWRhYmxlXSkKCiAgICAgICAgLy8g5Y+q6K+75LiU5YC85Zu65a6a55qE54m55b6B5Y+v5Lul6aKE572u57yT5a2Y5YC877yM5a+55omL5py656uv5pu055yB5LiA5qyh5Lqk5LqSCiAgICAgICAgbGV0IGluZm8gPSAiQkxFVW5sb2NrQ21kIHYxO1woZGV2aWNlTmFtZSkiCiAgICAgICAgbGV0IGluZm9DaGFyID0gQ0JNdXRhYmxlQ2hhcmFjdGVyaXN0aWModHlwZToga0NoYXJJbmZvVVVJRCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwcm9wZXJ0aWVzOiBbLnJlYWRdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHZhbHVlOiBpbmZvLmRhdGEodXNpbmc6IC51dGY4KSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwZXJtaXNzaW9uczogWy5yZWFkYWJsZV0pCgogICAgICAgIGxldCBzZXJ2aWNlID0gQ0JNdXRhYmxlU2VydmljZSh0eXBlOiBrU2VydmljZVVVSUQsIHByaW1hcnk6IHRydWUpCiAgICAgICAgc2VydmljZS5jaGFyYWN0ZXJpc3RpY3MgPSBbY29tbWFuZENoYXIsIHN0YXR1c0NoYXIsIGluZm9DaGFyXQogICAgICAgIG1hbmFnZXIuYWRkKHNlcnZpY2UpCiAgICB9CgogICAgcHJpdmF0ZSBmdW5jIHN0YXJ0QWR2ZXJ0aXNpbmcoKSB7CiAgICAgICAgZ3VhcmQgbWFuYWdlci5zdGF0ZSA9PSAucG93ZXJlZE9uIGVsc2UgeyByZXR1cm4gfQogICAgICAgIGd1YXJkICFtYW5hZ2VyLmlzQWR2ZXJ0aXNpbmcgZWxzZSB7IHJldHVybiB9CiAgICAgICAgbWFuYWdlci5zdGFydEFkdmVydGlzaW5nKFsKICAgICAgICAgICAgQ0JBZHZlcnRpc2VtZW50RGF0YVNlcnZpY2VVVUlEc0tleTogW2tTZXJ2aWNlVVVJRF0sCiAgICAgICAgICAgIENCQWR2ZXJ0aXNlbWVudERhdGFMb2NhbE5hbWVLZXk6IGRldmljZU5hbWUsCiAgICAgICAgXSkKICAgIH0KCiAgICBmdW5jIHNldFN0YXR1cyhfIHRleHQ6IFN0cmluZykgewogICAgICAgIHN0YXR1c1ZhbHVlID0gdGV4dAogICAgICAgIC8vIOazqOaEj++8muS4jeimgee7mSBzdGF0dXNDaGFyLnZhbHVlIOi1i+WAvOOAguW4piAubm90aWZ5IOeahOeJueW+geS4gOaXpuiiq+i1i+S6iOe8k+WtmOWAvO+8jAogICAgICAgIC8vIOS5i+WQjiBtYW5hZ2VyLmFkZChzZXJ2aWNlKSDkvJrmipsgIkNoYXJhY3RlcmlzdGljcyB3aXRoIGNhY2hlZCB2YWx1ZXMgbXVzdCBiZSByZWFkLW9ubHki44CCCiAgICAgICAgLy8g6K+75Y+W55SxIGRpZFJlY2VpdmVSZWFkIOWKqOaAgei/lOWbnu+8jOaOqOmAgei1sCB1cGRhdGVWYWx1ZeOAggogICAgICAgIGd1YXJkIG1hbmFnZXIuc3RhdGUgPT0gLnBvd2VyZWRPbiwgbGV0IGNoYXJhY3RlcmlzdGljID0gc3RhdHVzQ2hhciBlbHNlIHsgcmV0dXJuIH0KICAgICAgICBpZiAhbWFuYWdlci51cGRhdGVWYWx1ZSh0ZXh0LmRhdGEodXNpbmc6IC51dGY4KSEsIGZvcjogY2hhcmFjdGVyaXN0aWMsIG9uU3Vic2NyaWJlZENlbnRyYWxzOiBuaWwpIHsKICAgICAgICAgICAgLy8g6Zif5YiX5bey5ruh77yM562JIHBlcmlwaGVyYWxNYW5hZ2VySXNSZWFkeSDml7booaXlj5EKICAgICAgICAgICAgcGVuZGluZ1N0YXR1cyA9IHRleHQKICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlckRpZFVwZGF0ZVN0YXRlKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlcikgewogICAgICAgIHN3aXRjaCBwZXJpcGhlcmFsLnN0YXRlIHsKICAgICAgICBjYXNlIC5wb3dlcmVkT246CiAgICAgICAgICAgIGxvZygi6JOd54mZ5bey5bCx57uq77yM5rOo5YaMIEdBVFQg5pyN5YqhIikKICAgICAgICAgICAgYnVpbGRTZXJ2aWNlKCkKICAgICAgICAgICAgc3RhcnRBZHZlcnRpc2luZygpCiAgICAgICAgICAgIC8vIOWumuacn+mHjeaWsOW5v+aSre+8jOmBv+WFjemUgeWxjy/ns7vnu5/kvJHnnKDlkI7lub/mkq3ooqvlgZzmjokKICAgICAgICAgICAgYWR2ZXJ0aXNlVGltZXI/LmludmFsaWRhdGUoKQogICAgICAgICAgICBhZHZlcnRpc2VUaW1lciA9IFRpbWVyLnNjaGVkdWxlZFRpbWVyKHdpdGhUaW1lSW50ZXJ2YWw6IDIwLCByZXBlYXRzOiB0cnVlKSB7IFt3ZWFrIHNlbGZdIF8gaW4KICAgICAgICAgICAgICAgIHNlbGY/LnN0YXJ0QWR2ZXJ0aXNpbmcoKQogICAgICAgICAgICB9CiAgICAgICAgICAgIFJ1bkxvb3AubWFpbi5hZGQoYWR2ZXJ0aXNlVGltZXIhLCBmb3JNb2RlOiAuY29tbW9uKQogICAgICAgICAgICBzZXRTdGF0dXMoIlJFQURZIikKICAgICAgICBjYXNlIC5wb3dlcmVkT2ZmOgogICAgICAgICAgICBsb2coIuiTneeJmeW3suWFs+mXre+8jOetieW+hemHjeaWsOW8gOWQryIpCiAgICAgICAgY2FzZSAudW5hdXRob3JpemVkOgogICAgICAgICAgICBsb2coIuiTneeJmeadg+mZkOiiq+aLkue7ne+8jOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDok53niZnjgI3kuK3mjojmnYMiKQogICAgICAgIGRlZmF1bHQ6CiAgICAgICAgICAgIGJyZWFrCiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXJEaWRTdGFydEFkdmVydGlzaW5nKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwgZXJyb3I6IEVycm9yPykgewogICAgICAgIGlmIGxldCBlcnJvciA9IGVycm9yIHsKICAgICAgICAgICAgbG9nKCLlub/mkq3lpLHotKU6IFwoZXJyb3IubG9jYWxpemVkRGVzY3JpcHRpb24pIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBsb2coIuato+WcqOW5v+aSre+8jOetieW+heaJi+acuui/nuaOpe+8iOiuvuWkh+WQjSBcKGRldmljZU5hbWUp77yJIikKICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsIGRpZEFkZCBzZXJ2aWNlOiBDQlNlcnZpY2UsIGVycm9yOiBFcnJvcj8pIHsKICAgICAgICBpZiBsZXQgZXJyb3IgPSBlcnJvciB7CiAgICAgICAgICAgIGxvZygi5re75Yqg5pyN5Yqh5aSx6LSlOiBcKGVycm9yLmxvY2FsaXplZERlc2NyaXB0aW9uKSIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9nKCJHQVRUIOacjeWKoeW3suWwsee7qu+8iFNlcnZpY2UgXChrU2VydmljZVVVSUQudXVpZFN0cmluZynvvIkiKQogICAgICAgIH0KICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwgY2VudHJhbDogQ0JDZW50cmFsLCBkaWRTdWJzY3JpYmVUbyBjaGFyYWN0ZXJpc3RpYzogQ0JDaGFyYWN0ZXJpc3RpYykgewogICAgICAgIGxvZygi5omL5py65bey6K6i6ZiF54q25oCB54m55b6BOiBcKGNlbnRyYWwuaWRlbnRpZmllci51dWlkU3RyaW5nKSIpCiAgICAgICAgc2V0U3RhdHVzKCJDT05ORUNURUQiKQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXIoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLCBjZW50cmFsOiBDQkNlbnRyYWwsIGRpZFVuc3Vic2NyaWJlRnJvbSBjaGFyYWN0ZXJpc3RpYzogQ0JDaGFyYWN0ZXJpc3RpYykgewogICAgICAgIGxvZygi5omL5py65Y+W5raI6K6i6ZiF54q25oCB54m55b6BIikKICAgIH0KCiAgICBwcml2YXRlIHZhciBwZW5kaW5nU3RhdHVzOiBTdHJpbmc/CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcklzUmVhZHkodG9VcGRhdGVTdWJzY3JpYmVycyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyKSB7CiAgICAgICAgLy8g5LiK5LiA5qyhIHVwZGF0ZVZhbHVlIOWboOWPkemAgemYn+WIl+a7oeiAjOWksei0pe+8jOi/memHjOihpeWPkQogICAgICAgIGd1YXJkIGxldCB0ZXh0ID0gcGVuZGluZ1N0YXR1cywgbWFuYWdlci5zdGF0ZSA9PSAucG93ZXJlZE9uLCBsZXQgY2hhcmFjdGVyaXN0aWMgPSBzdGF0dXNDaGFyIGVsc2UgeyByZXR1cm4gfQogICAgICAgIHBlbmRpbmdTdGF0dXMgPSBuaWwKICAgICAgICBtYW5hZ2VyLnVwZGF0ZVZhbHVlKHRleHQuZGF0YSh1c2luZzogLnV0ZjgpISwgZm9yOiBjaGFyYWN0ZXJpc3RpYywgb25TdWJzY3JpYmVkQ2VudHJhbHM6IG5pbCkKICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwKICAgICAgICAgICAgICAgICAgICAgICAgICAgZGlkUmVjZWl2ZVdyaXRlIHJlcXVlc3RzOiBbQ0JBVFRSZXF1ZXN0XSkgewogICAgICAgIGZvciByZXF1ZXN0IGluIHJlcXVlc3RzIHsKICAgICAgICAgICAgZ3VhcmQgcmVxdWVzdC5jaGFyYWN0ZXJpc3RpYy51dWlkID09IGtDaGFyQ29tbWFuZFVVSUQgZWxzZSB7IGNvbnRpbnVlIH0KICAgICAgICAgICAgbGV0IGRhdGEgPSByZXF1ZXN0LnZhbHVlID8/IERhdGEoKQogICAgICAgICAgICBsb2coIuaUtuWIsOWGmeWFpSBcKGRhdGEuY291bnQpIOWtl+iKgiIpCgogICAgICAgICAgICAvLyDml6DorrrmoKHpqoznu5PmnpzlpoLkvZXpg73opoHlupTnrZTvvJvluKblupTnrZTlhpnkuI3lm57kvJrorqnmiYvmnLrnq6/ljaHkvY8KICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuc3VjY2VzcykKCiAgICAgICAgICAgIGxldCByZXN1bHQgPSB2ZXJpZnlQYWNrZXQoZGF0YSwga2V5OiBrZXkpCiAgICAgICAgICAgIHN3aXRjaCByZXN1bHQgewogICAgICAgICAgICBjYXNlIC5mYWlsZWQobGV0IHJlYXNvbik6CiAgICAgICAgICAgICAgICBsb2coIuagoemqjOWksei0pTogXChyZWFzb24pIikKICAgICAgICAgICAgICAgIHNldFN0YXR1cyhyZWFzb24pCgogICAgICAgICAgICBjYXNlIC5vayhsZXQgY29tbWFuZCwgbGV0IGluZGV4LCBsZXQgZm9yY2UpOgogICAgICAgICAgICAgICAgc3dpdGNoIGNvbW1hbmQgewogICAgICAgICAgICAgICAgY2FzZSBrQ21kVW5sb2NrRnJvbToKICAgICAgICAgICAgICAgICAgICAvLyDmiYvmnLrmjIflrprkuobopoHnlKjnrKzlh6DkuKrlr4bnoIHvvJtmb3JjZSDml7bot7Pov4fplIHlsY/moKHpqowKICAgICAgICAgICAgICAgICAgICBzZXRTdGF0dXMoIlVOTE9DS0lORyIpCiAgICAgICAgICAgICAgICAgICAgcGVyZm9ybVVubG9jayhwcmVmZXJyZWRJbmRleDogaW5kZXgsIGZvcmNlOiBmb3JjZSkgeyBzdGF0dXMgaW4KICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5zZXRTdGF0dXMoc3RhdHVzKQogICAgICAgICAgICAgICAgICAgICAgICBsb2coIuino+mUgee7k+aenDogXChzdGF0dXMpIikKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBjYXNlIGtDbWRVbmxvY2s6CiAgICAgICAgICAgICAgICAgICAgc2V0U3RhdHVzKCJVTkxPQ0tJTkciKQogICAgICAgICAgICAgICAgICAgIHBlcmZvcm1VbmxvY2sgeyBzdGF0dXMgaW4KICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5zZXRTdGF0dXMoc3RhdHVzKQogICAgICAgICAgICAgICAgICAgICAgICBsb2coIuino+mUgee7k+aenDogXChzdGF0dXMpIikKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBjYXNlIGtDbWRMb2NrOgogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiTE9DS0lORyIpCiAgICAgICAgICAgICAgICAgICAgcGVyZm9ybUxvY2sgeyBzdGF0dXMgaW4KICAgICAgICAgICAgICAgICAgICAgICAgc2VsZi5zZXRTdGF0dXMoc3RhdHVzKQogICAgICAgICAgICAgICAgICAgICAgICBsb2coIumUgeWumue7k+aenDogXChzdGF0dXMpIikKICAgICAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgICAgICBjYXNlIGtDbWRQaW5nOgogICAgICAgICAgICAgICAgICAgIGxvZygi5pS25YiwIFBJTkciKQogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiUE9ORyIpCiAgICAgICAgICAgICAgICBkZWZhdWx0OgogICAgICAgICAgICAgICAgICAgIGxvZygi5pyq55+l5oyH5LukIDB4XChTdHJpbmcoY29tbWFuZCwgcmFkaXg6IDE2KSkiKQogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiRVJSX0NNRCIpCiAgICAgICAgICAgICAgICB9CiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgIGRpZFJlY2VpdmVSZWFkIHJlcXVlc3Q6IENCQVRUUmVxdWVzdCkgewogICAgICAgIGlmIHJlcXVlc3QuY2hhcmFjdGVyaXN0aWMudXVpZCA9PSBrQ2hhclN0YXR1c1VVSUQgewogICAgICAgICAgICBsZXQgZGF0YSA9IHN0YXR1c1ZhbHVlLmRhdGEodXNpbmc6IC51dGY4KSEKICAgICAgICAgICAgaWYgcmVxdWVzdC5vZmZzZXQgPiBkYXRhLmNvdW50IHsKICAgICAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLmludmFsaWRPZmZzZXQpCiAgICAgICAgICAgICAgICByZXR1cm4KICAgICAgICAgICAgfQogICAgICAgICAgICByZXF1ZXN0LnZhbHVlID0gZGF0YS5zdWJkYXRhKGluOiByZXF1ZXN0Lm9mZnNldC4uPGRhdGEuY291bnQpCiAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLnN1Y2Nlc3MpCiAgICAgICAgfSBlbHNlIGlmIHJlcXVlc3QuY2hhcmFjdGVyaXN0aWMudXVpZCA9PSBrQ2hhckluZm9VVUlEIHsKICAgICAgICAgICAgbGV0IGRhdGEgPSAiQkxFVW5sb2NrQ21kIHYxO1woZGV2aWNlTmFtZSkiLmRhdGEodXNpbmc6IC51dGY4KSEKICAgICAgICAgICAgcmVxdWVzdC52YWx1ZSA9IGRhdGEKICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuc3VjY2VzcykKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBwZXJpcGhlcmFsLnJlc3BvbmQodG86IHJlcXVlc3QsIHdpdGhSZXN1bHQ6IC5hdHRyaWJ1dGVOb3RGb3VuZCkKICAgICAgICB9CiAgICB9Cn0KCi8vIE1BUks6IC0g5YWl5Y+jCgpmdW5jIHByaW50VXNhZ2UoKSB7CiAgICBwcmludCgiIiIKICAgIEJMRVVubG9ja0NtZCDigJQg55So5omL5py66YCa6L+H6JOd54mZ6Kej6ZSB6L+Z5Y+wIE1hYwoKICAgIOeUqOazlTogQkxFVW5sb2NrQ21kIFvpgInpobldCgogICAgICAtLXByaW50LXRva2VuICAgICAgICDmiZPljbDphY3lr7nku6TniYzvvIjlnKjmiYvmnLogQXBwIOS4reWhq+WGmei/meS4quWAvO+8iQogICAgICAtLXNldC1rZXkgPGJhc2U2ND4gICDlhpnlhaXmjIflrprnmoTphY3lr7nlr4bpkqUKICAgICAgLS1kZXZpY2UtbmFtZSA85ZCNPiAgIOW5v+aSreeahOiuvuWkh+WQjQogICAgICAtLWFkZC1hY2Nlc3NpYmlsaXR5ICDmiZPlvIDjgIzovoXliqnlip/og73jgI3mjojmnYPmj5DnpLoKICAgICAgLS1jaGVjayAgICAgICAgICAgICAg6Ieq5qOA77ya5omT5Y2w5p2D6ZmQ44CB6ZKl5YyZ5Liy5LiO6YWN572u54q25oCBCiAgICAgIC0tZHJ5LXJ1biAgICAgICAgICAgIOWuieWFqOa1i+ivleaooeW8j++8mui1sOWujCBCTEUg5pS25YyF5LiO5qCh6aqM77yM5L2G5LiN55yf55qE6Kej6ZSBCiAgICAgIC0tc2hvdy10b2tlbiAgICAgICAgIOaJk+WNsOmFjeWvueS7pOeJjO+8iOacquWuieijheaXtuiHquWKqOeUn+aIkOS4gOS4quS4tOaXtuWvhumSpe+8iQogICAgICAtLXNlbGZ0ZXN0IDxoZXg+ICAgICDljY/orq7oh6rmo4DvvJrlr7nnu5nlrprnmoTljYHlha3ov5vliLbmtojmga/ovpPlh7ogSE1BQy1TSEEyNTYKICAgICAgLS12ZXJzaW9uICAgICAgICAgICAg5pi+56S654mI5pysCiAgICAiIiIpCn0KCmVuc3VyZVN1cHBvcnREaXJlY3RvcnkoKQoKbGV0IGFyZ3MgPSBBcnJheShDb21tYW5kTGluZS5hcmd1bWVudHMuZHJvcEZpcnN0KCkpCgppZiBhcmdzLmNvbnRhaW5zKCItLXZlcnNpb24iKSB7CiAgICBwcmludCgiQkxFVW5sb2NrQ21kIDEuMC4wIikKICAgIGV4aXQoMCkKfQoKLy8g5Y2P6K6u6Zet546v6Ieq5qOA77ya5LiN5L6d6LWW6JOd54mZ77yM55u05o6l6LWwIuaUtuWMhSAtPiDmoKHpqowgLT4g5omn6KGMIuWFqOa1geeoiwppZiBhcmdzLmNvbnRhaW5zKCItLXNlbGZ0ZXN0LXByb3RvY29sIikgewogICAgZHJ5UnVuID0gdHJ1ZQogICAgdmFyIGZhaWxlZCA9IDAKCiAgICBmdW5jIGV4cGVjdChfIGxhYmVsOiBTdHJpbmcsIF8gb2s6IEJvb2wsIF8gZGV0YWlsOiBTdHJpbmcgPSAiIikgewogICAgICAgIGlmIG9rIHsKICAgICAgICAgICAgcHJpbnQoIiAg4pyTIFwobGFiZWwpIikKICAgICAgICB9IGVsc2UgewogICAgICAgICAgICBwcmludCgiICDinJcgXChsYWJlbCkgIFwoZGV0YWlsKSIpCiAgICAgICAgICAgIGZhaWxlZCArPSAxCiAgICAgICAgfQogICAgfQoKICAgIC8vIOeUqOS4tOaXtuWvhumSpeaehOmAoOa1i+ivleWMhQogICAgdmFyIGtleUJ5dGVzID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiAzMikKICAgIGZvciBpIGluIDAuLjwzMiB7IGtleUJ5dGVzW2ldID0gVUludDgoaSkgfQogICAgbGV0IHRlc3RLZXkgPSBTeW1tZXRyaWNLZXkoZGF0YTogRGF0YShrZXlCeXRlcykpCgogICAgZnVuYyBtYWtlUGFja2V0KGNvbW1hbmQ6IFVJbnQ4LCB0aW1lc3RhbXA6IEludDY0ID0gSW50NjQoRGF0ZSgpLnRpbWVJbnRlcnZhbFNpbmNlMTk3MCksCiAgICAgICAgICAgICAgICAgICAgbm9uY2U6IERhdGE/ID0gbmlsLCB0YW1wZXI6IEJvb2wgPSBmYWxzZSkgLT4gRGF0YSB7CiAgICAgICAgdmFyIG1lc3NhZ2UgPSBEYXRhKFsweDQyLCAweDU1LCAweDAxLCBjb21tYW5kXSkKICAgICAgICB2YXIgdHMgPSBVSW50NjQoYml0UGF0dGVybjogdGltZXN0YW1wKS5iaWdFbmRpYW4KICAgICAgICB3aXRoVW5zYWZlQnl0ZXMob2Y6ICZ0cykgeyBtZXNzYWdlLmFwcGVuZChjb250ZW50c09mOiAkMCkgfQogICAgICAgIHZhciBuID0gbm9uY2UgPz8gRGF0YSgoMC4uPDE2KS5tYXAgeyBfIGluIFVJbnQ4LnJhbmRvbShpbjogMC4uLjI1NSkgfSkKICAgICAgICBpZiBuLmNvdW50ICE9IDE2IHsgbiA9IERhdGEocmVwZWF0aW5nOiAwLCBjb3VudDogMTYpIH0KICAgICAgICBtZXNzYWdlLmFwcGVuZChuKQogICAgICAgIG1lc3NhZ2UuYXBwZW5kKGNvbnRlbnRzT2Y6IFsweDAwLCAweDAwXSkKICAgICAgICB2YXIgdGFnID0gRGF0YShITUFDPFNIQTI1Nj4uYXV0aGVudGljYXRpb25Db2RlKGZvcjogbWVzc2FnZSwgdXNpbmc6IHRlc3RLZXkpKQogICAgICAgIGlmIHRhbXBlciB7IHRhZ1swXSBePSAweEZGIH0KICAgICAgICByZXR1cm4gbWVzc2FnZSArIHRhZwogICAgfQoKICAgIHByaW50KCI9PSDmiqXmlofmoKHpqowgPT0iKQoKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vayhsZXQgYywgbGV0IGksIGxldCBmKToKICAgICAgICBleHBlY3QoIuWQiOazleino+mUgeWMhemAmui/h+agoemqjCIsIGMgPT0ga0NtZFVubG9jaywgIuWRveS7pD1cKGMpIikKICAgICAgICBleHBlY3QoIuaZrumAmuino+mUgeS4jeW4puWvhueggeW6j+WPtyIsIGkgPT0gbmlsLCAi5a6e6ZmFIFwoU3RyaW5nKGRlc2NyaWJpbmc6IGkpKSIpCiAgICAgICAgZXhwZWN0KCLmma7pgJrop6PplIHkuI3ot7Pov4fplIHlsY/moKHpqowiLCBmID09IGZhbHNlKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLlkIjms5Xop6PplIHljIXpgJrov4fmoKHpqowiLCBmYWxzZSwgcikKICAgIH0KCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFBpbmcpLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rKGxldCBjLCBfLCBfKTogZXhwZWN0KCJQSU5HIOWMhemAmui/h+agoemqjCIsIGMgPT0ga0NtZFBpbmcsICLlkb3ku6Q9XChjKSIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIlBJTkcg5YyF6YCa6L+H5qCh6aqMIiwgZmFsc2UsIHIpCiAgICB9CgogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2ssIHRhbXBlcjogdHJ1ZSksIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi56+h5pS555qEIEhNQUMg5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLnr6HmlLnnmoQgSE1BQyDooqvmi5Lnu50iLCByID09ICJFUlJfSE1BQyIsIHIpCiAgICB9CgogICAgbGV0IHdyb25nS2V5ID0gU3ltbWV0cmljS2V5KGRhdGE6IERhdGEocmVwZWF0aW5nOiAweEFCLCBjb3VudDogMzIpKQogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2spLCBrZXk6IHdyb25nS2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLplJnor6/lr4bpkqXlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIumUmeivr+WvhumSpeiiq+aLkue7nSIsIHIgPT0gIkVSUl9ITUFDIiwgcikKICAgIH0KCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KERhdGEoWzB4NDIsIDB4NTUsIDB4MDFdKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLov4fnn63nmoTljIXlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIui/h+efreeahOWMheiiq+aLkue7nSIsIHIgPT0gIkVSUl9MRU4iLCByKQogICAgfQoKICAgIHZhciBiYWRNYWdpYyA9IG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jaykKICAgIGJhZE1hZ2ljWzBdID0gMHgwMAogICAgc3dpdGNoIHZlcmlmeVBhY2tldChiYWRNYWdpYywga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLplJnor6/prZTmlbDlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIumUmeivr+mtlOaVsOiiq+aLkue7nSIsIHIgPT0gIkVSUl9NQUdJQyIsIHIpCiAgICB9CgogICAgbGV0IHN0YWxlID0gSW50NjQoRGF0ZSgpLnRpbWVJbnRlcnZhbFNpbmNlMTk3MCkgLSA2MDAKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrLCB0aW1lc3RhbXA6IHN0YWxlKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLov4fmnJ/ml7bpl7TmiLPlv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIui/h+acn+aXtumXtOaIs+iiq+aLkue7nSIsIHIgPT0gIkVSUl9USU1FIiwgcikKICAgIH0KCiAgICBwcmludCgpCiAgICBwcmludCgiPT0g6Ziy6YeN5pS+ID09IikKICAgIGxldCBmaXhlZE5vbmNlID0gRGF0YShyZXBlYXRpbmc6IDB4NUEsIGNvdW50OiAxNikKICAgIGxldCBwMSA9IG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jaywgbm9uY2U6IGZpeGVkTm9uY2UpCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KHAxLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIuWQjOS4gCBub25jZSDpppbmrKHpgJrov4ciLCB0cnVlKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLlkIzkuIAgbm9uY2Ug6aaW5qyh6YCa6L+HIiwgZmFsc2UsIHIpCiAgICB9CiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KHAxLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIuWQjOS4gCBub25jZSDph43mlL7lv4Xpobvooqvmi5Lnu50iLCBmYWxzZSwgIuWxheeEtumAmui/h+S6hiIpCiAgICBjYXNlIC5mYWlsZWQobGV0IHIpOiBleHBlY3QoIuWQjOS4gCBub25jZSDph43mlL7ooqvmi5Lnu50iLCByID09ICJFUlJfUkVQTEFZIiwgcikKICAgIH0KCiAgICBwcmludCgpCiAgICBwcmludCgiPT0g6Kej6ZSB5rWB56iL77yIZHJ5LXJ1bu+8jOS4jeS8muecn+eahOazqOWFpeWvhuegge+8iT09IikKICAgIC8vIOmAoOS4gOS4quS4tOaXtumFjee9ru+8jOaMh+WQkeS4gOS4quS4jeWtmOWcqOeahOmSpeWMmeS4sui0puaIt++8jOmihOacn+W+l+WIsCBFUlJfTk9fUFcKICAgIGxldCB0ZW1wQ29uZmlnID0gQ29uZmlnKGhtYWNLZXk6IERhdGEoa2V5Qnl0ZXMpLmJhc2U2NEVuY29kZWRTdHJpbmcoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtleWNoYWluQWNjb3VudDogIl9fYmxldW5sb2NrX3NlbGZ0ZXN0X25vbmV4aXN0ZW50X18iLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgZGV2aWNlTmFtZTogIlNFTEZURVNUIikKICAgIGxldCBlbmMgPSBKU09ORW5jb2RlcigpCiAgICBlbmMub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuYy5lbmNvZGUodGVtcENvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKCiAgICB2YXIgdW5sb2NrUmVzdWx0ID0gIiIKICAgIGxldCBzZW0gPSBEaXNwYXRjaFNlbWFwaG9yZSh2YWx1ZTogMCkKICAgIHBlcmZvcm1VbmxvY2sgeyBzdGF0dXMgaW4KICAgICAgICB1bmxvY2tSZXN1bHQgPSBzdGF0dXMKICAgICAgICBzZW0uc2lnbmFsKCkKICAgIH0KICAgIF8gPSBzZW0ud2FpdCh0aW1lb3V0OiAubm93KCkgKyAyMCkKICAgIGV4cGVjdCgi57y65bCR6ZKl5YyZ5Liy5a+G56CB5pe26L+U5ZueIEVSUl9OT19QVyIsIHVubG9ja1Jlc3VsdCA9PSAiRVJSX05PX1BXIiwgIuWunumZhSBcKHVubG9ja1Jlc3VsdCkiKQoKICAgIC8vIOWkmuWvhuegge+8mmRyeS1ydW4g5bqU6IO96K+G5Yir5Ye65YWo6YOo5a+G56CB5bm26YCQ5Liq5bCd6K+VCiAgICBsZXQgdGVzdEFjY291bnQgPSAiX19ibGV1bmxvY2tfc2VsZnRlc3RfbXVsdGlfXyIKICAgIHN0b3JlUGFzc3dvcmRzKFsic2VsZnRlc3QtcHctMSIsICJzZWxmdGVzdC1wdy0yIiwgInNlbGZ0ZXN0LXB3LTMiXSwgYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBsZXQgcmVhZEJhY2sgPSBmZXRjaFBhc3N3b3JkcyhhY2NvdW50OiB0ZXN0QWNjb3VudCkKICAgIGV4cGVjdCgi5aSa5a+G56CB5Y+v5YaZ5YWl5bm26K+75ZueIDMg5LiqIiwgcmVhZEJhY2suY291bnQgPT0gMywgIuWunumZhSBcKHJlYWRCYWNrLmNvdW50KSIpCiAgICBleHBlY3QoIumhuuW6j+S/neaMgSIsIHJlYWRCYWNrLmZpcnN0ID09ICJzZWxmdGVzdC1wdy0xIiAmJiByZWFkQmFjay5sYXN0ID09ICJzZWxmdGVzdC1wdy0zIiwKICAgICAgICAgICAi5a6e6ZmFIFwocmVhZEJhY2spIikKCiAgICBsZXQgbXVsdGlDb25maWcgPSBDb25maWcoaG1hY0tleTogRGF0YShrZXlCeXRlcykuYmFzZTY0RW5jb2RlZFN0cmluZygpLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIGtleWNoYWluQWNjb3VudDogdGVzdEFjY291bnQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgZGV2aWNlTmFtZTogIlNFTEZURVNUIikKICAgIHRyeT8gZW5jLmVuY29kZShtdWx0aUNvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKCiAgICB2YXIgbXVsdGlSZXN1bHQgPSAiIgogICAgbGV0IHNlbTIgPSBEaXNwYXRjaFNlbWFwaG9yZSh2YWx1ZTogMCkKICAgIHBlcmZvcm1VbmxvY2sgeyBzdGF0dXMgaW4KICAgICAgICBtdWx0aVJlc3VsdCA9IHN0YXR1cwogICAgICAgIHNlbTIuc2lnbmFsKCkKICAgIH0KICAgIF8gPSBzZW0yLndhaXQodGltZW91dDogLm5vdygpICsgMjApCiAgICBleHBlY3QoIuWkmuWvhueggSBkcnktcnVuIOi/lOWbniBPSyIsIG11bHRpUmVzdWx0ID09ICJPSyIsICLlrp7pmYUgXChtdWx0aVJlc3VsdCkiKQoKICAgIC8vIOeJueauiuWtl+espuW/hemhu+iDveWOn+agt+W+gOi/lO+8iOW8leWPt+OAgeWPjeaWnOadoOOAgeepuuagvOOAgeS4reaWh+OAgSTjgIHlj43lvJXlj7fvvIkKICAgIC8vIOi/meexu+Wtl+espuWcqCBzaGVsbCDnrqHpgZPph4zlrrnmmJPooqvlkIPmjonvvIzmiYDku6Xlv4XpobvlnKjku6PnoIHot6/lvoTkuIrpqozor4HjgIIKICAgIGxldCB0cmlja3kgPSBbInBAc3MgdzByZCIsICJ3aXRoXCJxdW90ZSIsICJ3aXRoXFxiYWNrc2xhc2giLCAi5Lit5paH5a+G56CBIiwKICAgICAgICAgICAgICAgICAgIiRkb2xsYXJgdGljayIsICJ0YWJcdGhlcmUiXQogICAgc3RvcmVQYXNzd29yZHModHJpY2t5LCBhY2NvdW50OiB0ZXN0QWNjb3VudCkKICAgIGxldCB0cmlja3lCYWNrID0gZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBleHBlY3QoIueJueauiuWtl+espuaVsOmHj+ato+ehriIsIHRyaWNreUJhY2suY291bnQgPT0gdHJpY2t5LmNvdW50LAogICAgICAgICAgICLlhpnlhaUgXCh0cmlja3kuY291bnQpIOivu+WbniBcKHRyaWNreUJhY2suY291bnQpIikKICAgIGV4cGVjdCgi54m55q6K5a2X56ym5YaF5a655Y6f5qC3IiwgdHJpY2t5QmFjayA9PSB0cmlja3ksICLlrp7pmYUgXCh0cmlja3lCYWNrKSIpCgogICAgLy8g56m65a+G56CB5bqU6KKr6L+H5ruk5o6J77yM5LiN6IO95Lqn55Sf5LiA5p2h56m65p2h55uuCiAgICBzdG9yZVBhc3N3b3JkcyhbImtlZXAtbWUiLCAiIiwgIiAgIl0sIGFjY291bnQ6IHRlc3RBY2NvdW50KQogICAgbGV0IGZpbHRlcmVkID0gZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBleHBlY3QoIuepuuWvhueggeiiq+i/h+a7pO+8iOS7hei/h+a7pOepuuS4su+8iSIsCiAgICAgICAgICAgZmlsdGVyZWQuZmlyc3QgPT0gImtlZXAtbWUiICYmICFmaWx0ZXJlZC5jb250YWlucygiIiksCiAgICAgICAgICAgIuWunumZhSBcKGZpbHRlcmVkLmNvdW50KSDkuKrvvJpcKGZpbHRlcmVkKSIpCgogICAgLy8g5pen5qC85byP5YW85a6577ya6ZKl5YyZ5Liy6YeM55u05o6l5pS+5piO5paHCiAgICBfID0gd3JpdGVLZXljaGFpblBhc3N3b3JkKCJsZWdhY3ktcGxhaW4iLCBhY2NvdW50OiB0ZXN0QWNjb3VudCkKICAgIGxldCBsZWdhY3kgPSBmZXRjaFBhc3N3b3JkcyhhY2NvdW50OiB0ZXN0QWNjb3VudCkKICAgIGV4cGVjdCgi5pen5qC85byP5Y2V5a+G56CB5Y+v6K+G5YirIiwgbGVnYWN5ID09IFsibGVnYWN5LXBsYWluIl0sICLlrp7pmYUgXChsZWdhY3kpIikKCiAgICAvLyDmiqXmlofph4znmoQi6Lez6L+H6ZSB5bGP5qCh6aqMIuagh+W/lwogICAgZnVuYyBwYWNrZXRXaXRoRm9yY2UoXyBmbGFnOiBVSW50OCwgY29tbWFuZDogVUludDggPSBrQ21kVW5sb2NrRnJvbSkgLT4gW1VJbnQ4XSB7CiAgICAgICAgdmFyIGIgPSBbVUludDhdKHJlcGVhdGluZzogMCwgY291bnQ6IGtQYWNrZXRMZW4pCiAgICAgICAgYlswXSA9IDB4NDI7IGJbMV0gPSAweDU1OyBiWzJdID0gMHgwMTsgYlszXSA9IGNvbW1hbmQKICAgICAgICBiW2tJbmRleE9mZnNldF0gPSAxCiAgICAgICAgYltrRm9yY2VPZmZzZXRdID0gZmxhZwogICAgICAgIHJldHVybiBiCiAgICB9CiAgICBleHBlY3QoIuagh+W/lyAxIOKGkiDop6PmnpDkuLrlvLrliLYiLCBleHRyYWN0Rm9yY2VGbGFnKHBhY2tldFdpdGhGb3JjZSgxKSkpCiAgICBleHBlY3QoIuagh+W/lyAwIOKGkiDkuI3lvLrliLYiLCBleHRyYWN0Rm9yY2VGbGFnKHBhY2tldFdpdGhGb3JjZSgwKSkgPT0gZmFsc2UpCiAgICBleHBlY3QoIuagh+W/lyAyIOKGkiDop4bkuLrlvLrliLbvvIjpnZ4gMCDljbPnnJ/vvIkiLCBleHRyYWN0Rm9yY2VGbGFnKHBhY2tldFdpdGhGb3JjZSgyKSkpCiAgICBleHBlY3QoIuaZrumAmuino+mUgeS4jeino+aekOW8uuWItuagh+W/lyIsCiAgICAgICAgICAgZXh0cmFjdEZvcmNlRmxhZyhwYWNrZXRXaXRoRm9yY2UoMSwgY29tbWFuZDoga0NtZFVubG9jaykpID09IGZhbHNlKQogICAgZXhwZWN0KCLplIHlrprmjIfku6TkuI3op6PmnpDlvLrliLbmoIflv5ciLAogICAgICAgICAgIGV4dHJhY3RGb3JjZUZsYWcocGFja2V0V2l0aEZvcmNlKDEsIGNvbW1hbmQ6IGtDbWRMb2NrKSkgPT0gZmFsc2UpCgogICAgLy8g5oql5paH6YeM55qE5a+G56CB5bqP5Y+36Kej5p6QCiAgICBmdW5jIHBhY2tldFdpdGhJbmRleChfIGlkeDogVUludDgsIGNvbW1hbmQ6IFVJbnQ4ID0ga0NtZFVubG9ja0Zyb20pIC0+IFtVSW50OF0gewogICAgICAgIHZhciBiID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiBrUGFja2V0TGVuKQogICAgICAgIGJbMF0gPSAweDQyOyBiWzFdID0gMHg1NTsgYlsyXSA9IDB4MDE7IGJbM10gPSBjb21tYW5kCiAgICAgICAgYltrSW5kZXhPZmZzZXRdID0gaWR4CiAgICAgICAgcmV0dXJuIGIKICAgIH0KICAgIGV4cGVjdCgi5LuO5oql5paH5Lit6Kej5p6Q5Ye65bqP5Y+3IDAiLAogICAgICAgICAgIGV4dHJhY3RQYXNzd29yZEluZGV4KHBhY2tldFdpdGhJbmRleCgwKSkgPT0gMCkKICAgIGV4cGVjdCgi5LuO5oql5paH5Lit6Kej5p6Q5Ye65bqP5Y+3IDUiLAogICAgICAgICAgIGV4dHJhY3RQYXNzd29yZEluZGV4KHBhY2tldFdpdGhJbmRleCg1KSkgPT0gNSkKICAgIGV4cGVjdCgi5LuO5oql5paH5Lit6Kej5p6Q5Ye65bqP5Y+3IDI1NSIsCiAgICAgICAgICAgZXh0cmFjdFBhc3N3b3JkSW5kZXgocGFja2V0V2l0aEluZGV4KDI1NSkpID09IDI1NSkKICAgIGV4cGVjdCgi5pmu6YCa6Kej6ZSB5LiN6Kej5p6Q5bqP5Y+3IiwKICAgICAgICAgICBleHRyYWN0UGFzc3dvcmRJbmRleChwYWNrZXRXaXRoSW5kZXgoMywgY29tbWFuZDoga0NtZFVubG9jaykpID09IG5pbCkKICAgIGV4cGVjdCgi6ZSB5a6a5oyH5Luk5LiN6Kej5p6Q5bqP5Y+3IiwKICAgICAgICAgICBleHRyYWN0UGFzc3dvcmRJbmRleChwYWNrZXRXaXRoSW5kZXgoMywgY29tbWFuZDoga0NtZExvY2spKSA9PSBuaWwpCgogICAgLy8g5omL5py65oyH5a6a5a+G56CB5pe255qE5o6S5bqP6YC76L6RCiAgICBsZXQgYmFzZSA9IFsicHctQSIsICJwdy1CIiwgInB3LUMiLCAicHctRCJdCiAgICBleHBlY3QoIuaMh+WumuesrCAzIOS4qiDihpIg5a6D5o6S5Yiw5pyA5YmNIiwKICAgICAgICAgICBwcm9tb3RlUGFzc3dvcmQoYmFzZSwgdG9Gcm9udDogMikgPT0gWyJwdy1DIiwgInB3LUEiLCAicHctQiIsICJwdy1EIl0sCiAgICAgICAgICAgIuWunumZhSBcKHByb21vdGVQYXNzd29yZChiYXNlLCB0b0Zyb250OiAyKSkiKQogICAgZXhwZWN0KCLmjIflrprnrKwgMSDkuKog4oaSIOmhuuW6j+S4jeWPmCIsCiAgICAgICAgICAgcHJvbW90ZVBhc3N3b3JkKGJhc2UsIHRvRnJvbnQ6IDApID09IGJhc2UsCiAgICAgICAgICAgIuWunumZhSBcKHByb21vdGVQYXNzd29yZChiYXNlLCB0b0Zyb250OiAwKSkiKQogICAgZXhwZWN0KCLmjIflrprmnIDlkI7kuIDkuKog4oaSIOWug+aOkuWIsOacgOWJjSIsCiAgICAgICAgICAgcHJvbW90ZVBhc3N3b3JkKGJhc2UsIHRvRnJvbnQ6IDMpID09IFsicHctRCIsICJwdy1BIiwgInB3LUIiLCAicHctQyJdLAogICAgICAgICAgICLlrp7pmYUgXChwcm9tb3RlUGFzc3dvcmQoYmFzZSwgdG9Gcm9udDogMykpIikKICAgIGV4cGVjdCgi5bqP5Y+36LaK55WMIOKGkiDljp/moLfov5Tlm57vvIjlm57pgIDpu5jorqTpobrluo/vvIkiLAogICAgICAgICAgIHByb21vdGVQYXNzd29yZChiYXNlLCB0b0Zyb250OiA5OSkgPT0gYmFzZSwKICAgICAgICAgICAi5a6e6ZmFIFwocHJvbW90ZVBhc3N3b3JkKGJhc2UsIHRvRnJvbnQ6IDk5KSkiKQogICAgZXhwZWN0KCLotJ/mlbDluo/lj7cg4oaSIOWOn+agt+i/lOWbniIsCiAgICAgICAgICAgcHJvbW90ZVBhc3N3b3JkKGJhc2UsIHRvRnJvbnQ6IC0xKSA9PSBiYXNlKQogICAgZXhwZWN0KCLljZXlhYPntKDliJfooajkuI3lj5flvbHlk40iLAogICAgICAgICAgIHByb21vdGVQYXNzd29yZChbIm9ubHkiXSwgdG9Gcm9udDogMCkgPT0gWyJvbmx5Il0pCiAgICBleHBlY3QoIuepuuWIl+ihqOS4jeW0qea6gyIsIHByb21vdGVQYXNzd29yZChbXSwgdG9Gcm9udDogMCkuaXNFbXB0eSkKCiAgICAvLyDmjIflrprluo/lj7flkI7ku43lupTog73or5XliLDlhajpg6jlr4bnoIHvvIjlm57pgIDpk77lrozmlbTvvIkKICAgIGxldCBwcm9tb3RlZCA9IHByb21vdGVQYXNzd29yZChiYXNlLCB0b0Zyb250OiAyKQogICAgZXhwZWN0KCLmjpLluo/lkI7ku43mmK/lkIzkuIDnu4Tlr4bnoIHvvIjml6DkuKLlpLHvvIkiLAogICAgICAgICAgIFNldChwcm9tb3RlZCkgPT0gU2V0KGJhc2UpICYmIHByb21vdGVkLmNvdW50ID09IGJhc2UuY291bnQsCiAgICAgICAgICAgIuWunumZhSBcKHByb21vdGVkKSIpCgogICAgLy8g5riF56m65ZCO5bqU5Li656m65YiX6KGo77yI5LiN6IO95oqKIEpTT04g5paH5pysICJbXSIg5b2T5a+G56CB77yJCiAgICBzdG9yZVBhc3N3b3JkcyhbXSwgYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBsZXQgZW1wdGllZCA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IHRlc3RBY2NvdW50KQogICAgZXhwZWN0KCLmuIXnqbrlkI7kuLrnqbrliJfooagiLCBlbXB0aWVkLmlzRW1wdHksICLlrp7pmYUgXChlbXB0aWVkLmNvdW50KSDkuKrvvJpcKGVtcHRpZWQpIikKCiAgICAvLyDmuIXnkIbmtYvor5XmnaHnm64KICAgIF8gPSBydW5Qcm9jZXNzKCIvdXNyL2Jpbi9zZWN1cml0eSIsCiAgICAgICAgICAgICAgICAgICBbImRlbGV0ZS1nZW5lcmljLXBhc3N3b3JkIiwgIi1hIiwgdGVzdEFjY291bnQsICItcyIsIGtLZXljaGFpblNlcnZpY2VdKQoKICAgIHByaW50KCkKICAgIGlmIGZhaWxlZCA9PSAwIHsKICAgICAgICBwcmludCgi57uT5p6cOiDlhajpg6jpgJrov4cg4pyTIikKICAgICAgICBleGl0KDApCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLnu5Pmnpw6IFwoZmFpbGVkKSDpobnlpLHotKUg4pyXIikKICAgICAgICBleGl0KDEpCiAgICB9Cn0KCi8vIOWNj+iuruiHquajgO+8mueUqOWbuuWumua1i+ivleWvhumSpeWvuee7meWumueahOWNgeWFrei/m+WItua2iOaBr+iuoeeulyBITUFD77yM5L6b6Leo6K+t6KiA5q+U5a+55L2/55SoCmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLXNlbGZ0ZXN0IiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIGxldCBoZXhTdHJpbmcgPSBhcmdzW2lkeCArIDFdCiAgICB2YXIgbWVzc2FnZSA9IERhdGEoKQogICAgdmFyIGkgPSBoZXhTdHJpbmcuc3RhcnRJbmRleAogICAgd2hpbGUgaSA8IGhleFN0cmluZy5lbmRJbmRleCB7CiAgICAgICAgZ3VhcmQgbGV0IG5leHQgPSBoZXhTdHJpbmcuaW5kZXgoaSwgb2Zmc2V0Qnk6IDIsIGxpbWl0ZWRCeTogaGV4U3RyaW5nLmVuZEluZGV4KSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGxldCBieXRlU3RyaW5nID0gaGV4U3RyaW5nW2kuLjxuZXh0XQogICAgICAgIGd1YXJkIGxldCBieXRlID0gVUludDgoYnl0ZVN0cmluZywgcmFkaXg6IDE2KSBlbHNlIHsKICAgICAgICAgICAgRmlsZUhhbmRsZS5zdGFuZGFyZEVycm9yLndyaXRlKCLml6DmlYjnmoTljYHlha3ov5vliLbovpPlhaVcbiIuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBtZXNzYWdlLmFwcGVuZChieXRlKQogICAgICAgIGkgPSBuZXh0CiAgICB9CiAgICAvLyDkuI4gQW5kcm9pZCDnq68gVmVyaWZ5UHJvdG9jb2wuamF2YSDkvb/nlKjlrozlhajnm7jlkIznmoTmtYvor5Xlr4bpkqXvvJoweDAwLDB4MDEsLi4uLDB4MWYKICAgIHZhciBrZXlCeXRlcyA9IFtVSW50OF0oKQogICAgZm9yIG4gaW4gMC4uPDMyIHsga2V5Qnl0ZXMuYXBwZW5kKFVJbnQ4KG4pKSB9CiAgICBsZXQgdGVzdEtleSA9IFN5bW1ldHJpY0tleShkYXRhOiBEYXRhKGtleUJ5dGVzKSkKICAgIGxldCB0YWcgPSBEYXRhKEhNQUM8U0hBMjU2Pi5hdXRoZW50aWNhdGlvbkNvZGUoZm9yOiBtZXNzYWdlLCB1c2luZzogdGVzdEtleSkpCiAgICBwcmludCh0YWcubWFwIHsgU3RyaW5nKGZvcm1hdDogIiUwMngiLCAkMCkgfS5qb2luZWQoKSkKICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1wcmludC10b2tlbiIpIHsKICAgIGd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICAgICAgcHJpbnQoIuWwmuacquWIneWni+WMlumFjee9ru+8jOivt+WFiOi/kOihjOWuieijheiEmuacrOOAgiIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgcHJpbnQoY29uZmlnLmhtYWNLZXkpCiAgICBleGl0KDApCn0KCmlmIGFyZ3MuY29udGFpbnMoIi0tYWRkLWFjY2Vzc2liaWxpdHkiKSB7CiAgICBsZXQgb2sgPSBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IHRydWUpCiAgICBwcmludChvayA/ICLlt7LojrflvpfovoXliqnlip/og73mnYPpmZDjgIIiIDogIuW3suW8ueWHuuaOiOadg+ivt+axgu+8jOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDovoXliqnlip/og73jgI3kuK3li77pgIkgQkxFVW5sb2NrQ21k44CCIikKICAgIGV4aXQoMCkKfQoKLy8g55Sx5a6I5oqk6L+b56iL6Ieq5bex5Y+R6LW344CM6L6F5Yqp5Yqf6IO944CN5o6I5p2D6K+35rGC44CCCi8vIOeUqCBwcm9tcHQ6dHJ1ZSDorqnns7vnu5/lvLnlh7rmjojmnYPlvJXlr7zlubbmiororrDlvZXnu5HlrprliLDmnKzkuozov5vliLbjgIIKaWYgYXJncy5jb250YWlucygiLS1yZXF1ZXN0LWFjY2Vzc2liaWxpdHkiKSB7CiAgICBsZXQga2V5ID0ga0FYVHJ1c3RlZENoZWNrT3B0aW9uUHJvbXB0LnRha2VVbnJldGFpbmVkVmFsdWUoKSBhcyBTdHJpbmcKICAgIGxldCB0cnVzdGVkID0gQVhJc1Byb2Nlc3NUcnVzdGVkV2l0aE9wdGlvbnMoW2tleTogdHJ1ZV0gYXMgQ0ZEaWN0aW9uYXJ5KQogICAgaWYgdHJ1c3RlZCB7CiAgICAgICAgcHJpbnQoIuW3suaOiOadg++8jOaXoOmcgOWGjeaTjeS9nOOAgiIpCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLlt7LlvLnlh7rns7vnu5/mjojmnYPlvJXlr7zjgIIiKQogICAgICAgIHByaW50KCLlpoLmnpzns7vnu5/orr7nva7ph4zmsqHmnInoh6rliqjlh7rnjrDmnaHnm67vvIzor7flnKjjgIzovoXliqnlip/og73jgI3liJfooajkuK3ngrkg77yLIOa3u+WKoO+8miIpCiAgICAgICAgcHJpbnQoQ29tbWFuZExpbmUuYXJndW1lbnRzWzBdKQogICAgICAgIHByaW50KCIiKQogICAgICAgIHByaW50KCLms6jmhI/vvJrlpoLmnpzliJfooajph4zlt7LmnIkgQkxFVW5sb2NrQ21kIOS4lOW8gOWFs+aYr+aJk+W8gOeahO+8jOS9huWvuemSqeaXoOaViO+8jCIpCiAgICAgICAgcHJpbnQoIuivt+WFiOeUqOOAjOKIkuOAjeWIoOmZpOWug++8jOWGjemHjeaWsOa3u+WKoOS4gOasoeKAlOKAlOaXp+aOiOadg+WPr+iDvee7keWumuS6huaXp+eJiOacrOeahOeoi+W6j+OAgiIpCiAgICB9CiAgICBleGl0KHRydXN0ZWQgPyAwIDogMSkKfQoKLy8g6YCa55+l5q2j5Zyo6L+Q6KGM55qE5a6I5oqk6L+b56iL5Yi35paw5p2D6ZmQ54q25oCB5paH5Lu244CCCi8vIOeUqOaIt+WcqOOAjOezu+e7n+iuvue9ruOAjemHjOWImuWLvumAieWujOaXtu+8jOmcgOimgeeUqOi/meS4queri+WIu+abtOaWsCBkYWVtb24tc3RhdHVzLmpzb27vvIwKLy8g5ZCm5YiZ6KaB562J5Yiw5LiL5LiA5qyh6Kej6ZSB5omN5Lya5Yi35paw44CCCmlmIGFyZ3MuY29udGFpbnMoIi0tYXgtcmVmcmVzaCIpIHsKICAgIGxldCBwYXlsb2FkOiBbU3RyaW5nOiBTdHJpbmddID0gWyJhY3Rpb24iOiAicmVmcmVzaC1heCJdCiAgICBpZiBsZXQgZGF0YSA9IHRyeT8gSlNPTlNlcmlhbGl6YXRpb24uZGF0YSh3aXRoSlNPTk9iamVjdDogcGF5bG9hZCkgewogICAgICAgIHRyeT8gZGF0YS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga1JlZnJlc2hSZXF1ZXN0UGF0aCkpCiAgICB9CiAgICBleGl0KDApCn0KCi8vIOWujOaVtOiviuaWre+8muaKiiLov5nkuKrlj6/miafooYzmlofku7boh6rlt7Ei55yL5Yiw55qE5p2D6ZmQ44CB6ZKl5YyZ5Liy44CB6ZSB5bGP54q25oCB5YWo6YOo5omT5Y2w5Ye65p2l44CCCi8vIOS4jiAtLWNoZWNrIOeahOWMuuWIq+aYr+Wug+WQjOaXtuaKpeWRiuabtOe7hueahOWIpOWumuS+neaNru+8jOS+v+S6juWMuuWIhuaYryLmnYPpmZDmsqHnu5nlr7kiCi8vIOi/mOaYryLliKvnmoTnjq/oioLlh7rpl67popgi44CCCmlmIGFyZ3MuY29udGFpbnMoIi0tZGlhZyIpIHsKICAgIGxldCBidW5kbGVJRCA9IEJ1bmRsZS5tYWluLmJ1bmRsZUlkZW50aWZpZXIgPz8gIijml6ApIgogICAgbGV0IGV4ZSA9IENvbW1hbmRMaW5lLmFyZ3VtZW50c1swXQogICAgcHJpbnQoIuWPr+aJp+ihjOaWh+S7tiA6IFwoZXhlKSIpCiAgICBwcmludCgiQnVuZGxlIElEICA6IFwoYnVuZGxlSUQpIikKICAgIHByaW50KCJCdW5kbGUg6Lev5b6EOiBcKEJ1bmRsZS5tYWluLmJ1bmRsZVBhdGgpIikKICAgIHByaW50KCIiKQogICAgbGV0IHRydXN0ZWQgPSBhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpCiAgICBwcmludCgiQVhJc1Byb2Nlc3NUcnVzdGVkIDogXCh0cnVzdGVkKSIpCiAgICBwcmludCgiICDihpIg6L+Z5LiA6aG55pivIFRDQyDlr7nmnKzkuozov5vliLbnmoTliKTlrprvvIzkuI7jgIzns7vnu5/orr7nva7jgI3ph4zmmL7npLrnmoTkuIDoh7QiKQogICAgcHJpbnQoIiIpCiAgICBpZiBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIHsKICAgICAgICBwcmludCgi6YWN572uICAgICAgIDog5q2j5bi477yI6K6+5aSH5ZCNIFwoY29uZmlnLmRldmljZU5hbWUp77yJIikKICAgICAgICBpZiBsZXQgcHcgPSBmZXRjaFBhc3N3b3JkKGFjY291bnQ6IGNvbmZpZy5rZXljaGFpbkFjY291bnQpIHsKICAgICAgICAgICAgcHJpbnQoIumSpeWMmeS4suWvhueggSA6IOWPr+ivu+WPlu+8iFwocHcuY291bnQpIOWtl+espu+8iSIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgcHJpbnQoIumSpeWMmeS4suWvhueggSA6IOivu+WPluWksei0pSIpCiAgICAgICAgfQogICAgfSBlbHNlIHsKICAgICAgICBwcmludCgi6YWN572uICAgICAgIDog57y65aSxIikKICAgIH0KICAgIHByaW50KCLmmK/lkKbplIHlsY8gICA6IFwoaXNTY3JlZW5Mb2NrZWQoKSA/ICLmmK8iIDogIuWQpiIpIikKICAgIHByaW50KCIiKQogICAgcHJpbnQoIuiLpeS4iumdoiBBWElzUHJvY2Vzc1RydXN0ZWQg5Li6IGZhbHNl77yM5L2G44CM57O757uf6K6+572uIOKGkiDovoXliqnlip/og73jgI3ph4zlvIDlhbPmmK/miZPlvIDnmoTvvIwiKQogICAgcHJpbnQoIuivtOaYjuivpemhueaOiOadg+e7keWumueahOaYr+aXp+eJiOacrOS6jOi/m+WItuOAguivt+WcqOivpeWIl+ihqOmHjOWIoOmZpCBCTEVVbmxvY2tDbWTvvIwiKQogICAgcHJpbnQoIueEtuWQjumHjeaWsOi/kOihjOiuvue9ruWQkeWvvOa3u+WKoOS4gOasoeOAgiIpCiAgICBleGl0KHRydXN0ZWQgPyAwIDogMSkKfQoKLy8g5L6b5a6J6KOF6ISa5pys5p+l6K+i5p2D6ZmQ54q25oCB44CC5b+F6aG755SxIEFwcCBidW5kbGUg5YaF6L+Z5Liq5Y+v5omn6KGM5paH5Lu26Ieq5bex5oql5ZGK77yMCi8vIOWboOS4uuOAjOi+heWKqeWKn+iDveOAjeadg+mZkOaYr+aMieS6jOi/m+WItu+8iFRDQyDkuLvkvZPvvInmjojkuojnmoTvvJrlj6bnvJbkuIDkuKrmjqLmtYvlsI/nqIvluo/ljrvmn6XvvIwKLy8g5b6X5Yiw55qE5piv6YKj5Liq56iL5bqP6Ieq5bex55qE5p2D6ZmQ77yM5Lya5rC46L+c5piv44CM5pyq5o6I5p2D44CN4oCU4oCU6L+Z5q2j5piv5LmL5YmN55qE6K+v5oql5p2l5rqQ44CCCmlmIGFyZ3MuY29udGFpbnMoIi0tYXgtc3RhdHVzIikgewogICAgZXhpdChhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpID8gMCA6IDEpCn0KCi8vIOWkmuWvhueggeeuoeeQhuOAguS+m+iuvue9ruWQkeWvvOS4juWRveS7pOihjOWFseeUqO+8jOmAu+i+keWPquWcqOi/memHjOWunueOsOS4gOS7veOAggovLwovLyAgIC0tcGFzc3dvcmRzIGxpc3QgWy0tanNvbl0gICAgICAgIOWIl+WHuuWvhuegge+8iOm7mOiupOaJk+egge+8iQovLyAgIC0tcGFzc3dvcmRzIGFkZCAgIC0tc3RkaW4gICAgICAgIOS7juagh+WHhui+k+WFpeivu+S4gOihjOS9nOS4uuaWsOWvhueggQovLyAgIC0tcGFzc3dvcmRzIHNldCAgIC0tc3RkaW4gICAgICAgIOaVtOS9k+abv+aNou+8iOivu+S4gOihjOS4gOS4qu+8jOepuuihjOe7k+adn++8iQovLyAgIC0tcGFzc3dvcmRzIHJlbW92ZSAtLWluZGV4IE4gICAgIOWIoOmZpOesrCBOIOS4qu+8iOS7jiAxIOW8gOWni++8iQovLyAgIC0tcGFzc3dvcmRzIGNsZWFyICAgICAgICAgICAgICAgIOa4heepugppZiBsZXQgaWR4ID0gYXJncy5maXJzdEluZGV4KG9mOiAiLS1wYXNzd29yZHMiKSB7CiAgICBsZXQganNvbk91dCA9IGFyZ3MuY29udGFpbnMoIi0tanNvbiIpCiAgICBsZXQgYWNjb3VudCA9IGxvYWRDb25maWcoKT8ua2V5Y2hhaW5BY2NvdW50ID8/IE5TVXNlck5hbWUoKQogICAgbGV0IGFjdGlvbiA9IChpZHggKyAxIDwgYXJncy5jb3VudCkgPyBhcmdzW2lkeCArIDFdIDogImxpc3QiCiAgICB2YXIgbGlzdCA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IGFjY291bnQpCgogICAgLy8vIOivu+WPluagh+WHhui+k+WFpeS4reeahOWvhueggeOAggogICAgLy8vCiAgICAvLy8gLSBQYXJhbWV0ZXIgc2luZ2xlOiB0cnVlIOWPquivu+S4gOihjO+8iGFkZO+8ie+8m2ZhbHNlIOivu+WIsOepuuihjOaIliBFT0Yg5Li65q2i77yIc2V077yJCiAgICAvLy8KICAgIC8vLyDms6jmhI/vvJrovpPlhaXmmK/mjInooYzkvKDovpPnmoTvvIzlm6DmraQqKuWvhueggeacrOi6q+S4jeiDveWMheWQq+aNouihjOespioq4oCU4oCUCiAgICAvLy8g5ZCr5o2i6KGM55qE5a+G56CB5Lya6KKr5ouG5oiQ5Lik5p2h77yM5omA5Lul6L+Z6YeM55u05o6l5ouS57ud5bm25oql6ZSZ77yM6ICM5LiN5piv6Z2Z6buY5ouG5byA44CCCiAgICAvLy8g5a6e6Le15Lit55m75b2V5a+G56CB5ZCr5o2i6KGM5p6B5Li6572V6KeB77yM55WM6Z2i5LiK55qE5a+G56CB5qGG5Lmf5peg5rOV6L6T5YWl5o2i6KGM44CCCiAgICBmdW5jIHJlYWRMaW5lcyhzaW5nbGU6IEJvb2wpIC0+IFtTdHJpbmddIHsKICAgICAgICB2YXIgbGluZXM6IFtTdHJpbmddID0gW10KICAgICAgICB3aGlsZSBsZXQgbGluZSA9IHJlYWRMaW5lKHN0cmlwcGluZ05ld2xpbmU6IHRydWUpIHsKICAgICAgICAgICAgaWYgc2luZ2xlIHsKICAgICAgICAgICAgICAgIGlmICFsaW5lLmlzRW1wdHkgeyBsaW5lcy5hcHBlbmQobGluZSkgfQogICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiBsaW5lLmlzRW1wdHkgeyBicmVhayB9ICAgLy8g56m66KGM57uT5p2fCiAgICAgICAgICAgIGxpbmVzLmFwcGVuZChsaW5lKQogICAgICAgIH0KICAgICAgICByZXR1cm4gbGluZXMKICAgIH0KCiAgICBzd2l0Y2ggYWN0aW9uIHsKICAgIGNhc2UgImxpc3QiOgogICAgICAgIC8vIC0tdmFsdWVz77ya5LulIEpTT04g5pWw57uE6L6T5Ye65Y6f5aeL5a+G56CB77yM5L6b6K6+572u5ZCR5a+857K+56Gu6K+75Y+W44CCCiAgICAgICAgLy8g5LiN6IO96YCQ6KGM6L6T5Ye64oCU4oCU5a+G56CB5pys6Lqr5Y+v6IO95ZCr5o2i6KGM56ym77yM5Lya5LiA5p2h6KKr5ouG5oiQ5Lik5p2h44CCCiAgICAgICAgLy8gSlNPTiDkvJrmiormjaLooYzovazkuYnvvIzog73nsr7noa7mib/ovb3ku7vmhI/lrZfnrKbjgIIKICAgICAgICBpZiBhcmdzLmNvbnRhaW5zKCItLXZhbHVlcyIpIHsKICAgICAgICAgICAgaWYgbGV0IGRhdGEgPSB0cnk/IEpTT05TZXJpYWxpemF0aW9uLmRhdGEod2l0aEpTT05PYmplY3Q6IGxpc3QpLAogICAgICAgICAgICAgICBsZXQgdGV4dCA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpIHsKICAgICAgICAgICAgICAgIHByaW50KHRleHQpCiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBwcmludCgiW10iKQogICAgICAgICAgICB9CiAgICAgICAgICAgIGV4aXQoMCkKICAgICAgICB9CiAgICAgICAgaWYganNvbk91dCB7CiAgICAgICAgICAgIHByaW50SlNPTihbImNvdW50IjogbGlzdC5jb3VudCwgImxlbmd0aHMiOiBsaXN0Lm1hcCB7ICQwLmNvdW50IH1dKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGlmIGxpc3QuaXNFbXB0eSB7CiAgICAgICAgICAgICAgICBwcmludCgi5bCa5pyq5L+d5a2Y5Lu75L2V5a+G56CB44CCIikKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHByaW50KCLlt7Lkv53lrZggXChsaXN0LmNvdW50KSDkuKrlr4bnoIHvvIjmjInlsJ3or5Xpobrluo/vvInvvJoiKQogICAgICAgICAgICAgICAgZm9yIChuLCBwdykgaW4gbGlzdC5lbnVtZXJhdGVkKCkgewogICAgICAgICAgICAgICAgICAgIHByaW50KCIgIFwobiArIDEpLiBcKFN0cmluZyhyZXBlYXRpbmc6ICLigKIiLCBjb3VudDogbWF4KHB3LmNvdW50LCAxKSkpICDvvIhcKHB3LmNvdW50KSDlrZfnrKbvvIkiKQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGV4aXQoMCkKCiAgICBjYXNlICJhZGQiOgogICAgICAgIGxldCBuZXdPbmVzID0gcmVhZExpbmVzKHNpbmdsZTogdHJ1ZSkKICAgICAgICBndWFyZCAhbmV3T25lcy5pc0VtcHR5IGVsc2UgewogICAgICAgICAgICBpZiBqc29uT3V0IHsgcHJpbnRKU09OKFsib2siOiBmYWxzZSwgImVycm9yIjogIuayoeacieS7juagh+WHhui+k+WFpeivu+WIsOWvhueggSJdKSB9CiAgICAgICAgICAgIGVsc2UgeyBGaWxlSGFuZGxlLnN0YW5kYXJkRXJyb3Iud3JpdGUoIuayoeacieS7juagh+WHhui+k+WFpeivu+WIsOWvhueggVxuIi5kYXRhKHVzaW5nOiAudXRmOCkhKSB9CiAgICAgICAgICAgIGV4aXQoMikKICAgICAgICB9CiAgICAgICAgbGlzdC5hcHBlbmQoY29udGVudHNPZjogbmV3T25lcykKICAgICAgICBsZXQgb2sgPSBzdG9yZVBhc3N3b3JkcyhsaXN0LCBhY2NvdW50OiBhY2NvdW50KQogICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IG9rLCAiY291bnQiOiBsaXN0LmNvdW50XSkgfQogICAgICAgIGVsc2UgeyBwcmludChvayA/ICLlt7Lmt7vliqDvvIzlhbEgXChsaXN0LmNvdW50KSDkuKrlr4bnoIHjgIIiIDogIuWGmeWFpemSpeWMmeS4suWksei0peOAgiIpIH0KICAgICAgICBleGl0KG9rID8gMCA6IDEpCgogICAgY2FzZSAic2V0IjoKICAgICAgICBsZXQgbmV3TGlzdCA9IHJlYWRMaW5lcyhzaW5nbGU6IGZhbHNlKQogICAgICAgIGd1YXJkICFuZXdMaXN0LmlzRW1wdHkgZWxzZSB7CiAgICAgICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IGZhbHNlLCAiZXJyb3IiOiAi5rKh5pyJ5LuO5qCH5YeG6L6T5YWl6K+75Yiw5a+G56CBIl0pIH0KICAgICAgICAgICAgZWxzZSB7IEZpbGVIYW5kbGUuc3RhbmRhcmRFcnJvci53cml0ZSgi5rKh5pyJ5LuO5qCH5YeG6L6T5YWl6K+75Yiw5a+G56CBXG4iLmRhdGEodXNpbmc6IC51dGY4KSEpIH0KICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBsZXQgb2sgPSBzdG9yZVBhc3N3b3JkcyhuZXdMaXN0LCBhY2NvdW50OiBhY2NvdW50KQogICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IG9rLCAiY291bnQiOiBuZXdMaXN0LmNvdW50XSkgfQogICAgICAgIGVsc2UgeyBwcmludChvayA/ICLlt7Lorr7nva7kuLogXChuZXdMaXN0LmNvdW50KSDkuKrlr4bnoIHjgIIiIDogIuWGmeWFpemSpeWMmeS4suWksei0peOAgiIpIH0KICAgICAgICBleGl0KG9rID8gMCA6IDEpCgogICAgY2FzZSAicmVtb3ZlIjoKICAgICAgICBndWFyZCBsZXQgdmlkeCA9IGFyZ3MuZmlyc3RJbmRleChvZjogIi0taW5kZXgiKSwgdmlkeCArIDEgPCBhcmdzLmNvdW50LAogICAgICAgICAgICAgIGxldCBvbmVCYXNlZCA9IEludChhcmdzW3ZpZHggKyAxXSksIG9uZUJhc2VkID49IDEsIG9uZUJhc2VkIDw9IGxpc3QuY291bnQgZWxzZSB7CiAgICAgICAgICAgIGxldCBtc2cgPSAi57Si5byV5peg5pWI77yI6IyD5Zu05Li6IDEuLlwobGlzdC5jb3VudCnvvIkiCiAgICAgICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IGZhbHNlLCAiZXJyb3IiOiBtc2ddKSB9IGVsc2UgeyBwcmludChtc2cpIH0KICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBsaXN0LnJlbW92ZShhdDogb25lQmFzZWQgLSAxKQogICAgICAgIGxldCBvayA9IHN0b3JlUGFzc3dvcmRzKGxpc3QsIGFjY291bnQ6IGFjY291bnQpCiAgICAgICAgaWYganNvbk91dCB7IHByaW50SlNPTihbIm9rIjogb2ssICJjb3VudCI6IGxpc3QuY291bnRdKSB9CiAgICAgICAgZWxzZSB7IHByaW50KG9rID8gIuW3suWIoOmZpO+8jOWJqeS9mSBcKGxpc3QuY291bnQpIOS4quWvhueggeOAgiIgOiAi5YaZ5YWl6ZKl5YyZ5Liy5aSx6LSl44CCIikgfQogICAgICAgIGV4aXQob2sgPyAwIDogMSkKCiAgICBjYXNlICJjbGVhciI6CiAgICAgICAgbGV0IG9rID0gc3RvcmVQYXNzd29yZHMoW10sIGFjY291bnQ6IGFjY291bnQpCiAgICAgICAgaWYganNvbk91dCB7IHByaW50SlNPTihbIm9rIjogb2ssICJjb3VudCI6IDBdKSB9CiAgICAgICAgZWxzZSB7IHByaW50KG9rID8gIuW3sua4heepuuWFqOmDqOWvhueggeOAgiIgOiAi5YaZ5YWl6ZKl5YyZ5Liy5aSx6LSl44CCIikgfQogICAgICAgIGV4aXQob2sgPyAwIDogMSkKCiAgICBkZWZhdWx0OgogICAgICAgIGxldCBtc2cgPSAi5pyq55+l5pON5L2c77yaXChhY3Rpb24p77yI5Y+v55So77yabGlzdC9hZGQvc2V0L3JlbW92ZS9jbGVhcu+8iSIKICAgICAgICBpZiBqc29uT3V0IHsgcHJpbnRKU09OKFsib2siOiBmYWxzZSwgImVycm9yIjogbXNnXSkgfSBlbHNlIHsgcHJpbnQobXNnKSB9CiAgICAgICAgZXhpdCgyKQogICAgfQp9CgppZiBhcmdzLmNvbnRhaW5zKCItLWNoZWNrIikgewogICAgZ3VhcmQgbGV0IGNvbmZpZyA9IGxvYWRDb25maWcoKSBlbHNlIHsKICAgICAgICBwcmludCgi6YWN572uOiDnvLrlpLHvvIhcKGtDb25maWdQYXRoKe+8iSIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgcHJpbnQoIumFjee9rjog5q2j5bi4IikKICAgIHByaW50KCLorr7lpIflkI06IFwoY29uZmlnLmRldmljZU5hbWUpIikKICAgIHByaW50KCLpkqXljJnkuLLotKbmiLc6IFwoY29uZmlnLmtleWNoYWluQWNjb3VudCkiKQogICAgcHJpbnQoIui+heWKqeWKn+iDveadg+mZkDogXChhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpID8gIuW3suaOiOadgyIgOiAi5pyq5o6I5p2D77yI6Kej6ZSB5Lya5aSx6LSl77yJIikiKQogICAgaWYgbGV0IHB3ID0gZmV0Y2hQYXNzd29yZChhY2NvdW50OiBjb25maWcua2V5Y2hhaW5BY2NvdW50KSB7CiAgICAgICAgcHJpbnQoIueZu+W9leWvhueggTog5bey5a2Y5YWl6ZKl5YyZ5Liy77yIXChwdy5jb3VudCkg5Liq5a2X56ym77yJIikKICAgIH0gZWxzZSB7CiAgICAgICAgcHJpbnQoIueZu+W9leWvhueggTog5pyq5om+5YiwIikKICAgIH0KICAgIHByaW50KCLlvZPliY3mmK/lkKbplIHlsY86IFwoaXNTY3JlZW5Mb2NrZWQoKSA/ICLmmK8iIDogIuWQpiIpIikKICAgIHByaW50KCIiKQogICAgcHJpbnQoIuKUgOKUgCDlrojmiqTov5vnqIvlrp7pmYXnirbmgIHvvIjlhrPlrprop6PplIHog73lkKbmiJDlip/vvInilIDilIAiKQogICAgLy8g5rOo5oSP77ya5pys6L+b56iL5LuO57uI56uv5ZCv5Yqo5pe25Y+v6IO957un5om/5LqG57uI56uv55qEIEFYIOS/oeS7u++8jOWboOatpOS4iumdoumCo+S4gOmhuQogICAgLy8g5pyq5b+F5Luj6KGo55yf5q2j5bmy5rS755qE5a6I5oqk6L+b56iL44CC55yf5a6e54q25oCB5Lul5a6I5oqk6L+b56iL6Ieq5bex6JC955uY55qE5YaF5a655Li65YeG44CCCiAgICBpZiBsZXQgZGF0YSA9IEZpbGVNYW5hZ2VyLmRlZmF1bHQuY29udGVudHMoYXRQYXRoOiBrU3RhdHVzUGF0aCksCiAgICAgICBsZXQgb2JqID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5qc29uT2JqZWN0KHdpdGg6IGRhdGEpIGFzPyBbU3RyaW5nOiBBbnldIHsKICAgICAgICBsZXQgYXggPSAob2JqWyJheFRydXN0ZWQiXSBhcz8gQm9vbCkgPz8gZmFsc2UKICAgICAgICBsZXQgcGlkID0gb2JqWyJwaWQiXSBhcz8gSW50ID8/IC0xCiAgICAgICAgbGV0IGF0ID0gb2JqWyJ1cGRhdGVkQXQiXSBhcz8gU3RyaW5nID8/ICI/IgogICAgICAgIHByaW50KCLlrojmiqTov5vnqIsgQVgg5p2D6ZmQOiBcKGF4ID8gIuW3suaOiOadgyDinJMiIDogIuacquaOiOadgyDinJciKSIpCiAgICAgICAgcHJpbnQoIiAg6K6w5b2V5pe26Ze0OiBcKGF0KSAgUElEOiBcKHBpZCkiKQogICAgICAgIGlmICFheCB7CiAgICAgICAgICAgIHByaW50KCIgIOKGkiDop6PplIHkvJrlpLHotKXjgILor7flnKjjgIzns7vnu5/orr7nva4g4oaSIOmakOengeS4juWuieWFqOaApyDihpIg6L6F5Yqp5Yqf6IO944CNIikKICAgICAgICAgICAgcHJpbnQoIiAgICAg5Lit5Yu+6YCJIEJMRVVubG9ja0NtZO+8m+iLpeW8gOWFs+W3suaJk+W8gO+8jOivt+WFiOWIoOmZpOivpemhueWGjemHjeaWsOa3u+WKoOOAgiIpCiAgICAgICAgfQogICAgfSBlbHNlIHsKICAgICAgICBwcmludCgi5a6I5oqk6L+b56iLIEFYIOadg+mZkDog5pyq55+l77yI5a6I5oqk6L+b56iL5bCa5pyq5YaZ6L+H54q25oCB77yM5Y+v6IO95pyq6L+Q6KGM77yJIikKICAgIH0KICAgIGV4aXQoMCkKfQoKLy8gLS1zZXQta2V5CmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLXNldC1rZXkiKSwgaWR4ICsgMSA8IGFyZ3MuY291bnQgewogICAgbGV0IG5ld0tleSA9IGFyZ3NbaWR4ICsgMV0KICAgIGd1YXJkIERhdGEoYmFzZTY0RW5jb2RlZDogbmV3S2V5KT8uY291bnQgPT0gMzIgZWxzZSB7CiAgICAgICAgcHJpbnQoIumUmeivr++8muWvhumSpeW/hemhu+aYryAzMiDlrZfoioLnmoQgYmFzZTY0IOe8lueggeWtl+espuS4suOAgiIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgdmFyIGNvbmZpZyA9IGxvYWRDb25maWcoKSA/PyBDb25maWcoaG1hY0tleTogbmV3S2V5LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAga2V5Y2hhaW5BY2NvdW50OiBOU1VzZXJOYW1lKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZXZpY2VOYW1lOiBIb3N0LmN1cnJlbnQoKS5sb2NhbGl6ZWROYW1lID8/ICJNYWMiKQogICAgY29uZmlnLmhtYWNLZXkgPSBuZXdLZXkKICAgIGxldCBlbmNvZGVyID0gSlNPTkVuY29kZXIoKQogICAgZW5jb2Rlci5vdXRwdXRGb3JtYXR0aW5nID0gWy5wcmV0dHlQcmludGVkLCAuc29ydGVkS2V5c10KICAgIHRyeT8gZW5jb2Rlci5lbmNvZGUoY29uZmlnKS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga0NvbmZpZ1BhdGgpKQogICAgdHJ5PyBGaWxlTWFuYWdlci5kZWZhdWx0LnNldEF0dHJpYnV0ZXMoWy5wb3NpeFBlcm1pc3Npb25zOiAwbzYwMF0sIG9mSXRlbUF0UGF0aDoga0NvbmZpZ1BhdGgpCiAgICBwcmludCgi5bey5pu05paw6YWN5a+55a+G6ZKl77yM6K+35Zyo5omL5py6IEFwcCDkuK3lkIzmraXkv67mlLnjgIIiKQogICAgZXhpdCgwKQp9CgovLyAtLXNob3ctdG9rZW7vvJrmiZPljbDlvZPliY3lr4bpkqXvvJvmnKrlronoo4Xml7bnlJ/miJDkuIDkuKrkuLTml7blr4bpkqXvvIjphY3lkIggLS1kcnktcnVuIOa1i+ivleeUqO+8iQppZiBhcmdzLmNvbnRhaW5zKCItLXNob3ctdG9rZW4iKSB7CiAgICBpZiBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIHsKICAgICAgICBwcmludChjb25maWcuaG1hY0tleSkKICAgIH0gZWxzZSB7CiAgICAgICAgdmFyIGJ5dGVzID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiAzMikKICAgICAgICBmb3IgaSBpbiAwLi48MzIgeyBieXRlc1tpXSA9IFVJbnQ4LnJhbmRvbShpbjogMC4uLjI1NSkgfQogICAgICAgIHByaW50KERhdGEoYnl0ZXMpLmJhc2U2NEVuY29kZWRTdHJpbmcoKSkKICAgIH0KICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1kcnktcnVuIikgewogICAgZHJ5UnVuID0gdHJ1ZQp9CgovLyDmtYvor5XmqKHlvI/kuJTmsqHmnInmraPlvI/phY3nva7ml7bvvIznlKjkuLTml7blr4bpkqUgKyDkuLTml7botKbmiLfvvIzmlrnkvr/lnKjmnKrlronoo4XnmoTmnLrlmajkuIrpqozor4EKaWYgZHJ5UnVuICYmIGxvYWRDb25maWcoKSA9PSBuaWwgewogICAgdmFyIGJ5dGVzID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiAzMikKICAgIGZvciBpIGluIDAuLjwzMiB7IGJ5dGVzW2ldID0gVUludDgucmFuZG9tKGluOiAwLi4uMjU1KSB9CiAgICBsZXQgdGVtcENvbmZpZyA9IENvbmZpZyhobWFjS2V5OiBEYXRhKGJ5dGVzKS5iYXNlNjRFbmNvZGVkU3RyaW5nKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXljaGFpbkFjY291bnQ6IE5TVXNlck5hbWUoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGRldmljZU5hbWU6ICJCTEVVbmxvY2stRFJZUlVOIikKICAgIGxldCBlbmNvZGVyID0gSlNPTkVuY29kZXIoKQogICAgZW5jb2Rlci5vdXRwdXRGb3JtYXR0aW5nID0gWy5wcmV0dHlQcmludGVkLCAuc29ydGVkS2V5c10KICAgIHRyeT8gZW5jb2Rlci5lbmNvZGUodGVtcENvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5zZXRBdHRyaWJ1dGVzKFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgb2ZJdGVtQXRQYXRoOiBrQ29uZmlnUGF0aCkKICAgIGxvZygiZHJ5LXJ1bu+8muW3sueUn+aIkOS4tOaXtumFjee9riBcKGtDb25maWdQYXRoKSIpCn0KCmd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICBwcmludCgi6ZSZ6K+v77ya5om+5LiN5Yiw6YWN572u5paH5Lu2IFwoa0NvbmZpZ1BhdGgpIikKICAgIHByaW50KCLor7flhYjov5DooYwgbWFjLWJsZS11bmxvY2suc2ggaW5zdGFsbCDlrozmiJDliJ3lp4vljJbjgIIiKQogICAgZXhpdCgxKQp9CgpndWFyZCBsZXQga2V5RGF0YSA9IERhdGEoYmFzZTY0RW5jb2RlZDogY29uZmlnLmhtYWNLZXkpLCBrZXlEYXRhLmNvdW50ID09IDMyIGVsc2UgewogICAgcHJpbnQoIumUmeivr++8mumFjee9ruaWh+S7tuS4reeahCBobWFjS2V5IOaXoOaViOOAgiIpCiAgICBleGl0KDEpCn0KCmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLWRldmljZS1uYW1lIiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIHZhciB1cGRhdGVkID0gY29uZmlnCiAgICB1cGRhdGVkLmRldmljZU5hbWUgPSBhcmdzW2lkeCArIDFdCiAgICBsZXQgZW5jb2RlciA9IEpTT05FbmNvZGVyKCkKICAgIGVuY29kZXIub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuY29kZXIuZW5jb2RlKHVwZGF0ZWQpLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrQ29uZmlnUGF0aCkpCiAgICBwcmludCgi6K6+5aSH5ZCN5bey5pu05paw5Li6IFwodXBkYXRlZC5kZXZpY2VOYW1lKSIpCiAgICBleGl0KDApCn0KCmxldCBzeW1tZXRyaWNLZXkgPSBTeW1tZXRyaWNLZXkoZGF0YToga2V5RGF0YSkKCmlmICFhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpIHsKICAgIGxvZygi6K2m5ZGK77ya5bCa5pyq6I635b6X44CM6L6F5Yqp5Yqf6IO944CN5p2D6ZmQ77yM6Kej6ZSB5LiN5Lya55Sf5pWI44CCIikKICAgIGxvZygi6K+36L+Q6KGM77yaQkxFVW5sb2NrQ21kIC0tYWRkLWFjY2Vzc2liaWxpdHkiKQp9Cgpsb2coIuWQr+WKqCBCTEVVbmxvY2tDbWTvvIzorr7lpIflkI3jgIxcKGNvbmZpZy5kZXZpY2VOYW1lKeOAjSIpCgovLyDmiormnKzov5vnqIvvvIjlrojmiqTov5vnqIvvvInoh6rouqvnmoTmnYPpmZDliKTlrprokL3nm5jvvIzkvpvorr7nva7lkJHlr7zor7vlj5bjgIIKLy8g6L+Z5LiA6aG55omN5piv5Yaz5a6aIuino+mUgeiDveWQpuaIkOWKnyLnmoTnnJ/lrp7nirbmgIHjgIIKd3JpdGVEYWVtb25TdGF0dXMoKQoKbGV0IHNlcnZlciA9IFBlcmlwaGVyYWxTZXJ2ZXIoKQpzZXJ2ZXIuc3RhcnQoa2V5OiBzeW1tZXRyaWNLZXksIGRldmljZU5hbWU6IGNvbmZpZy5kZXZpY2VOYW1lKQoKLy8g6Ziy5q2i57O757uf56m66Zey5LyR55yg77ya5LyR55yg5Lya5YGc5o6J6JOd54mZ5bm/5pKt77yM5omL5py65bCx5YaN5Lmf6L+e5LiN5LiK5LqGCnZhciBzbGVlcEFzc2VydGlvbiA9IElPUE1Bc3NlcnRpb25JRCgwKQpsZXQgYXNzZXJ0aW9uUmVzdWx0ID0gSU9QTUFzc2VydGlvbkNyZWF0ZVdpdGhOYW1lKGtJT1BNQXNzZXJ0aW9uVHlwZU5vSWRsZVNsZWVwIGFzIENGU3RyaW5nLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSU9QTUFzc2VydGlvbkxldmVsKGtJT1BNQXNzZXJ0aW9uTGV2ZWxPbiksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiQkxFVW5sb2NrQ21kIOS/neaMgeiTneeJmeWPr+i/nuaOpSIgYXMgQ0ZTdHJpbmcsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAmc2xlZXBBc3NlcnRpb24pCmlmIGFzc2VydGlvblJlc3VsdCA9PSBrSU9SZXR1cm5TdWNjZXNzIHsKICAgIGxvZygi5bey6Zi75q2i57O757uf56m66Zey5LyR55yg77yM5Lul5L+d5oyB6JOd54mZ5Y+v6L+e5o6l77yI5pi+56S65Zmo5LuN5Lya5q2j5bi45oGv5bGP77yJIikKfSBlbHNlIHsKICAgIGxvZygi6K2m5ZGK77ya5peg5rOV5Yib5bu66Ziy5LyR55yg5pat6KiA77yM57O757uf5LyR55yg5ZCO6JOd54mZ5bCG5pat5byAIikKfQoKLy8g6L+b56iL6YCA5Ye65pe26YeK5pS+5pat6KiACmZ1bmMgY2xlYW51cCgpIHsKICAgIGlmIHNsZWVwQXNzZXJ0aW9uICE9IDAgewogICAgICAgIElPUE1Bc3NlcnRpb25SZWxlYXNlKHNsZWVwQXNzZXJ0aW9uKQogICAgICAgIHNsZWVwQXNzZXJ0aW9uID0gMAogICAgfQogICAgbG9nKCJCTEVVbmxvY2tDbWQg6YCA5Ye6IikKfQoKc2lnbmFsKFNJR0lOVCwgU0lHX0lHTikKc2lnbmFsKFNJR1RFUk0sIFNJR19JR04pCmxldCBzaWdpbnRTb3VyY2UgPSBEaXNwYXRjaFNvdXJjZS5tYWtlU2lnbmFsU291cmNlKHNpZ25hbDogU0lHSU5ULCBxdWV1ZTogLm1haW4pCnNpZ2ludFNvdXJjZS5zZXRFdmVudEhhbmRsZXIgeyBsb2coIuaUtuWIsCBTSUdJTlTvvIzpgIDlh7oiKTsgY2xlYW51cCgpOyBleGl0KDApIH0Kc2lnaW50U291cmNlLnJlc3VtZSgpCmxldCBzaWd0ZXJtU291cmNlID0gRGlzcGF0Y2hTb3VyY2UubWFrZVNpZ25hbFNvdXJjZShzaWduYWw6IFNJR1RFUk0sIHF1ZXVlOiAubWFpbikKc2lndGVybVNvdXJjZS5zZXRFdmVudEhhbmRsZXIgeyBsb2coIuaUtuWIsCBTSUdURVJN77yM6YCA5Ye6Iik7IGNsZWFudXAoKTsgZXhpdCgwKSB9CnNpZ3Rlcm1Tb3VyY2UucmVzdW1lKCkKCi8vIOebkeinhuWIt+aWsOivt+axgu+8muiuvue9ruWQkeWvvOWcqOeUqOaIt+WujOaIkOaOiOadg+WQjuWGmeWFpeivpeaWh+S7tu+8jAovLyDlrojmiqTov5vnqIvmja7mraTnq4vliLvliLfmlrAgZGFlbW9uLXN0YXR1cy5qc29u77yM5peg6ZyA6YeN5ZCv5pyN5Yqh44CCCmxldCByZWZyZXNoVGltZXIgPSBUaW1lci5zY2hlZHVsZWRUaW1lcih3aXRoVGltZUludGVydmFsOiAxLjAsIHJlcGVhdHM6IHRydWUpIHsgXyBpbgogICAgbGV0IGZtID0gRmlsZU1hbmFnZXIuZGVmYXVsdAogICAgZ3VhcmQgZm0uZmlsZUV4aXN0cyhhdFBhdGg6IGtSZWZyZXNoUmVxdWVzdFBhdGgpIGVsc2UgeyByZXR1cm4gfQogICAgdHJ5PyBmbS5yZW1vdmVJdGVtKGF0UGF0aDoga1JlZnJlc2hSZXF1ZXN0UGF0aCkKICAgIGxvZygi5pS25Yiw5p2D6ZmQ5Yi35paw6K+35rGCIikKICAgIHdyaXRlRGFlbW9uU3RhdHVzKCkKICAgIGxvZygi5p2D6ZmQ54q25oCB5bey5pu05paw77yM5omL5py656uv5Lya56uL5Y2z55yL5Yiw5pyA5paw57uT5p6cIikKfQpSdW5Mb29wLm1haW4uYWRkKHJlZnJlc2hUaW1lciwgZm9yTW9kZTogLmNvbW1vbikKClJ1bkxvb3AubWFpbi5ydW4oKQo=
__SWIFT_SOURCE_END__
