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
Ly8gQkxFVW5sb2NrQ21kIOKAlCBNYWMgQkxFIOino+mUgeacjeWKoeerrwovLwovLyDkvZznlKjvvJrkvZzkuLogQkxFIOWkluiuvihHQVRUIFNlcnZlcinlub/mkq3vvIzmiYvmnLogQXBwIOi/nuaOpeWQjuWGmeWFpeS4gOadoeW4piBITUFDLVNIQTI1NiDnrb7lkI3nmoQKLy8gICAgICAg5oyH5Luk77yb5qCh6aqM6YCa6L+H5YiZ6LCD55So5LiOIEJMRVVubG9jayDnm7jlkIznmoTmnLrliLboh6rliqjovpPlhaXnmbvlvZXlr4bnoIHmnaXop6PplIHlsY/luZXjgIIKLy8KLy8g57yW6K+R77yac3dpZnRjIC1PIG1haW4uc3dpZnQgLW8gQkxFVW5sb2NrQ21kCi8vIOS+nei1lu+8mkNvcmVCbHVldG9vdGggLyBDcnlwdG9LaXQgLyBDb3JlR3JhcGhpY3MgLyBJT0tpdO+8iOWFqOmDqOS4uuezu+e7n+ahhuaetu+8iQoKaW1wb3J0IEZvdW5kYXRpb24KaW1wb3J0IENvcmVCbHVldG9vdGgKaW1wb3J0IENyeXB0b0tpdAppbXBvcnQgQ29yZUdyYXBoaWNzCmltcG9ydCBEYXJ3aW4KaW1wb3J0IElPS2l0LnB3cl9tZ3QKaW1wb3J0IEFwcGxpY2F0aW9uU2VydmljZXMKCi8vIE1BUks6IC0g5Y2P6K6u5bi46YeP77yI5b+F6aG75LiOIEFuZHJvaWQg56uv5LiA6Ie077yJCgpsZXQga1NlcnZpY2VVVUlEICAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAxLTRBMDAtODAwMC0wMDgwNUY5QjAwMDEiKQpsZXQga0NoYXJDb21tYW5kVVVJRCAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAyLTRBMDAtODAwMC0wMDgwNUY5QjAwMDIiKQpsZXQga0NoYXJTdGF0dXNVVUlEICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDAzLTRBMDAtODAwMC0wMDgwNUY5QjAwMDMiKQpsZXQga0NoYXJJbmZvVVVJRCAgICAgICA9IENCVVVJRChzdHJpbmc6ICJCMUUwQTEwMC0wMDA0LTRBMDAtODAwMC0wMDgwNUY5QjAwMDQiKQoKbGV0IGtNYWdpYzogW1VJbnQ4XSA9IFsweDQyLCAweDU1XSAgICAgICAgICAvLyAiQlUiCmxldCBrVmVyc2lvbjogVUludDggPSAweDAxCmxldCBrQ21kVW5sb2NrOiBVSW50OCA9IDB4MDEKbGV0IGtDbWRMb2NrOiBVSW50OCA9IDB4MDIKbGV0IGtDbWRQaW5nOiBVSW50OCA9IDB4MDMKCmxldCBrUGFja2V0TGVuICA9IDYyICAgICAgICAgICAgICAgICAgICAgICAgLy8gMiBtYWdpYyArIDEgdmVyICsgMSBjbWQgKyA4IHRzICsgMTYgbm9uY2UgKyAzMiBobWFjCmxldCBrSG1hY09mZnNldCA9IDMwICAgICAgICAgICAgICAgICAgICAgICAgLy8gSE1BQyDopobnm5bliY0gMzAg5a2X6IqCCgpsZXQga1RpbWVzdGFtcFNrZXc6IEludDY0ID0gMTIwICAgICAgICAgICAgIC8vIOWFgeiuuOeahOaXtumSn+WBj+W3ru+8iOenku+8iQpsZXQga05vbmNlQ2FjaGVMaW1pdCA9IDUxMgoKLy8gTUFSSzogLSDov5DooYznjq/looPot6/lvoQKLy8KLy8g6buY6K6k5L2/55SoIH4vTGlicmFyeS9BcHBsaWNhdGlvbiBTdXBwb3J0L0JMRVVubG9ja0NtZOOAggovLyDnjq/looPlj5jph48gQkxFVU5MT0NLX0FQUF9TVVBQT1JUIOWPr+imhuebluivpeebruW9le+8iOa1i+ivlS/mspnnrrHnjq/looPnlKjvvInjgIIKCmxldCBrQXBwU3VwcG9ydDogU3RyaW5nID0gewogICAgaWYgbGV0IG92ZXJyaWRlID0gUHJvY2Vzc0luZm8ucHJvY2Vzc0luZm8uZW52aXJvbm1lbnRbIkJMRVVOTE9DS19BUFBfU1VQUE9SVCJdLAogICAgICAgIW92ZXJyaWRlLmlzRW1wdHkgewogICAgICAgIHJldHVybiBvdmVycmlkZQogICAgfQogICAgcmV0dXJuICgifi9MaWJyYXJ5L0FwcGxpY2F0aW9uIFN1cHBvcnQvQkxFVW5sb2NrQ21kIiBhcyBOU1N0cmluZykuZXhwYW5kaW5nVGlsZGVJblBhdGgKfSgpCmxldCBrQ29uZmlnUGF0aCA9IGtBcHBTdXBwb3J0ICsgIi9jb25maWcuanNvbiIKbGV0IGtMb2dQYXRoICAgID0ga0FwcFN1cHBvcnQgKyAiL2JsZS11bmxvY2subG9nIgovLy8g6ZKl5YyZ5Liy5pyN5Yqh5ZCN44CC5Y+v55So546v5aKD5Y+Y6YeP6KaG55uW77yM5L6/5LqO6Ieq5Yqo5YyW5rWL6K+V55So54us56uL5p2h55uu6aqM6K+B44CCCmxldCBrS2V5Y2hhaW5TZXJ2aWNlOiBTdHJpbmcgPSB7CiAgICBpZiBsZXQgbyA9IFByb2Nlc3NJbmZvLnByb2Nlc3NJbmZvLmVudmlyb25tZW50WyJCTEVVTkxPQ0tfS0VZQ0hBSU5fU0VSVklDRSJdLCAhby5pc0VtcHR5IHsKICAgICAgICByZXR1cm4gbwogICAgfQogICAgcmV0dXJuICJibGUtdW5sb2NrLWNtZCIKfSgpCi8vLyDlrojmiqTov5vnqIvmioroh6rlt7HnmoQgVENDIOadg+mZkOeKtuaAgeWGmeWcqOi/memHjO+8jOS+m+iuvue9ruWQkeWvvOivu+WPluOAggovLy8KLy8vIOS4uuS7gOS5iOS4jeebtOaOpemXrui/m+eoi++8mlRDQyDnmoQgQVgg5L+h5Lu75Lya5LuO54i26L+b56iL57un5om/44CC6K6+572u5ZCR5a+85LuOIEZpbmRlci/nu4jnq68KLy8vIOWQr+WKqOaXtuacrOi6q+aYr+WPl+S/oeS7u+eahO+8jOWugyBmb3JrIOWHuuadpeeahOWtkOi/m+eoi+S5n+S8muaKpeWRiuOAjOW3suaOiOadg+OAjeKAlOKAlAovLy8g5L2G55yf5q2j5bmy5rS755qE5a6I5oqk6L+b56iL55SxIGxhdW5jaGQg5ZCv5Yqo77yM5LiN5Y+X5q2k5L+h5Lu777yM5a6e6ZmF5piv5pyq5o6I5p2D44CCCi8vLyDlm6DmraTlv4XpobvorqnlrojmiqTov5vnqIvoh6rlt7HmiorliKTlrprnu5PmnpzokL3nm5jjgIIKbGV0IGtTdGF0dXNQYXRoID0ga0FwcFN1cHBvcnQgKyAiL2RhZW1vbi1zdGF0dXMuanNvbiIKLy8vIOWklumDqOivt+axguWIt+aWsOadg+mZkOeKtuaAgeeahOS/oeWPt+aWh+S7tu+8iOiuvue9ruWQkeWvvOWcqOeUqOaIt+aOiOadg+WQjuWGmeWFpe+8iQpsZXQga1JlZnJlc2hSZXF1ZXN0UGF0aCA9IGtBcHBTdXBwb3J0ICsgIi9yZWZyZXNoLnJlcXVlc3QiCgovLy8g5pel5b+X5paH5Lu25piv5ZCm5Y+v55So77yI55uu5b2V5LiN5Y+v5YaZ5pe26YCA5YyW5Li65Y+q6L6T5Ye65YiwIHN0ZGVycu+8iQpsZXQga0xvZ0ZpbGVXcml0YWJsZTogQm9vbCA9IHsKICAgIEZpbGVNYW5hZ2VyLmRlZmF1bHQuY3JlYXRlRmlsZShhdFBhdGg6IGtMb2dQYXRoLCBjb250ZW50czogbmlsLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGF0dHJpYnV0ZXM6IFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdKQogICAgcmV0dXJuIEZpbGVNYW5hZ2VyLmRlZmF1bHQuaXNXcml0YWJsZUZpbGUoYXRQYXRoOiBrTG9nUGF0aCkKfSgpCgovLyBNQVJLOiAtIOaXpeW/lwoKbGV0IGxvZ0Zvcm1hdHRlcjogRGF0ZUZvcm1hdHRlciA9IHsKICAgIGxldCBmID0gRGF0ZUZvcm1hdHRlcigpCiAgICBmLmRhdGVGb3JtYXQgPSAieXl5eS1NTS1kZCBISDptbTpzcyIKICAgIHJldHVybiBmCn0oKQoKLy8vIOiusOW9leWuiOaKpOi/m+eoi+iHqui6q+eahCBUQ0Mg5p2D6ZmQ54q25oCB77yM5L6b6K6+572u5ZCR5a+85Yik5patIuecn+ato+W5sua0u+eahOi/m+eoiyLog73lkKbovpPlhaXjgIIKZnVuYyB3cml0ZURhZW1vblN0YXR1cygpIHsKICAgIGxldCB0cnVzdGVkID0gYWNjZXNzaWJpbGl0eUdyYW50ZWQoKQogICAgbGV0IHBheWxvYWQ6IFtTdHJpbmc6IEFueV0gPSBbCiAgICAgICAgInBpZCI6IEludChnZXRwaWQoKSksCiAgICAgICAgImF4VHJ1c3RlZCI6IHRydXN0ZWQsCiAgICAgICAgInVwZGF0ZWRBdCI6IElTTzg2MDFEYXRlRm9ybWF0dGVyKCkuc3RyaW5nKGZyb206IERhdGUoKSksCiAgICAgICAgImJ1bmRsZVBhdGgiOiBCdW5kbGUubWFpbi5idW5kbGVQYXRoLAogICAgXQogICAgaWYgbGV0IGRhdGEgPSB0cnk/IEpTT05TZXJpYWxpemF0aW9uLmRhdGEod2l0aEpTT05PYmplY3Q6IHBheWxvYWQsIG9wdGlvbnM6IFsucHJldHR5UHJpbnRlZF0pIHsKICAgICAgICB0cnk/IGRhdGEud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtTdGF0dXNQYXRoKSkKICAgICAgICB0cnk/IEZpbGVNYW5hZ2VyLmRlZmF1bHQuc2V0QXR0cmlidXRlcyhbLnBvc2l4UGVybWlzc2lvbnM6IDBvNjAwXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBvZkl0ZW1BdFBhdGg6IGtTdGF0dXNQYXRoKQogICAgfQogICAgbG9nKCLlrojmiqTov5vnqIvmnYPpmZDoh6rmo4DvvJpBWElzUHJvY2Vzc1RydXN0ZWQgPSBcKHRydXN0ZWQpIikKICAgIGlmICF0cnVzdGVkIHsKICAgICAgICBsb2coIiAg4pqg77iPIOacrOi/m+eoi+aXoOazleaooeaLn+mUruebmOi+k+WFpe+8jOino+mUgeS8muWksei0peOAgiIpCiAgICAgICAgbG9nKCIgICAgIOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDovoXliqnlip/og73jgI3kuK3li77pgIkgQkxFVW5sb2NrQ21k77ybIikKICAgICAgICBsb2coIiAgICAg6Iul5byA5YWz5bey5piv5omT5byA54q25oCB77yM6K+35YWI5Yig6Zmk6K+l6aG55YaN6YeN5paw5re75Yqg77yI5pen5o6I5p2D5Y+v6IO957uR5a6a5Yiw5pen54mI5pys77yJ44CCIikKICAgIH0KfQoKZnVuYyBsb2coXyBtZXNzYWdlOiBTdHJpbmcpIHsKICAgIGxldCBsaW5lID0gIltcKGxvZ0Zvcm1hdHRlci5zdHJpbmcoZnJvbTogRGF0ZSgpKSldIFwobWVzc2FnZSlcbiIKICAgIEZpbGVIYW5kbGUuc3RhbmRhcmRFcnJvci53cml0ZShsaW5lLmRhdGEodXNpbmc6IC51dGY4KSEpCiAgICBpZiBrTG9nRmlsZVdyaXRhYmxlLCBsZXQgaGFuZGxlID0gRmlsZUhhbmRsZShmb3JXcml0aW5nQXRQYXRoOiBrTG9nUGF0aCkgewogICAgICAgIGhhbmRsZS5zZWVrVG9FbmRPZkZpbGUoKQogICAgICAgIGhhbmRsZS53cml0ZShsaW5lLmRhdGEodXNpbmc6IC51dGY4KSEpCiAgICAgICAgdHJ5PyBoYW5kbGUuY2xvc2UoKQogICAgfQp9CgovLyBNQVJLOiAtIOmFjee9rgoKc3RydWN0IENvbmZpZzogQ29kYWJsZSB7CiAgICB2YXIgaG1hY0tleTogU3RyaW5nICAgICAgICAgIC8vIGJhc2U2NCDnvJbnoIHnmoQgMzIg5a2X6IqC6aKE5YWx5Lqr5a+G6ZKlCiAgICB2YXIga2V5Y2hhaW5BY2NvdW50OiBTdHJpbmcgIC8vIOeZu+W9leWvhueggeaJgOWcqOeahOmSpeWMmeS4sui0puaIt+WQjQogICAgdmFyIGRldmljZU5hbWU6IFN0cmluZyAgICAgICAvLyDlub/mkq3lh7rljrvnmoTorr7lpIflkI0KfQoKZnVuYyBsb2FkQ29uZmlnKCkgLT4gQ29uZmlnPyB7CiAgICBndWFyZCBsZXQgZGF0YSA9IEZpbGVNYW5hZ2VyLmRlZmF1bHQuY29udGVudHMoYXRQYXRoOiBrQ29uZmlnUGF0aCkgZWxzZSB7IHJldHVybiBuaWwgfQogICAgcmV0dXJuIHRyeT8gSlNPTkRlY29kZXIoKS5kZWNvZGUoQ29uZmlnLnNlbGYsIGZyb206IGRhdGEpCn0KCmZ1bmMgZW5zdXJlU3VwcG9ydERpcmVjdG9yeSgpIHsKICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5jcmVhdGVEaXJlY3RvcnkoYXRQYXRoOiBrQXBwU3VwcG9ydCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgd2l0aEludGVybWVkaWF0ZURpcmVjdG9yaWVzOiB0cnVlLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBhdHRyaWJ1dGVzOiBbLnBvc2l4UGVybWlzc2lvbnM6IDBvNzAwXSkKfQoKLy8gTUFSSzogLSDlr4bnoIHor7vlj5bvvIhrZXljaGFpbu+8iQoKLy8vIOaKiue7k+aenOaMiSBKU09OIOi+k+WHuu+8jOS+v+S6juiuvue9ruWQkeWvvOino+aekO+8iOmBv+WFjeS4pOerr+WQhOWGmeS4gOWll+mAu+i+ke+8iQpmdW5jIHByaW50SlNPTihfIHBheWxvYWQ6IFtTdHJpbmc6IEFueV0pIHsKICAgIGlmIGxldCBkYXRhID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5kYXRhKHdpdGhKU09OT2JqZWN0OiBwYXlsb2FkLCBvcHRpb25zOiBbLnNvcnRlZEtleXNdKSwKICAgICAgIGxldCB0ZXh0ID0gU3RyaW5nKGRhdGE6IGRhdGEsIGVuY29kaW5nOiAudXRmOCkgewogICAgICAgIHByaW50KHRleHQpCiAgICB9Cn0KCi8vIE1BUks6IC0g5aSa5a+G56CB5a2Y5YKoCi8vCi8vIOavj+WPsOiuvuWkh+WPr+S7peS/neWtmOWkmuS4queZu+W9leWvhuegge+8iOS+i+WmguWImuaUuei/h+WvhueggeOAgeaIluWQjOaXtueUqOWkmuS4qui0puaIt++8ieOAggovLyDop6PplIHml7bmjInpobrluo/pgJDkuKrlsJ3or5XvvIznm7TliLDlsY/luZXop6PlvIDkuLrmraLjgIIKLy8KLy8g5a2Y5YKo5qC85byP77ya6ZKl5YyZ5Liy6YeM5pS+5LiA5LiqIEpTT04g5pWw57uE44CC6L+Z5qC35Y2V5Liq5p2h55uu5bCx6IO96KOF5LiL5YWo6YOo5a+G56CB77yMCi8vIOS5n+WkqeeEtuWFvOWuuSLlj6rmnInkuIDkuKrlr4bnoIEi55qE5pen5qC85byP4oCU4oCU6K+75Y+W5pe26Iul6Kej5p6Q5aSx6LSl5bCx5b2T5L2c5Y2V5Liq5piO5paH5a+G56CB44CCCgovLy8g6K+75Y+W5YWo6YOo5a+G56CB44CC6aG65bqP5Y2z5bCd6K+V6aG65bqP44CCCmZ1bmMgZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogU3RyaW5nKSAtPiBbU3RyaW5nXSB7CiAgICBndWFyZCBsZXQgcmF3ID0gcmVhZEtleWNoYWluUGFzc3dvcmQoYWNjb3VudDogYWNjb3VudCkgZWxzZSB7IHJldHVybiBbXSB9CgogICAgLy8g5paw5qC85byP77yaSlNPTiDmlbDnu4TjgIIKICAgIC8vIOazqOaEj++8muWPquimgeino+aekOaIkOWKn+WwseS7peWug+S4uuWHhu+8jOWNs+S9v+e7k+aenOaYr+epuuaVsOe7hOKAlOKAlAogICAgLy8g5ZCm5YiZ44CMW13jgI3kvJrooqvlvZPmiJDkuIDkuKrkuKTlrZfnrKbnmoTlr4bnoIHvvIjmm77ouKnov4fov5nkuKrlnZHvvInjgIIKICAgIGlmIGxldCBkYXRhID0gcmF3LmRhdGEodXNpbmc6IC51dGY4KSwKICAgICAgIGxldCBhcnIgPSB0cnk/IEpTT05TZXJpYWxpemF0aW9uLmpzb25PYmplY3Qod2l0aDogZGF0YSkgYXM/IFtTdHJpbmddIHsKICAgICAgICByZXR1cm4gYXJyLmZpbHRlciB7ICEkMC5pc0VtcHR5IH0ubWFwKG5vcm1hbGl6ZVBhc3N3b3JkKQogICAgfQoKICAgIC8vIOaXp+agvOW8j++8muWNleS4quaYjuaWh+WvhueggQogICAgcmV0dXJuIHJhdy5pc0VtcHR5ID8gW10gOiBbbm9ybWFsaXplUGFzc3dvcmQocmF3KV0KfQoKLy8vIOWGmeWbnuWFqOmDqOWvhueggeOAguWni+e7iOWGmSBKU09OIOaVsOe7hO+8jOS+v+S6juaXpeWQjuWinuWIoOOAggpAZGlzY2FyZGFibGVSZXN1bHQKZnVuYyBzdG9yZVBhc3N3b3JkcyhfIHBhc3N3b3JkczogW1N0cmluZ10sIGFjY291bnQ6IFN0cmluZykgLT4gQm9vbCB7CiAgICBsZXQgbGlzdCA9IHBhc3N3b3Jkcy5maWx0ZXIgeyAhJDAuaXNFbXB0eSB9Lm1hcChub3JtYWxpemVQYXNzd29yZCkKICAgIGd1YXJkIGxldCBkYXRhID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5kYXRhKHdpdGhKU09OT2JqZWN0OiBsaXN0LCBvcHRpb25zOiBbXSksCiAgICAgICAgICBsZXQganNvbiA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpIGVsc2UgewogICAgICAgIGxvZygi5a+G56CB5bqP5YiX5YyW5aSx6LSlIikKICAgICAgICByZXR1cm4gZmFsc2UKICAgIH0KICAgIHJldHVybiB3cml0ZUtleWNoYWluUGFzc3dvcmQoanNvbiwgYWNjb3VudDogYWNjb3VudCkKfQoKLy8vIOWFvOWuueaXp+aOpeWPo++8mui/lOWbnuesrOS4gOS4quWvhueggQpmdW5jIGZldGNoUGFzc3dvcmQoYWNjb3VudDogU3RyaW5nKSAtPiBTdHJpbmc/IHsKICAgIGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IGFjY291bnQpLmZpcnN0Cn0KCmZ1bmMgcmVhZEtleWNoYWluUGFzc3dvcmQoYWNjb3VudDogU3RyaW5nKSAtPiBTdHJpbmc/IHsKICAgIGxldCBwcm9jZXNzID0gUHJvY2VzcygpCiAgICBwcm9jZXNzLmV4ZWN1dGFibGVVUkwgPSBVUkwoZmlsZVVSTFdpdGhQYXRoOiAiL3Vzci9iaW4vc2VjdXJpdHkiKQogICAgcHJvY2Vzcy5hcmd1bWVudHMgPSBbImZpbmQtZ2VuZXJpYy1wYXNzd29yZCIsCiAgICAgICAgICAgICAgICAgICAgICAgICAiLWEiLCBhY2NvdW50LAogICAgICAgICAgICAgICAgICAgICAgICAgIi1zIiwga0tleWNoYWluU2VydmljZSwKICAgICAgICAgICAgICAgICAgICAgICAgICItdyJdCiAgICBsZXQgcGlwZSA9IFBpcGUoKQogICAgcHJvY2Vzcy5zdGFuZGFyZE91dHB1dCA9IHBpcGUKICAgIHByb2Nlc3Muc3RhbmRhcmRFcnJvciA9IEZpbGVIYW5kbGUubnVsbERldmljZQogICAgZG8gewogICAgICAgIHRyeSBwcm9jZXNzLnJ1bigpCiAgICB9IGNhdGNoIHsKICAgICAgICBsb2coIuaXoOazleaJp+ihjCBzZWN1cml0eSDlkb3ku6Q6IFwoZXJyb3IpIikKICAgICAgICByZXR1cm4gbmlsCiAgICB9CiAgICBsZXQgZGF0YSA9IHBpcGUuZmlsZUhhbmRsZUZvclJlYWRpbmcucmVhZERhdGFUb0VuZE9mRmlsZSgpCiAgICBwcm9jZXNzLndhaXRVbnRpbEV4aXQoKQogICAgZ3VhcmQgcHJvY2Vzcy50ZXJtaW5hdGlvblN0YXR1cyA9PSAwIGVsc2UgeyByZXR1cm4gbmlsIH0KICAgIHZhciBwdyA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpID8/ICIiCiAgICAvLyBzZWN1cml0eSAtdyDkvJrpmYTluKbkuIDkuKrmjaLooYwKICAgIHdoaWxlIHB3Lmhhc1N1ZmZpeCgiXG4iKSB8fCBwdy5oYXNTdWZmaXgoIlxyIikgeyBwdy5yZW1vdmVMYXN0KCkgfQogICAgZ3VhcmQgIXB3LmlzRW1wdHkgZWxzZSB7IHJldHVybiBuaWwgfQogICAgcmV0dXJuIGRlY29kZUhleElmTmVlZGVkKHB3KQp9CgovLy8gYHNlY3VyaXR5IC13YCDlr7kqKumdniBBU0NJSSoqIOeahOWvhueggeS8mui+k+WHuuWNgeWFrei/m+WItuS4suiAjOS4jeaYr+WOn+aWhwovLy8g77yI5L6L5aaC44CM5Lit5paH5a+G56CB44CN5Lya6K+75oiQICJlNGI4YWRlNjk2ODdlNWFmODZlN2EwODEi77yJ44CCCi8vLyDov5nph4zmiorlroPov5jljp/jgIIKLy8vCi8vLyDliKTlrprmnaHku7bliLvmhI/kv53lrojvvIzpgb/lhY3or6/kvKQi5pys5p2l5bCx5piv5Y2B5YWt6L+b5Yi2IueahCBBU0NJSSDlr4bnoIHvvJoKLy8vIOWPquacieaVtOS4suaYr+WQiOazleWNgeWFrei/m+WItuOAgemVv+W6puS4uuWBtuaVsO+8jCoq5LiU6Kej56CB5ZCO5ZCr6Z2eIEFTQ0lJIOWtl+espioq5pe25omN6L+Y5Y6f44CCCi8vLyDnuq8gQVNDSUkg55qE5a+G56CB6Kej56CB5ZCO5LuN5pivIEFTQ0lJ77yM5Zug5q2k5LiN5Lya6KKr6K+v5pS544CCCmZ1bmMgZGVjb2RlSGV4SWZOZWVkZWQoXyB2YWx1ZTogU3RyaW5nKSAtPiBTdHJpbmcgewogICAgbGV0IGhleERpZ2l0cyA9IENoYXJhY3RlclNldChjaGFyYWN0ZXJzSW46ICIwMTIzNDU2Nzg5YWJjZGVmQUJDREVGIikKICAgIGd1YXJkIHZhbHVlLmNvdW50ID49IDIsIHZhbHVlLmNvdW50ICUgMiA9PSAwLAogICAgICAgICAgdmFsdWUudW5pY29kZVNjYWxhcnMuYWxsU2F0aXNmeSh7IGhleERpZ2l0cy5jb250YWlucygkMCkgfSkgZWxzZSB7CiAgICAgICAgcmV0dXJuIHZhbHVlCiAgICB9CiAgICB2YXIgYnl0ZXM6IFtVSW50OF0gPSBbXQogICAgYnl0ZXMucmVzZXJ2ZUNhcGFjaXR5KHZhbHVlLmNvdW50IC8gMikKICAgIHZhciBpZHggPSB2YWx1ZS5zdGFydEluZGV4CiAgICB3aGlsZSBpZHggPCB2YWx1ZS5lbmRJbmRleCB7CiAgICAgICAgbGV0IG5leHQgPSB2YWx1ZS5pbmRleChpZHgsIG9mZnNldEJ5OiAyKQogICAgICAgIGd1YXJkIGxldCBieXRlID0gVUludDgodmFsdWVbaWR4Li48bmV4dF0sIHJhZGl4OiAxNikgZWxzZSB7IHJldHVybiB2YWx1ZSB9CiAgICAgICAgYnl0ZXMuYXBwZW5kKGJ5dGUpCiAgICAgICAgaWR4ID0gbmV4dAogICAgfQogICAgZ3VhcmQgbGV0IGRlY29kZWQgPSBTdHJpbmcoYnl0ZXM6IGJ5dGVzLCBlbmNvZGluZzogLnV0ZjgpIGVsc2UgeyByZXR1cm4gdmFsdWUgfQogICAgLy8g5Y+q5pyJ6Kej56CB57uT5p6c5ZCr6Z2eIEFTQ0lJIOaXtuaJjeiupOWumuaYryBoZXgg57yW56CB77ybCiAgICAvLyDlkKbliJnkv53nlZnljp/mlofvvIzpgb/lhY3miorlvaLlpoIgImRlYWRiZWVmIiDnmoTlr4bnoIHmlLnmjonjgIIKICAgIGd1YXJkIGRlY29kZWQudW5pY29kZVNjYWxhcnMuY29udGFpbnMod2hlcmU6IHsgJDAudmFsdWUgPiAxMjcgfSkgZWxzZSB7IHJldHVybiB2YWx1ZSB9CiAgICBsb2coIumSpeWMmeS4sui/lOWbnueahOaYr+WNgeWFrei/m+WItue8luegge+8jOW3sui/mOWOn+S4uuWOn+aWh++8iFwodmFsdWUuY291bnQpIOKGkiBcKGRlY29kZWQuY291bnQpIOWtl+espu+8iSIpCiAgICByZXR1cm4gZGVjb2RlZAp9CgovLy8g57uf5LiA6KeE6IyD5YyW5b2i5byP44CCCi8vLwovLy8gbWFjT1Mg6ZKl5YyZ5Liy5Lya5oqK6Z2eIEFTQ0lJIOWtl+espuWtmOaIkCBORkTvvIjliIbop6PlvI/vvIzDqSA9IGUgKyDnu4TlkIjph43pn7PvvInvvIwKLy8vIOiAjOi+k+WFpeW+gOW+gOaYryBORkPvvIjpooTnu4TlkIjvvInjgILkuKTnp43lvaLlvI/muLLmn5Pnm7jlkIzjgIFORkMg5b2S5LiA5ZCO55u4562J77yMCi8vLyDkvYbnoIHngrnkuI3lkIzkvJrorqnlrZfnrKbkuLLmr5TovoPlh7rnjrDlgYflpLHotKXjgILov5nph4znu5/kuIDmiJAgTkZD77yM6K6p5a2Y5Y+W56Gu5a6a44CCCmZ1bmMgbm9ybWFsaXplUGFzc3dvcmQoXyBzOiBTdHJpbmcpIC0+IFN0cmluZyB7CiAgICBzLnByZWNvbXBvc2VkU3RyaW5nV2l0aENhbm9uaWNhbE1hcHBpbmcKfQoKLy8vIOeUqCBzZWN1cml0eSDlkb3ku6TlhpnlhaXpkqXljJnkuLLvvIgtVSDooajnpLrlrZjlnKjliJnljp/lnLDmm7TmlrDvvIkKZnVuYyB3cml0ZUtleWNoYWluUGFzc3dvcmQoXyB2YWx1ZTogU3RyaW5nLCBhY2NvdW50OiBTdHJpbmcpIC0+IEJvb2wgewogICAgbGV0IHIgPSBydW5Qcm9jZXNzKCIvdXNyL2Jpbi9zZWN1cml0eSIsCiAgICAgICAgICAgICAgICAgICAgICAgWyJhZGQtZ2VuZXJpYy1wYXNzd29yZCIsICItVSIsCiAgICAgICAgICAgICAgICAgICAgICAgICItYSIsIGFjY291bnQsCiAgICAgICAgICAgICAgICAgICAgICAgICItcyIsIGtLZXljaGFpblNlcnZpY2UsCiAgICAgICAgICAgICAgICAgICAgICAgICItbCIsICJCTEVVbmxvY2tDbWQiLAogICAgICAgICAgICAgICAgICAgICAgICAiLXciLCB2YWx1ZV0pCiAgICBpZiByLmNvZGUgIT0gMCB7CiAgICAgICAgbGV0IGRldGFpbCA9IHIuZXJyLnRyaW1taW5nQ2hhcmFjdGVycyhpbjogLndoaXRlc3BhY2VzQW5kTmV3bGluZXMpCiAgICAgICAgbG9nKCLlhpnlhaXpkqXljJnkuLLlpLHotKXvvJrpgIDlh7rnoIEgXChyLmNvZGUpIiArIChkZXRhaWwuaXNFbXB0eSA/ICIiIDogIu+8mlwoZGV0YWlsKSIpKQogICAgICAgIHJldHVybiBmYWxzZQogICAgfQogICAgcmV0dXJuIHRydWUKfQoKLy8vIOaJp+ihjOWklumDqOWRveS7pOW5tuWQjOaXtui/lOWbniBzdGRlcnLvvIzkvr/kuo7or4rmlq0KZnVuYyBydW5Qcm9jZXNzKF8gcGF0aDogU3RyaW5nLCBfIGFyZ3M6IFtTdHJpbmddKSAtPiAoY29kZTogSW50MzIsIG91dDogU3RyaW5nLCBlcnI6IFN0cmluZykgewogICAgbGV0IHAgPSBQcm9jZXNzKCkKICAgIHAuZXhlY3V0YWJsZVVSTCA9IFVSTChmaWxlVVJMV2l0aFBhdGg6IHBhdGgpCiAgICBwLmFyZ3VtZW50cyA9IGFyZ3MKICAgIGxldCBvdXRQaXBlID0gUGlwZSgpCiAgICBsZXQgZXJyUGlwZSA9IFBpcGUoKQogICAgcC5zdGFuZGFyZE91dHB1dCA9IG91dFBpcGUKICAgIHAuc3RhbmRhcmRFcnJvciA9IGVyclBpcGUKICAgIGRvIHsgdHJ5IHAucnVuKCkgfSBjYXRjaCB7CiAgICAgICAgcmV0dXJuICgtMSwgIiIsIGVycm9yLmxvY2FsaXplZERlc2NyaXB0aW9uKQogICAgfQogICAgbGV0IG91dERhdGEgPSBvdXRQaXBlLmZpbGVIYW5kbGVGb3JSZWFkaW5nLnJlYWREYXRhVG9FbmRPZkZpbGUoKQogICAgbGV0IGVyckRhdGEgPSBlcnJQaXBlLmZpbGVIYW5kbGVGb3JSZWFkaW5nLnJlYWREYXRhVG9FbmRPZkZpbGUoKQogICAgcC53YWl0VW50aWxFeGl0KCkKICAgIHJldHVybiAocC50ZXJtaW5hdGlvblN0YXR1cywKICAgICAgICAgICAgU3RyaW5nKGRhdGE6IG91dERhdGEsIGVuY29kaW5nOiAudXRmOCkgPz8gIiIsCiAgICAgICAgICAgIFN0cmluZyhkYXRhOiBlcnJEYXRhLCBlbmNvZGluZzogLnV0ZjgpID8/ICIiKQp9CgovLyBNQVJLOiAtIOWxj+W5leeKtuaAgSAvIOaYvuekuuWZqOaOp+WItgoKZnVuYyBpc1NjcmVlbkxvY2tlZCgpIC0+IEJvb2wgewogICAgLy8g5YWs5byAIEFQSe+8mkNHU2Vzc2lvbkNvcHlDdXJyZW50RGljdGlvbmFyee+8iFF1YXJ0eiDnp4HmnInkvYbooqvlub/ms5vkvb/nlKjnmoQgc2Vzc2lvbiDlrZflhbjvvIkKICAgIGd1YXJkIGxldCBkaWN0ID0gQ0dTZXNzaW9uQ29weUN1cnJlbnREaWN0aW9uYXJ5KCkgYXM/IFtTdHJpbmc6IEFueV0gZWxzZSB7IHJldHVybiBmYWxzZSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEludCB7IHJldHVybiBsb2NrZWQgPT0gMSB9CiAgICBpZiBsZXQgbG9ja2VkID0gZGljdFsiQ0dTU2Vzc2lvblNjcmVlbklzTG9ja2VkIl0gYXM/IEJvb2wgeyByZXR1cm4gbG9ja2VkIH0KICAgIHJldHVybiBmYWxzZQp9Cgp2YXIgZGlzcGxheUFzc2VydGlvbklEID0gSU9QTUFzc2VydGlvbklEKDApCgpmdW5jIHdha2VEaXNwbGF5KCkgewogICAgSU9QTUFzc2VydGlvbkRlY2xhcmVVc2VyQWN0aXZpdHkoIkJMRVVubG9ja0NtZCIgYXMgQ0ZTdHJpbmcsIGtJT1BNVXNlckFjdGl2ZUxvY2FsLCAmZGlzcGxheUFzc2VydGlvbklEKQp9CgpmdW5jIHNsZWVwRGlzcGxheSgpIHsKICAgIC8vIElPUmVnaXN0cnlFbnRyeUZyb21QYXRoIOmcgOimgSBDIOWtl+espuS4sui3r+W+hAogICAgbGV0IGVudHJ5ID0gSU9SZWdpc3RyeUVudHJ5RnJvbVBhdGgoa0lPTWFzdGVyUG9ydERlZmF1bHQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiSU9TZXJ2aWNlOi9JT1Jlc291cmNlcy9JT0Rpc3BsYXlXcmFuZ2xlciIpCiAgICBpZiBlbnRyeSAhPSAwIHsKICAgICAgICBJT1JlZ2lzdHJ5RW50cnlTZXRDRlByb3BlcnR5KGVudHJ5LCAiSU9SZXF1ZXN0SWRsZSIgYXMgQ0ZTdHJpbmcsIGtDRkJvb2xlYW5UcnVlKQogICAgICAgIElPT2JqZWN0UmVsZWFzZShlbnRyeSkKICAgIH0KfQoKLy8gTUFSSzogLSDlhajlsYDlvIDlhbMKCi8vLyDlronlhajmtYvor5XmqKHlvI/vvJrlrozmlbTotbDkuIDpgY0gQkxFIOaUtuWMheS4juagoemqjO+8jOS9huS4jeecn+eahOazqOWFpeWvhueggQp2YXIgZHJ5UnVuID0gZmFsc2UKCi8vIE1BUks6IC0g6ZSu55uY5LqL5Lu25rOo5YWl77yI6Kej6ZSB55qE5qC45b+D77yJCgovLy8g5Y+R6YCB5LiA5Liq5Y2V54us55qE5oyJ6ZSu77yI55So6Jma5ouf6ZSu56CB77yJ77yM5L6L5aaCIEVzYyDnlKjmnaXmuIXnqbrlr4bnoIHovpPlhaXmoYYKZnVuYyBzZW5kS2V5KF8gdmlydHVhbEtleTogQ0dLZXlDb2RlKSB7CiAgICBpZiBkcnlSdW4geyByZXR1cm4gfQogICAgZ3VhcmQgbGV0IHNvdXJjZSA9IENHRXZlbnRTb3VyY2Uoc3RhdGVJRDogLmhpZFN5c3RlbVN0YXRlKSBlbHNlIHsgcmV0dXJuIH0KICAgIENHRXZlbnQoa2V5Ym9hcmRFdmVudFNvdXJjZTogc291cmNlLCB2aXJ0dWFsS2V5OiB2aXJ0dWFsS2V5LCBrZXlEb3duOiB0cnVlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IHZpcnR1YWxLZXksIGtleURvd246IGZhbHNlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQp9CgpmdW5jIGZha2VLZXlTdHJva2VzKF8gc3RyaW5nOiBTdHJpbmcpIHsKICAgIGlmIGRyeVJ1biB7CiAgICAgICAgbG9nKCJbZHJ5LXJ1bl0g5pys5bqU5rOo5YWlIFwoc3RyaW5nLmNvdW50KSDkuKrlrZfnrKbnmoTlr4bnoIHlubblm57ovabvvIzlt7Lot7Pov4ciKQogICAgICAgIHJldHVybgogICAgfQogICAgZ3VhcmQgbGV0IHNvdXJjZSA9IENHRXZlbnRTb3VyY2Uoc3RhdGVJRDogLmhpZFN5c3RlbVN0YXRlKSBlbHNlIHsKICAgICAgICBsb2coIuaXoOazleWIm+W7uiBDR0V2ZW50U291cmNlIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIGxldCB1bml0cyA9IEFycmF5KHN0cmluZy51dGYxNikKICAgIGxldCBwZXJDaHVuayA9IDIwICAgLy8g5Y2V5Liq6ZSu55uY5LqL5Lu25pyA5aSa5pC65bimIDIwIOS4qiBVVEYtMTYg5a2X56ymCgogICAgdmFyIGluZGV4ID0gMAogICAgd2hpbGUgaW5kZXggPCB1bml0cy5jb3VudCB7CiAgICAgICAgbGV0IGNvdW50ID0gbWluKHBlckNodW5rLCB1bml0cy5jb3VudCAtIGluZGV4KQogICAgICAgIHZhciBidWZmZXIgPSBBcnJheSh1bml0c1tpbmRleCAuLjwgaW5kZXggKyBjb3VudF0pCgogICAgICAgIGd1YXJkIGxldCBkb3duID0gQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDQ5LCBrZXlEb3duOiB0cnVlKSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGRvd24ua2V5Ym9hcmRTZXRVbmljb2RlU3RyaW5nKHN0cmluZ0xlbmd0aDogY291bnQsIHVuaWNvZGVTdHJpbmc6ICZidWZmZXIpCiAgICAgICAgZG93bi5wb3N0KHRhcDogLmNnaGlkRXZlbnRUYXApCgogICAgICAgIENHRXZlbnQoa2V5Ym9hcmRFdmVudFNvdXJjZTogc291cmNlLCB2aXJ0dWFsS2V5OiA0OSwga2V5RG93bjogZmFsc2UpPwogICAgICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgICAgIGluZGV4ICs9IGNvdW50CiAgICB9CgogICAgLy8g5Zue6L2m6ZSu77yIdmlydHVhbEtleSA1MiA9IFJldHVybu+8iQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiB0cnVlKT8KICAgICAgICAucG9zdCh0YXA6IC5jZ2hpZEV2ZW50VGFwKQogICAgQ0dFdmVudChrZXlib2FyZEV2ZW50U291cmNlOiBzb3VyY2UsIHZpcnR1YWxLZXk6IDUyLCBrZXlEb3duOiBmYWxzZSk/CiAgICAgICAgLnBvc3QodGFwOiAuY2doaWRFdmVudFRhcCkKfQoKZnVuYyBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IEJvb2wgPSBmYWxzZSkgLT4gQm9vbCB7CiAgICBsZXQga2V5ID0ga0FYVHJ1c3RlZENoZWNrT3B0aW9uUHJvbXB0LnRha2VVbnJldGFpbmVkVmFsdWUoKSBhcyBTdHJpbmcKICAgIHJldHVybiBBWElzUHJvY2Vzc1RydXN0ZWRXaXRoT3B0aW9ucyhba2V5OiBwcm9tcHRdIGFzIENGRGljdGlvbmFyeSkKfQoKLy8gTUFSSzogLSDop6PplIEgLyDplIHlrpoKCnZhciB1bmxvY2tJbkZsaWdodCA9IGZhbHNlCgovLy8g6Ieq5Yqo6Kej6ZSB77ya5ZSk6YaS5bGP5bmVIC0+IOehruiupOWkhOS6jumUgeWxjyAtPiDms6jlhaXlr4bnoIEKZnVuYyBwZXJmb3JtVW5sb2NrKHJlcGx5OiBAZXNjYXBpbmcgKFN0cmluZykgLT4gVm9pZCkgewogICAgZ3VhcmQgIXVubG9ja0luRmxpZ2h0IGVsc2UgewogICAgICAgIHJlcGx5KCJCVVNZIikKICAgICAgICByZXR1cm4KICAgIH0KICAgIC8vIGRyeS1ydW4g5LiL5LiN5qOA5p+l6L6F5Yqp5Yqf6IO95p2D6ZmQ77yM5Zug5Li65LiN5Lya55yf55qE5rOo5YWl5LqL5Lu2CiAgICBndWFyZCBkcnlSdW4gfHwgYWNjZXNzaWJpbGl0eUdyYW50ZWQoKSBlbHNlIHsKICAgICAgICBsb2coIuino+mUgeWksei0pe+8mue8uuWwkeOAjOi+heWKqeWKn+iDveOAjeadg+mZkCIpCiAgICAgICAgcmVwbHkoIkVSUl9OT19BWCIpCiAgICAgICAgcmV0dXJuCiAgICB9CiAgICBndWFyZCBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIGVsc2UgewogICAgICAgIGxvZygi6Kej6ZSB5aSx6LSl77ya6YWN572u57y65aSxIikKICAgICAgICByZXBseSgiRVJSX0NPTkZJRyIpCiAgICAgICAgcmV0dXJuCiAgICB9CgogICAgbGV0IHBhc3N3b3JkcyA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IGNvbmZpZy5rZXljaGFpbkFjY291bnQpCiAgICBndWFyZCAhcGFzc3dvcmRzLmlzRW1wdHkgZWxzZSB7CiAgICAgICAgbG9nKCLop6PplIHlpLHotKXvvJrpkqXljJnkuLLkuK3or7vkuI3liLDlr4bnoIEiKQogICAgICAgIHJlcGx5KCJFUlJfTk9fUFciKQogICAgICAgIHJldHVybgogICAgfQoKICAgIGlmIGRyeVJ1biB7CiAgICAgICAgbG9nKCJbZHJ5LXJ1bl0g5qCh6aqM6YCa6L+H77yM5YWxIFwocGFzc3dvcmRzLmNvdW50KSDkuKrlr4bnoIHvvIzmnKzlupTpgJDkuKrlsJ3or5UiKQogICAgICAgIHJlcGx5KCJPSyIpCiAgICAgICAgcmV0dXJuCiAgICB9CgogICAgdW5sb2NrSW5GbGlnaHQgPSB0cnVlCiAgICB3cml0ZURhZW1vblN0YXR1cygpCiAgICBsb2coIuaUtuWIsOino+mUgeaMh+S7pO+8jOW8gOWni+aJp+ihjO+8iFwocGFzc3dvcmRzLmNvdW50KSDkuKrlr4bnoIHlvoXlsJ3or5XvvIkiKQoKICAgIHdha2VEaXNwbGF5KCkKCiAgICAvLyDmmL7npLrlmajllKTphpLlkI7pnIDopoHkuIDngrnml7bpl7TmiY3nnJ/mraPngrnkuq7vvIzph43or5Xlh6Dova4KICAgIHZhciB3YWtlQXR0ZW1wdCA9IDAKICAgIGxldCBtYXhXYWtlQXR0ZW1wdHMgPSA4CiAgICAvLy8g5q+P5Liq5a+G56CB5rOo5YWl5ZCO77yM562J5b6F5aSa5LmF5YaN5Yik5pat5piv5ZCm6Kej6ZSB5oiQ5YqfCiAgICBsZXQgc2V0dGxlRGVsYXkgPSAxLjIKCiAgICAvLy8g6Kej6ZSB5oiQ5Yqf5pS25bC+CiAgICBmdW5jIHN1Y2NlZWRlZChhZnRlciB0cmllZDogSW50KSB7CiAgICAgICAgdW5sb2NrSW5GbGlnaHQgPSBmYWxzZQogICAgICAgIGlmIHRyaWVkID09IDAgewogICAgICAgICAgICBsb2coIuW3suazqOWFpeWvhueggeW5tuWbnui9pu+8jOino+mUgeaMh+S7pOWujOaIkCIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9nKCLnrKwgXCh0cmllZCArIDEpIOS4quWvhueggeeUn+aViO+8jOino+mUgeaMh+S7pOWujOaIkCIpCiAgICAgICAgfQogICAgICAgIHJlcGx5KCJPSyIpCiAgICB9CgogICAgLy8vIOS+neasoeWwneivleavj+S4quWvhuegge+8m+WFqOmDqOWksei0peWImeWbnuaKpQogICAgZnVuYyB0cnlQYXNzd29yZChhdCBpbmRleDogSW50KSB7CiAgICAgICAgZ3VhcmQgaW5kZXggPCBwYXNzd29yZHMuY291bnQgZWxzZSB7CiAgICAgICAgICAgIHVubG9ja0luRmxpZ2h0ID0gZmFsc2UKICAgICAgICAgICAgbG9nKCLlt7LlsJ3or5Xlhajpg6ggXChwYXNzd29yZHMuY291bnQpIOS4quWvhuegge+8jOWxj+W5leS7jeacquino+mUgSIpCiAgICAgICAgICAgIHJlcGx5KCJFUlJfQUxMX1BXIikKICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgfQoKICAgICAgICBsZXQgaXNMYXN0ID0gKGluZGV4ID09IHBhc3N3b3Jkcy5jb3VudCAtIDEpCiAgICAgICAgbG9nKCLms6jlhaXnrKwgXChpbmRleCArIDEpL1wocGFzc3dvcmRzLmNvdW50KSDkuKrlr4bnoIHvvIhcKHBhc3N3b3Jkc1tpbmRleF0uY291bnQpIOWtl+espu+8iSIpCgogICAgICAgIC8vIOWwneivleWJjeWFiOa4heepuui+k+WFpeahhu+8muS4iuS4gOS4quWvhueggeiLpemUmeivr++8jOWtl+autemHjOWPr+iDveaui+eVmeWGheWuueOAggogICAgICAgIC8vIOeUqCBFc2Mg5riF56m65q+U6YCQ5a2X56ym5Yig6Zmk5Y+v6Z2g44CCCiAgICAgICAgaWYgaW5kZXggPiAwIHsKICAgICAgICAgICAgc2VuZEtleSgweDM1KSAgIC8vIEVzYwogICAgICAgICAgICBUaHJlYWQuc2xlZXAoZm9yVGltZUludGVydmFsOiAwLjI1KQogICAgICAgIH0KCiAgICAgICAgZmFrZUtleVN0cm9rZXMocGFzc3dvcmRzW2luZGV4XSkKCiAgICAgICAgRGlzcGF0Y2hRdWV1ZS5tYWluLmFzeW5jQWZ0ZXIoZGVhZGxpbmU6IC5ub3coKSArIHNldHRsZURlbGF5KSB7CiAgICAgICAgICAgIGlmICFpc1NjcmVlbkxvY2tlZCgpIHsKICAgICAgICAgICAgICAgIHN1Y2NlZWRlZChhZnRlcjogaW5kZXgpCiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBpZiAhaXNMYXN0IHsgbG9nKCIgIOivpeWvhueggeaXoOaViO+8jOe7p+e7reWwneivleS4i+S4gOS4qiIpIH0KICAgICAgICAgICAgICAgIHRyeVBhc3N3b3JkKGF0OiBpbmRleCArIDEpCiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CgogICAgZnVuYyB0aWNrKCkgewogICAgICAgIHdha2VBdHRlbXB0ICs9IDEKICAgICAgICB3YWtlRGlzcGxheSgpCgogICAgICAgIGlmIGlzU2NyZWVuTG9ja2VkKCkgewogICAgICAgICAgICAvLyDlho3nrYkgMC40cyDorqnlr4bnoIHovpPlhaXmoYbojrflvpfnhKbngrkKICAgICAgICAgICAgRGlzcGF0Y2hRdWV1ZS5tYWluLmFzeW5jQWZ0ZXIoZGVhZGxpbmU6IC5ub3coKSArIDAuNCkgewogICAgICAgICAgICAgICAgdHJ5UGFzc3dvcmQoYXQ6IDApCiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgfQoKICAgICAgICBpZiB3YWtlQXR0ZW1wdCA+PSBtYXhXYWtlQXR0ZW1wdHMgewogICAgICAgICAgICB1bmxvY2tJbkZsaWdodCA9IGZhbHNlCiAgICAgICAgICAgIGxvZygi6Kej6ZSB5Lit5q2i77ya5bGP5bmV5pyq5aSE5LqO6ZSB5a6a54q25oCB77yI5Y+v6IO95bey55Sx55So5oi35omL5Yqo6Kej6ZSB77yJIikKICAgICAgICAgICAgcmVwbHkoIk5PVF9MT0NLRUQiKQogICAgICAgICAgICByZXR1cm4KICAgICAgICB9CiAgICAgICAgRGlzcGF0Y2hRdWV1ZS5tYWluLmFzeW5jQWZ0ZXIoZGVhZGxpbmU6IC5ub3coKSArIDAuNSwgZXhlY3V0ZTogdGljaykKICAgIH0KCiAgICB0aWNrKCkKfQoKZnVuYyBwZXJmb3JtTG9jayhyZXBseTogQGVzY2FwaW5nIChTdHJpbmcpIC0+IFZvaWQpIHsKICAgIGlmIGRyeVJ1biB7CiAgICAgICAgbG9nKCJbZHJ5LXJ1bl0g5pys5bqU6ZSB5a6a5bGP5bmV77yM5bey6Lez6L+HIikKICAgICAgICByZXBseSgiT0siKQogICAgICAgIHJldHVybgogICAgfQogICAgbG9nKCLmlLbliLDplIHlrprmjIfku6QiKQogICAgLy8g6YCa6L+H6ZSB5bGP56eB5pyJIEFQSSDplIHlrprvvJvoi6XkuI3lj6/nlKjliJnpgIDlm57lsY/kv50KICAgIGxldCBoYW5kbGUgPSBkbG9wZW4oIi9TeXN0ZW0vTGlicmFyeS9Qcml2YXRlRnJhbWV3b3Jrcy9sb2dpbi5mcmFtZXdvcmsvbG9naW4iLCBSVExEX05PVykKICAgIGlmIGxldCBoYW5kbGUgPSBoYW5kbGUsIGxldCBzeW0gPSBkbHN5bShoYW5kbGUsICJTQUNMb2NrU2NyZWVuSW1tZWRpYXRlIikgewogICAgICAgIHR5cGVhbGlhcyBMb2NrRm4gPSBAY29udmVudGlvbihjKSAoKSAtPiBJbnQzMgogICAgICAgIGxldCBsb2NrID0gdW5zYWZlQml0Q2FzdChzeW0sIHRvOiBMb2NrRm4uc2VsZikKICAgICAgICBsZXQgcmVzdWx0ID0gbG9jaygpCiAgICAgICAgZGxjbG9zZShoYW5kbGUpCiAgICAgICAgbG9nKCJTQUNMb2NrU2NyZWVuSW1tZWRpYXRlIOi/lOWbniBcKHJlc3VsdCkiKQogICAgICAgIHJlcGx5KHJlc3VsdCA9PSAwID8gIk9LIiA6ICJFUlJfTE9DSyIpCiAgICB9IGVsc2UgewogICAgICAgIGxvZygibG9naW4uZnJhbWV3b3JrIOS4jeWPr+eUqO+8jOaUueeUqOWxj+S/nemUgeWumiIpCiAgICAgICAgUHJvY2Vzcy5sYXVuY2hlZFByb2Nlc3MobGF1bmNoUGF0aDogIi91c3IvYmluL29wZW4iLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGFyZ3VtZW50czogWyItYSIsICJTY3JlZW5TYXZlckVuZ2luZSJdKQogICAgICAgIHJlcGx5KCJPS19TUyIpCiAgICB9CiAgICBzbGVlcERpc3BsYXkoKQp9CgovLyBNQVJLOiAtIOmYsumHjeaUvgoKZmluYWwgY2xhc3MgTm9uY2VDYWNoZSB7CiAgICBwcml2YXRlIHZhciBzZWVuOiBbU3RyaW5nOiBEYXRlXSA9IFs6XQogICAgcHJpdmF0ZSBsZXQgbG9jayA9IE5TTG9jaygpCgogICAgLy8vIOi/lOWbniB0cnVlIOihqOekuuivpSBub25jZSDmmK/mlrDnmoTvvIjmnKrooqvph43mlL7vvIkKICAgIGZ1bmMgYWNjZXB0KF8gbm9uY2U6IERhdGEpIC0+IEJvb2wgewogICAgICAgIGxldCBrZXkgPSBub25jZS5iYXNlNjRFbmNvZGVkU3RyaW5nKCkKICAgICAgICBsb2NrLmxvY2soKQogICAgICAgIGRlZmVyIHsgbG9jay51bmxvY2soKSB9CiAgICAgICAgbGV0IG5vdyA9IERhdGUoKQogICAgICAgIHNlZW4gPSBzZWVuLmZpbHRlciB7IG5vdy50aW1lSW50ZXJ2YWxTaW5jZSgkMC52YWx1ZSkgPCAzMDAgfQogICAgICAgIGlmIHNlZW5ba2V5XSAhPSBuaWwgeyByZXR1cm4gZmFsc2UgfQogICAgICAgIGlmIHNlZW4uY291bnQgPj0ga05vbmNlQ2FjaGVMaW1pdCB7CiAgICAgICAgICAgIGlmIGxldCBvbGRlc3QgPSBzZWVuLm1pbihieTogeyAkMC52YWx1ZSA8ICQxLnZhbHVlIH0pPy5rZXkgeyBzZWVuLnJlbW92ZVZhbHVlKGZvcktleTogb2xkZXN0KSB9CiAgICAgICAgfQogICAgICAgIHNlZW5ba2V5XSA9IG5vdwogICAgICAgIHJldHVybiB0cnVlCiAgICB9Cn0KCmxldCBub25jZUNhY2hlID0gTm9uY2VDYWNoZSgpCgovLyBNQVJLOiAtIOaVsOaNruWMheagoemqjAoKZW51bSBWZXJpZnlSZXN1bHQgewogICAgY2FzZSBvayhjb21tYW5kOiBVSW50OCkKICAgIGNhc2UgZmFpbGVkKFN0cmluZykKfQoKZnVuYyB2ZXJpZnlQYWNrZXQoXyBkYXRhOiBEYXRhLCBrZXk6IFN5bW1ldHJpY0tleSkgLT4gVmVyaWZ5UmVzdWx0IHsKICAgIGd1YXJkIGRhdGEuY291bnQgPj0ga1BhY2tldExlbiBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9MRU4iKSB9CiAgICBsZXQgYnl0ZXMgPSBbVUludDhdKGRhdGEpCgogICAgZ3VhcmQgYnl0ZXNbMF0gPT0ga01hZ2ljWzBdLCBieXRlc1sxXSA9PSBrTWFnaWNbMV0gZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfTUFHSUMiKSB9CiAgICBndWFyZCBieXRlc1syXSA9PSBrVmVyc2lvbiBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9WRVIiKSB9CgogICAgbGV0IG5vdyA9IEludDY0KERhdGUoKS50aW1lSW50ZXJ2YWxTaW5jZTE5NzApCiAgICB2YXIgdHM6IEludDY0ID0gMAogICAgZm9yIGkgaW4gMC4uPDggeyB0cyA9ICh0cyA8PCA4KSB8IEludDY0KGJ5dGVzWzQgKyBpXSkgfQogICAgZ3VhcmQgYWJzKG5vdyAtIHRzKSA8PSBrVGltZXN0YW1wU2tldyBlbHNlIHsgcmV0dXJuIC5mYWlsZWQoIkVSUl9USU1FIikgfQoKICAgIGxldCBub25jZSA9IERhdGEoYnl0ZXNbMTIuLjwyOF0pCiAgICBndWFyZCBub25jZUNhY2hlLmFjY2VwdChub25jZSkgZWxzZSB7IHJldHVybiAuZmFpbGVkKCJFUlJfUkVQTEFZIikgfQoKICAgIGxldCBtZXNzYWdlID0gRGF0YShieXRlc1swLi48a0htYWNPZmZzZXRdKQogICAgbGV0IGV4cGVjdGVkID0gRGF0YShITUFDPFNIQTI1Nj4uYXV0aGVudGljYXRpb25Db2RlKGZvcjogbWVzc2FnZSwgdXNpbmc6IGtleSkpCiAgICBsZXQgcmVjZWl2ZWQgPSBEYXRhKGJ5dGVzW2tIbWFjT2Zmc2V0Li48a1BhY2tldExlbl0pCiAgICAvLyDluLjph4/ml7bpl7Tmr5TovoMKICAgIGd1YXJkIGV4cGVjdGVkLmNvdW50ID09IHJlY2VpdmVkLmNvdW50IGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX0hNQUMiKSB9CiAgICB2YXIgZGlmZjogVUludDggPSAwCiAgICBmb3IgaSBpbiAwLi48ZXhwZWN0ZWQuY291bnQgeyBkaWZmIHw9IGV4cGVjdGVkW2ldIF4gcmVjZWl2ZWRbaV0gfQogICAgZ3VhcmQgZGlmZiA9PSAwIGVsc2UgeyByZXR1cm4gLmZhaWxlZCgiRVJSX0hNQUMiKSB9CgogICAgcmV0dXJuIC5vayhjb21tYW5kOiBieXRlc1szXSkKfQoKLy8gTUFSSzogLSBCTEUg5aSW6K6+CgpmaW5hbCBjbGFzcyBQZXJpcGhlcmFsU2VydmVyOiBOU09iamVjdCwgQ0JQZXJpcGhlcmFsTWFuYWdlckRlbGVnYXRlIHsKICAgIHByaXZhdGUgdmFyIG1hbmFnZXI6IENCUGVyaXBoZXJhbE1hbmFnZXIhCiAgICBwcml2YXRlIHZhciBjb21tYW5kQ2hhcjogQ0JNdXRhYmxlQ2hhcmFjdGVyaXN0aWMhCiAgICBwcml2YXRlIHZhciBzdGF0dXNDaGFyOiBDQk11dGFibGVDaGFyYWN0ZXJpc3RpYyEKICAgIHByaXZhdGUgdmFyIGtleTogU3ltbWV0cmljS2V5IQogICAgcHJpdmF0ZSB2YXIgZGV2aWNlTmFtZTogU3RyaW5nID0gIkJMRVVubG9jay1NYWMiCiAgICBwcml2YXRlIHZhciBhZHZlcnRpc2VUaW1lcjogVGltZXI/CiAgICBwcml2YXRlIHZhciBzdGF0dXNWYWx1ZSA9ICJSRUFEWSIKCiAgICBmdW5jIHN0YXJ0KGtleTogU3ltbWV0cmljS2V5LCBkZXZpY2VOYW1lOiBTdHJpbmcpIHsKICAgICAgICBzZWxmLmtleSA9IGtleQogICAgICAgIHNlbGYuZGV2aWNlTmFtZSA9IGRldmljZU5hbWUKICAgICAgICBtYW5hZ2VyID0gQ0JQZXJpcGhlcmFsTWFuYWdlcihkZWxlZ2F0ZTogc2VsZiwgcXVldWU6IG5pbCkKICAgIH0KCiAgICBwcml2YXRlIGZ1bmMgYnVpbGRTZXJ2aWNlKCkgewogICAgICAgIGNvbW1hbmRDaGFyID0gQ0JNdXRhYmxlQ2hhcmFjdGVyaXN0aWModHlwZToga0NoYXJDb21tYW5kVVVJRCwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIHByb3BlcnRpZXM6IFsud3JpdGUsIC53cml0ZVdpdGhvdXRSZXNwb25zZV0sCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB2YWx1ZTogbmlsLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcGVybWlzc2lvbnM6IFsud3JpdGVhYmxlXSkKCiAgICAgICAgLy8g5rOo5oSP77ya5bimIC5ub3RpZnkvLnJlYWQg55qE54m55b6B5LiN6IO96aKE572u57yT5a2Y5YC877yIQ29yZUJsdWV0b290aCDkvJrmipsKICAgICAgICAvLyAiQ2hhcmFjdGVyaXN0aWNzIHdpdGggY2FjaGVkIHZhbHVlcyBtdXN0IGJlIHJlYWQtb25seSLvvInvvIwKICAgICAgICAvLyDlm6DmraTov5nph4wgdmFsdWUg5b+F6aG75pivIG5pbO+8jOivu+WPluaXtuWcqCBkaWRSZWNlaXZlUmVhZCDph4zliqjmgIHov5Tlm57jgIIKICAgICAgICBzdGF0dXNDaGFyID0gQ0JNdXRhYmxlQ2hhcmFjdGVyaXN0aWModHlwZToga0NoYXJTdGF0dXNVVUlELAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwcm9wZXJ0aWVzOiBbLnJlYWQsIC5ub3RpZnldLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB2YWx1ZTogbmlsLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBwZXJtaXNzaW9uczogWy5yZWFkYWJsZV0pCgogICAgICAgIC8vIOWPquivu+S4lOWAvOWbuuWumueahOeJueW+geWPr+S7pemihOe9rue8k+WtmOWAvO+8jOWvueaJi+acuuerr+abtOecgeS4gOasoeS6pOS6kgogICAgICAgIGxldCBpbmZvID0gIkJMRVVubG9ja0NtZCB2MTtcKGRldmljZU5hbWUpIgogICAgICAgIGxldCBpbmZvQ2hhciA9IENCTXV0YWJsZUNoYXJhY3RlcmlzdGljKHR5cGU6IGtDaGFySW5mb1VVSUQsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcHJvcGVydGllczogWy5yZWFkXSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB2YWx1ZTogaW5mby5kYXRhKHVzaW5nOiAudXRmOCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgcGVybWlzc2lvbnM6IFsucmVhZGFibGVdKQoKICAgICAgICBsZXQgc2VydmljZSA9IENCTXV0YWJsZVNlcnZpY2UodHlwZToga1NlcnZpY2VVVUlELCBwcmltYXJ5OiB0cnVlKQogICAgICAgIHNlcnZpY2UuY2hhcmFjdGVyaXN0aWNzID0gW2NvbW1hbmRDaGFyLCBzdGF0dXNDaGFyLCBpbmZvQ2hhcl0KICAgICAgICBtYW5hZ2VyLmFkZChzZXJ2aWNlKQogICAgfQoKICAgIHByaXZhdGUgZnVuYyBzdGFydEFkdmVydGlzaW5nKCkgewogICAgICAgIGd1YXJkIG1hbmFnZXIuc3RhdGUgPT0gLnBvd2VyZWRPbiBlbHNlIHsgcmV0dXJuIH0KICAgICAgICBndWFyZCAhbWFuYWdlci5pc0FkdmVydGlzaW5nIGVsc2UgeyByZXR1cm4gfQogICAgICAgIG1hbmFnZXIuc3RhcnRBZHZlcnRpc2luZyhbCiAgICAgICAgICAgIENCQWR2ZXJ0aXNlbWVudERhdGFTZXJ2aWNlVVVJRHNLZXk6IFtrU2VydmljZVVVSURdLAogICAgICAgICAgICBDQkFkdmVydGlzZW1lbnREYXRhTG9jYWxOYW1lS2V5OiBkZXZpY2VOYW1lLAogICAgICAgIF0pCiAgICB9CgogICAgZnVuYyBzZXRTdGF0dXMoXyB0ZXh0OiBTdHJpbmcpIHsKICAgICAgICBzdGF0dXNWYWx1ZSA9IHRleHQKICAgICAgICAvLyDms6jmhI/vvJrkuI3opoHnu5kgc3RhdHVzQ2hhci52YWx1ZSDotYvlgLzjgILluKYgLm5vdGlmeSDnmoTnibnlvoHkuIDml6booqvotYvkuojnvJPlrZjlgLzvvIwKICAgICAgICAvLyDkuYvlkI4gbWFuYWdlci5hZGQoc2VydmljZSkg5Lya5oqbICJDaGFyYWN0ZXJpc3RpY3Mgd2l0aCBjYWNoZWQgdmFsdWVzIG11c3QgYmUgcmVhZC1vbmx5IuOAggogICAgICAgIC8vIOivu+WPlueUsSBkaWRSZWNlaXZlUmVhZCDliqjmgIHov5Tlm57vvIzmjqjpgIHotbAgdXBkYXRlVmFsdWXjgIIKICAgICAgICBndWFyZCBtYW5hZ2VyLnN0YXRlID09IC5wb3dlcmVkT24sIGxldCBjaGFyYWN0ZXJpc3RpYyA9IHN0YXR1c0NoYXIgZWxzZSB7IHJldHVybiB9CiAgICAgICAgaWYgIW1hbmFnZXIudXBkYXRlVmFsdWUodGV4dC5kYXRhKHVzaW5nOiAudXRmOCkhLCBmb3I6IGNoYXJhY3RlcmlzdGljLCBvblN1YnNjcmliZWRDZW50cmFsczogbmlsKSB7CiAgICAgICAgICAgIC8vIOmYn+WIl+W3sua7oe+8jOetiSBwZXJpcGhlcmFsTWFuYWdlcklzUmVhZHkg5pe26KGl5Y+RCiAgICAgICAgICAgIHBlbmRpbmdTdGF0dXMgPSB0ZXh0CiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXJEaWRVcGRhdGVTdGF0ZShfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIpIHsKICAgICAgICBzd2l0Y2ggcGVyaXBoZXJhbC5zdGF0ZSB7CiAgICAgICAgY2FzZSAucG93ZXJlZE9uOgogICAgICAgICAgICBsb2coIuiTneeJmeW3suWwsee7qu+8jOazqOWGjCBHQVRUIOacjeWKoSIpCiAgICAgICAgICAgIGJ1aWxkU2VydmljZSgpCiAgICAgICAgICAgIHN0YXJ0QWR2ZXJ0aXNpbmcoKQogICAgICAgICAgICAvLyDlrprmnJ/ph43mlrDlub/mkq3vvIzpgb/lhY3plIHlsY8v57O757uf5LyR55yg5ZCO5bm/5pKt6KKr5YGc5o6JCiAgICAgICAgICAgIGFkdmVydGlzZVRpbWVyPy5pbnZhbGlkYXRlKCkKICAgICAgICAgICAgYWR2ZXJ0aXNlVGltZXIgPSBUaW1lci5zY2hlZHVsZWRUaW1lcih3aXRoVGltZUludGVydmFsOiAyMCwgcmVwZWF0czogdHJ1ZSkgeyBbd2VhayBzZWxmXSBfIGluCiAgICAgICAgICAgICAgICBzZWxmPy5zdGFydEFkdmVydGlzaW5nKCkKICAgICAgICAgICAgfQogICAgICAgICAgICBSdW5Mb29wLm1haW4uYWRkKGFkdmVydGlzZVRpbWVyISwgZm9yTW9kZTogLmNvbW1vbikKICAgICAgICAgICAgc2V0U3RhdHVzKCJSRUFEWSIpCiAgICAgICAgY2FzZSAucG93ZXJlZE9mZjoKICAgICAgICAgICAgbG9nKCLok53niZnlt7LlhbPpl63vvIznrYnlvoXph43mlrDlvIDlkK8iKQogICAgICAgIGNhc2UgLnVuYXV0aG9yaXplZDoKICAgICAgICAgICAgbG9nKCLok53niZnmnYPpmZDooqvmi5Lnu53vvIzor7flnKjjgIzns7vnu5/orr7nva4g4oaSIOmakOengeS4juWuieWFqOaApyDihpIg6JOd54mZ44CN5Lit5o6I5p2DIikKICAgICAgICBkZWZhdWx0OgogICAgICAgICAgICBicmVhawogICAgICAgIH0KICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyRGlkU3RhcnRBZHZlcnRpc2luZyhfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsIGVycm9yOiBFcnJvcj8pIHsKICAgICAgICBpZiBsZXQgZXJyb3IgPSBlcnJvciB7CiAgICAgICAgICAgIGxvZygi5bm/5pKt5aSx6LSlOiBcKGVycm9yLmxvY2FsaXplZERlc2NyaXB0aW9uKSIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgbG9nKCLmraPlnKjlub/mkq3vvIznrYnlvoXmiYvmnLrov57mjqXvvIjorr7lpIflkI0gXChkZXZpY2VOYW1lKe+8iSIpCiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXIoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLCBkaWRBZGQgc2VydmljZTogQ0JTZXJ2aWNlLCBlcnJvcjogRXJyb3I/KSB7CiAgICAgICAgaWYgbGV0IGVycm9yID0gZXJyb3IgewogICAgICAgICAgICBsb2coIua3u+WKoOacjeWKoeWksei0pTogXChlcnJvci5sb2NhbGl6ZWREZXNjcmlwdGlvbikiKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGxvZygiR0FUVCDmnI3liqHlt7LlsLHnu6rvvIhTZXJ2aWNlIFwoa1NlcnZpY2VVVUlELnV1aWRTdHJpbmcp77yJIikKICAgICAgICB9CiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsIGNlbnRyYWw6IENCQ2VudHJhbCwgZGlkU3Vic2NyaWJlVG8gY2hhcmFjdGVyaXN0aWM6IENCQ2hhcmFjdGVyaXN0aWMpIHsKICAgICAgICBsb2coIuaJi+acuuW3suiuoumYheeKtuaAgeeJueW+gTogXChjZW50cmFsLmlkZW50aWZpZXIudXVpZFN0cmluZykiKQogICAgICAgIHNldFN0YXR1cygiQ09OTkVDVEVEIikKICAgIH0KCiAgICBmdW5jIHBlcmlwaGVyYWxNYW5hZ2VyKF8gcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlciwgY2VudHJhbDogQ0JDZW50cmFsLCBkaWRVbnN1YnNjcmliZUZyb20gY2hhcmFjdGVyaXN0aWM6IENCQ2hhcmFjdGVyaXN0aWMpIHsKICAgICAgICBsb2coIuaJi+acuuWPlua2iOiuoumYheeKtuaAgeeJueW+gSIpCiAgICB9CgogICAgcHJpdmF0ZSB2YXIgcGVuZGluZ1N0YXR1czogU3RyaW5nPwoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXJJc1JlYWR5KHRvVXBkYXRlU3Vic2NyaWJlcnMgcGVyaXBoZXJhbDogQ0JQZXJpcGhlcmFsTWFuYWdlcikgewogICAgICAgIC8vIOS4iuS4gOasoSB1cGRhdGVWYWx1ZSDlm6Dlj5HpgIHpmJ/liJfmu6HogIzlpLHotKXvvIzov5nph4zooaXlj5EKICAgICAgICBndWFyZCBsZXQgdGV4dCA9IHBlbmRpbmdTdGF0dXMsIG1hbmFnZXIuc3RhdGUgPT0gLnBvd2VyZWRPbiwgbGV0IGNoYXJhY3RlcmlzdGljID0gc3RhdHVzQ2hhciBlbHNlIHsgcmV0dXJuIH0KICAgICAgICBwZW5kaW5nU3RhdHVzID0gbmlsCiAgICAgICAgbWFuYWdlci51cGRhdGVWYWx1ZSh0ZXh0LmRhdGEodXNpbmc6IC51dGY4KSEsIGZvcjogY2hhcmFjdGVyaXN0aWMsIG9uU3Vic2NyaWJlZENlbnRyYWxzOiBuaWwpCiAgICB9CgogICAgZnVuYyBwZXJpcGhlcmFsTWFuYWdlcihfIHBlcmlwaGVyYWw6IENCUGVyaXBoZXJhbE1hbmFnZXIsCiAgICAgICAgICAgICAgICAgICAgICAgICAgIGRpZFJlY2VpdmVXcml0ZSByZXF1ZXN0czogW0NCQVRUUmVxdWVzdF0pIHsKICAgICAgICBmb3IgcmVxdWVzdCBpbiByZXF1ZXN0cyB7CiAgICAgICAgICAgIGd1YXJkIHJlcXVlc3QuY2hhcmFjdGVyaXN0aWMudXVpZCA9PSBrQ2hhckNvbW1hbmRVVUlEIGVsc2UgeyBjb250aW51ZSB9CiAgICAgICAgICAgIGxldCBkYXRhID0gcmVxdWVzdC52YWx1ZSA/PyBEYXRhKCkKICAgICAgICAgICAgbG9nKCLmlLbliLDlhpnlhaUgXChkYXRhLmNvdW50KSDlrZfoioIiKQoKICAgICAgICAgICAgLy8g5peg6K665qCh6aqM57uT5p6c5aaC5L2V6YO96KaB5bqU562U77yb5bim5bqU562U5YaZ5LiN5Zue5Lya6K6p5omL5py656uv5Y2h5L2PCiAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLnN1Y2Nlc3MpCgogICAgICAgICAgICBsZXQgcmVzdWx0ID0gdmVyaWZ5UGFja2V0KGRhdGEsIGtleToga2V5KQogICAgICAgICAgICBzd2l0Y2ggcmVzdWx0IHsKICAgICAgICAgICAgY2FzZSAuZmFpbGVkKGxldCByZWFzb24pOgogICAgICAgICAgICAgICAgbG9nKCLmoKHpqozlpLHotKU6IFwocmVhc29uKSIpCiAgICAgICAgICAgICAgICBzZXRTdGF0dXMocmVhc29uKQoKICAgICAgICAgICAgY2FzZSAub2sobGV0IGNvbW1hbmQpOgogICAgICAgICAgICAgICAgc3dpdGNoIGNvbW1hbmQgewogICAgICAgICAgICAgICAgY2FzZSBrQ21kVW5sb2NrOgogICAgICAgICAgICAgICAgICAgIHNldFN0YXR1cygiVU5MT0NLSU5HIikKICAgICAgICAgICAgICAgICAgICBwZXJmb3JtVW5sb2NrIHsgc3RhdHVzIGluCiAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuc2V0U3RhdHVzKHN0YXR1cykKICAgICAgICAgICAgICAgICAgICAgICAgbG9nKCLop6PplIHnu5Pmnpw6IFwoc3RhdHVzKSIpCiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgY2FzZSBrQ21kTG9jazoKICAgICAgICAgICAgICAgICAgICBzZXRTdGF0dXMoIkxPQ0tJTkciKQogICAgICAgICAgICAgICAgICAgIHBlcmZvcm1Mb2NrIHsgc3RhdHVzIGluCiAgICAgICAgICAgICAgICAgICAgICAgIHNlbGYuc2V0U3RhdHVzKHN0YXR1cykKICAgICAgICAgICAgICAgICAgICAgICAgbG9nKCLplIHlrprnu5Pmnpw6IFwoc3RhdHVzKSIpCiAgICAgICAgICAgICAgICAgICAgfQogICAgICAgICAgICAgICAgY2FzZSBrQ21kUGluZzoKICAgICAgICAgICAgICAgICAgICBsb2coIuaUtuWIsCBQSU5HIikKICAgICAgICAgICAgICAgICAgICBzZXRTdGF0dXMoIlBPTkciKQogICAgICAgICAgICAgICAgZGVmYXVsdDoKICAgICAgICAgICAgICAgICAgICBsb2coIuacquefpeaMh+S7pCAweFwoU3RyaW5nKGNvbW1hbmQsIHJhZGl4OiAxNikpIikKICAgICAgICAgICAgICAgICAgICBzZXRTdGF0dXMoIkVSUl9DTUQiKQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgfQoKICAgIGZ1bmMgcGVyaXBoZXJhbE1hbmFnZXIoXyBwZXJpcGhlcmFsOiBDQlBlcmlwaGVyYWxNYW5hZ2VyLAogICAgICAgICAgICAgICAgICAgICAgICAgICBkaWRSZWNlaXZlUmVhZCByZXF1ZXN0OiBDQkFUVFJlcXVlc3QpIHsKICAgICAgICBpZiByZXF1ZXN0LmNoYXJhY3RlcmlzdGljLnV1aWQgPT0ga0NoYXJTdGF0dXNVVUlEIHsKICAgICAgICAgICAgbGV0IGRhdGEgPSBzdGF0dXNWYWx1ZS5kYXRhKHVzaW5nOiAudXRmOCkhCiAgICAgICAgICAgIGlmIHJlcXVlc3Qub2Zmc2V0ID4gZGF0YS5jb3VudCB7CiAgICAgICAgICAgICAgICBwZXJpcGhlcmFsLnJlc3BvbmQodG86IHJlcXVlc3QsIHdpdGhSZXN1bHQ6IC5pbnZhbGlkT2Zmc2V0KQogICAgICAgICAgICAgICAgcmV0dXJuCiAgICAgICAgICAgIH0KICAgICAgICAgICAgcmVxdWVzdC52YWx1ZSA9IGRhdGEuc3ViZGF0YShpbjogcmVxdWVzdC5vZmZzZXQuLjxkYXRhLmNvdW50KQogICAgICAgICAgICBwZXJpcGhlcmFsLnJlc3BvbmQodG86IHJlcXVlc3QsIHdpdGhSZXN1bHQ6IC5zdWNjZXNzKQogICAgICAgIH0gZWxzZSBpZiByZXF1ZXN0LmNoYXJhY3RlcmlzdGljLnV1aWQgPT0ga0NoYXJJbmZvVVVJRCB7CiAgICAgICAgICAgIGxldCBkYXRhID0gIkJMRVVubG9ja0NtZCB2MTtcKGRldmljZU5hbWUpIi5kYXRhKHVzaW5nOiAudXRmOCkhCiAgICAgICAgICAgIHJlcXVlc3QudmFsdWUgPSBkYXRhCiAgICAgICAgICAgIHBlcmlwaGVyYWwucmVzcG9uZCh0bzogcmVxdWVzdCwgd2l0aFJlc3VsdDogLnN1Y2Nlc3MpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgcGVyaXBoZXJhbC5yZXNwb25kKHRvOiByZXF1ZXN0LCB3aXRoUmVzdWx0OiAuYXR0cmlidXRlTm90Rm91bmQpCiAgICAgICAgfQogICAgfQp9CgovLyBNQVJLOiAtIOWFpeWPowoKZnVuYyBwcmludFVzYWdlKCkgewogICAgcHJpbnQoIiIiCiAgICBCTEVVbmxvY2tDbWQg4oCUIOeUqOaJi+acuumAmui/h+iTneeJmeino+mUgei/meWPsCBNYWMKCiAgICDnlKjms5U6IEJMRVVubG9ja0NtZCBb6YCJ6aG5XQoKICAgICAgLS1wcmludC10b2tlbiAgICAgICAg5omT5Y2w6YWN5a+55Luk54mM77yI5Zyo5omL5py6IEFwcCDkuK3loavlhpnov5nkuKrlgLzvvIkKICAgICAgLS1zZXQta2V5IDxiYXNlNjQ+ICAg5YaZ5YWl5oyH5a6a55qE6YWN5a+55a+G6ZKlCiAgICAgIC0tZGV2aWNlLW5hbWUgPOWQjT4gICDlub/mkq3nmoTorr7lpIflkI0KICAgICAgLS1hZGQtYWNjZXNzaWJpbGl0eSAg5omT5byA44CM6L6F5Yqp5Yqf6IO944CN5o6I5p2D5o+Q56S6CiAgICAgIC0tY2hlY2sgICAgICAgICAgICAgIOiHquajgO+8muaJk+WNsOadg+mZkOOAgemSpeWMmeS4suS4jumFjee9rueKtuaAgQogICAgICAtLWRyeS1ydW4gICAgICAgICAgICDlronlhajmtYvor5XmqKHlvI/vvJrotbDlrowgQkxFIOaUtuWMheS4juagoemqjO+8jOS9huS4jeecn+eahOino+mUgQogICAgICAtLXNob3ctdG9rZW4gICAgICAgICDmiZPljbDphY3lr7nku6TniYzvvIjmnKrlronoo4Xml7boh6rliqjnlJ/miJDkuIDkuKrkuLTml7blr4bpkqXvvIkKICAgICAgLS1zZWxmdGVzdCA8aGV4PiAgICAg5Y2P6K6u6Ieq5qOA77ya5a+557uZ5a6a55qE5Y2B5YWt6L+b5Yi25raI5oGv6L6T5Ye6IEhNQUMtU0hBMjU2CiAgICAgIC0tdmVyc2lvbiAgICAgICAgICAgIOaYvuekuueJiOacrAogICAgIiIiKQp9CgplbnN1cmVTdXBwb3J0RGlyZWN0b3J5KCkKCmxldCBhcmdzID0gQXJyYXkoQ29tbWFuZExpbmUuYXJndW1lbnRzLmRyb3BGaXJzdCgpKQoKaWYgYXJncy5jb250YWlucygiLS12ZXJzaW9uIikgewogICAgcHJpbnQoIkJMRVVubG9ja0NtZCAxLjAuMCIpCiAgICBleGl0KDApCn0KCi8vIOWNj+iurumXreeOr+iHquajgO+8muS4jeS+nei1luiTneeJme+8jOebtOaOpei1sCLmlLbljIUgLT4g5qCh6aqMIC0+IOaJp+ihjCLlhajmtYHnqIsKaWYgYXJncy5jb250YWlucygiLS1zZWxmdGVzdC1wcm90b2NvbCIpIHsKICAgIGRyeVJ1biA9IHRydWUKICAgIHZhciBmYWlsZWQgPSAwCgogICAgZnVuYyBleHBlY3QoXyBsYWJlbDogU3RyaW5nLCBfIG9rOiBCb29sLCBfIGRldGFpbDogU3RyaW5nID0gIiIpIHsKICAgICAgICBpZiBvayB7CiAgICAgICAgICAgIHByaW50KCIgIOKckyBcKGxhYmVsKSIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgcHJpbnQoIiAg4pyXIFwobGFiZWwpICBcKGRldGFpbCkiKQogICAgICAgICAgICBmYWlsZWQgKz0gMQogICAgICAgIH0KICAgIH0KCiAgICAvLyDnlKjkuLTml7blr4bpkqXmnoTpgKDmtYvor5XljIUKICAgIHZhciBrZXlCeXRlcyA9IFtVSW50OF0ocmVwZWF0aW5nOiAwLCBjb3VudDogMzIpCiAgICBmb3IgaSBpbiAwLi48MzIgeyBrZXlCeXRlc1tpXSA9IFVJbnQ4KGkpIH0KICAgIGxldCB0ZXN0S2V5ID0gU3ltbWV0cmljS2V5KGRhdGE6IERhdGEoa2V5Qnl0ZXMpKQoKICAgIGZ1bmMgbWFrZVBhY2tldChjb21tYW5kOiBVSW50OCwgdGltZXN0YW1wOiBJbnQ2NCA9IEludDY0KERhdGUoKS50aW1lSW50ZXJ2YWxTaW5jZTE5NzApLAogICAgICAgICAgICAgICAgICAgIG5vbmNlOiBEYXRhPyA9IG5pbCwgdGFtcGVyOiBCb29sID0gZmFsc2UpIC0+IERhdGEgewogICAgICAgIHZhciBtZXNzYWdlID0gRGF0YShbMHg0MiwgMHg1NSwgMHgwMSwgY29tbWFuZF0pCiAgICAgICAgdmFyIHRzID0gVUludDY0KGJpdFBhdHRlcm46IHRpbWVzdGFtcCkuYmlnRW5kaWFuCiAgICAgICAgd2l0aFVuc2FmZUJ5dGVzKG9mOiAmdHMpIHsgbWVzc2FnZS5hcHBlbmQoY29udGVudHNPZjogJDApIH0KICAgICAgICB2YXIgbiA9IG5vbmNlID8/IERhdGEoKDAuLjwxNikubWFwIHsgXyBpbiBVSW50OC5yYW5kb20oaW46IDAuLi4yNTUpIH0pCiAgICAgICAgaWYgbi5jb3VudCAhPSAxNiB7IG4gPSBEYXRhKHJlcGVhdGluZzogMCwgY291bnQ6IDE2KSB9CiAgICAgICAgbWVzc2FnZS5hcHBlbmQobikKICAgICAgICBtZXNzYWdlLmFwcGVuZChjb250ZW50c09mOiBbMHgwMCwgMHgwMF0pCiAgICAgICAgdmFyIHRhZyA9IERhdGEoSE1BQzxTSEEyNTY+LmF1dGhlbnRpY2F0aW9uQ29kZShmb3I6IG1lc3NhZ2UsIHVzaW5nOiB0ZXN0S2V5KSkKICAgICAgICBpZiB0YW1wZXIgeyB0YWdbMF0gXj0gMHhGRiB9CiAgICAgICAgcmV0dXJuIG1lc3NhZ2UgKyB0YWcKICAgIH0KCiAgICBwcmludCgiPT0g5oql5paH5qCh6aqMID09IikKCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jayksIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2sobGV0IGMpOiBleHBlY3QoIuWQiOazleino+mUgeWMhemAmui/h+agoemqjCIsIGMgPT0ga0NtZFVubG9jaywgIuWRveS7pD1cKGMpIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi5ZCI5rOV6Kej6ZSB5YyF6YCa6L+H5qCh6aqMIiwgZmFsc2UsIHIpCiAgICB9CgogICAgc3dpdGNoIHZlcmlmeVBhY2tldChtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRQaW5nKSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vayhsZXQgYyk6IGV4cGVjdCgiUElORyDljIXpgJrov4fmoKHpqowiLCBjID09IGtDbWRQaW5nLCAi5ZG95LukPVwoYykiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCJQSU5HIOWMhemAmui/h+agoemqjCIsIGZhbHNlLCByKQogICAgfQoKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrLCB0YW1wZXI6IHRydWUpLCBrZXk6IHRlc3RLZXkpIHsKICAgIGNhc2UgLm9rOiBleHBlY3QoIuevoeaUueeahCBITUFDIOW/hemhu+iiq+aLkue7nSIsIGZhbHNlLCAi5bGF54S26YCa6L+H5LqGIikKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi56+h5pS555qEIEhNQUMg6KKr5ouS57udIiwgciA9PSAiRVJSX0hNQUMiLCByKQogICAgfQoKICAgIGxldCB3cm9uZ0tleSA9IFN5bW1ldHJpY0tleShkYXRhOiBEYXRhKHJlcGVhdGluZzogMHhBQiwgY291bnQ6IDMyKSkKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQobWFrZVBhY2tldChjb21tYW5kOiBrQ21kVW5sb2NrKSwga2V5OiB3cm9uZ0tleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi6ZSZ6K+v5a+G6ZKl5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLplJnor6/lr4bpkqXooqvmi5Lnu50iLCByID09ICJFUlJfSE1BQyIsIHIpCiAgICB9CgogICAgc3dpdGNoIHZlcmlmeVBhY2tldChEYXRhKFsweDQyLCAweDU1LCAweDAxXSksIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi6L+H55+t55qE5YyF5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLov4fnn63nmoTljIXooqvmi5Lnu50iLCByID09ICJFUlJfTEVOIiwgcikKICAgIH0KCiAgICB2YXIgYmFkTWFnaWMgPSBtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2spCiAgICBiYWRNYWdpY1swXSA9IDB4MDAKICAgIHN3aXRjaCB2ZXJpZnlQYWNrZXQoYmFkTWFnaWMsIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi6ZSZ6K+v6a2U5pWw5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLplJnor6/prZTmlbDooqvmi5Lnu50iLCByID09ICJFUlJfTUFHSUMiLCByKQogICAgfQoKICAgIGxldCBzdGFsZSA9IEludDY0KERhdGUoKS50aW1lSW50ZXJ2YWxTaW5jZTE5NzApIC0gNjAwCiAgICBzd2l0Y2ggdmVyaWZ5UGFja2V0KG1ha2VQYWNrZXQoY29tbWFuZDoga0NtZFVubG9jaywgdGltZXN0YW1wOiBzdGFsZSksIGtleTogdGVzdEtleSkgewogICAgY2FzZSAub2s6IGV4cGVjdCgi6L+H5pyf5pe26Ze05oiz5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLov4fmnJ/ml7bpl7TmiLPooqvmi5Lnu50iLCByID09ICJFUlJfVElNRSIsIHIpCiAgICB9CgogICAgcHJpbnQoKQogICAgcHJpbnQoIj09IOmYsumHjeaUviA9PSIpCiAgICBsZXQgZml4ZWROb25jZSA9IERhdGEocmVwZWF0aW5nOiAweDVBLCBjb3VudDogMTYpCiAgICBsZXQgcDEgPSBtYWtlUGFja2V0KGNvbW1hbmQ6IGtDbWRVbmxvY2ssIG5vbmNlOiBmaXhlZE5vbmNlKQogICAgc3dpdGNoIHZlcmlmeVBhY2tldChwMSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLlkIzkuIAgbm9uY2Ug6aaW5qyh6YCa6L+HIiwgdHJ1ZSkKICAgIGNhc2UgLmZhaWxlZChsZXQgcik6IGV4cGVjdCgi5ZCM5LiAIG5vbmNlIOmmluasoemAmui/hyIsIGZhbHNlLCByKQogICAgfQogICAgc3dpdGNoIHZlcmlmeVBhY2tldChwMSwga2V5OiB0ZXN0S2V5KSB7CiAgICBjYXNlIC5vazogZXhwZWN0KCLlkIzkuIAgbm9uY2Ug6YeN5pS+5b+F6aG76KKr5ouS57udIiwgZmFsc2UsICLlsYXnhLbpgJrov4fkuoYiKQogICAgY2FzZSAuZmFpbGVkKGxldCByKTogZXhwZWN0KCLlkIzkuIAgbm9uY2Ug6YeN5pS+6KKr5ouS57udIiwgciA9PSAiRVJSX1JFUExBWSIsIHIpCiAgICB9CgogICAgcHJpbnQoKQogICAgcHJpbnQoIj09IOino+mUgea1geeoi++8iGRyeS1ydW7vvIzkuI3kvJrnnJ/nmoTms6jlhaXlr4bnoIHvvIk9PSIpCiAgICAvLyDpgKDkuIDkuKrkuLTml7bphY3nva7vvIzmjIflkJHkuIDkuKrkuI3lrZjlnKjnmoTpkqXljJnkuLLotKbmiLfvvIzpooTmnJ/lvpfliLAgRVJSX05PX1BXCiAgICBsZXQgdGVtcENvbmZpZyA9IENvbmZpZyhobWFjS2V5OiBEYXRhKGtleUJ5dGVzKS5iYXNlNjRFbmNvZGVkU3RyaW5nKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXljaGFpbkFjY291bnQ6ICJfX2JsZXVubG9ja19zZWxmdGVzdF9ub25leGlzdGVudF9fIiwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGRldmljZU5hbWU6ICJTRUxGVEVTVCIpCiAgICBsZXQgZW5jID0gSlNPTkVuY29kZXIoKQogICAgZW5jLm91dHB1dEZvcm1hdHRpbmcgPSBbLnByZXR0eVByaW50ZWQsIC5zb3J0ZWRLZXlzXQogICAgdHJ5PyBlbmMuZW5jb2RlKHRlbXBDb25maWcpLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrQ29uZmlnUGF0aCkpCgogICAgdmFyIHVubG9ja1Jlc3VsdCA9ICIiCiAgICBsZXQgc2VtID0gRGlzcGF0Y2hTZW1hcGhvcmUodmFsdWU6IDApCiAgICBwZXJmb3JtVW5sb2NrIHsgc3RhdHVzIGluCiAgICAgICAgdW5sb2NrUmVzdWx0ID0gc3RhdHVzCiAgICAgICAgc2VtLnNpZ25hbCgpCiAgICB9CiAgICBfID0gc2VtLndhaXQodGltZW91dDogLm5vdygpICsgMjApCiAgICBleHBlY3QoIue8uuWwkemSpeWMmeS4suWvhueggeaXtui/lOWbniBFUlJfTk9fUFciLCB1bmxvY2tSZXN1bHQgPT0gIkVSUl9OT19QVyIsICLlrp7pmYUgXCh1bmxvY2tSZXN1bHQpIikKCiAgICAvLyDlpJrlr4bnoIHvvJpkcnktcnVuIOW6lOiDveivhuWIq+WHuuWFqOmDqOWvhueggeW5tumAkOS4quWwneivlQogICAgbGV0IHRlc3RBY2NvdW50ID0gIl9fYmxldW5sb2NrX3NlbGZ0ZXN0X211bHRpX18iCiAgICBzdG9yZVBhc3N3b3JkcyhbInNlbGZ0ZXN0LXB3LTEiLCAic2VsZnRlc3QtcHctMiIsICJzZWxmdGVzdC1wdy0zIl0sIGFjY291bnQ6IHRlc3RBY2NvdW50KQogICAgbGV0IHJlYWRCYWNrID0gZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBleHBlY3QoIuWkmuWvhueggeWPr+WGmeWFpeW5tuivu+WbniAzIOS4qiIsIHJlYWRCYWNrLmNvdW50ID09IDMsICLlrp7pmYUgXChyZWFkQmFjay5jb3VudCkiKQogICAgZXhwZWN0KCLpobrluo/kv53mjIEiLCByZWFkQmFjay5maXJzdCA9PSAic2VsZnRlc3QtcHctMSIgJiYgcmVhZEJhY2subGFzdCA9PSAic2VsZnRlc3QtcHctMyIsCiAgICAgICAgICAgIuWunumZhSBcKHJlYWRCYWNrKSIpCgogICAgbGV0IG11bHRpQ29uZmlnID0gQ29uZmlnKGhtYWNLZXk6IERhdGEoa2V5Qnl0ZXMpLmJhc2U2NEVuY29kZWRTdHJpbmcoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXljaGFpbkFjY291bnQ6IHRlc3RBY2NvdW50LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgIGRldmljZU5hbWU6ICJTRUxGVEVTVCIpCiAgICB0cnk/IGVuYy5lbmNvZGUobXVsdGlDb25maWcpLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrQ29uZmlnUGF0aCkpCgogICAgdmFyIG11bHRpUmVzdWx0ID0gIiIKICAgIGxldCBzZW0yID0gRGlzcGF0Y2hTZW1hcGhvcmUodmFsdWU6IDApCiAgICBwZXJmb3JtVW5sb2NrIHsgc3RhdHVzIGluCiAgICAgICAgbXVsdGlSZXN1bHQgPSBzdGF0dXMKICAgICAgICBzZW0yLnNpZ25hbCgpCiAgICB9CiAgICBfID0gc2VtMi53YWl0KHRpbWVvdXQ6IC5ub3coKSArIDIwKQogICAgZXhwZWN0KCLlpJrlr4bnoIEgZHJ5LXJ1biDov5Tlm54gT0siLCBtdWx0aVJlc3VsdCA9PSAiT0siLCAi5a6e6ZmFIFwobXVsdGlSZXN1bHQpIikKCiAgICAvLyDnibnmrorlrZfnrKblv4Xpobvog73ljp/moLflvoDov5TvvIjlvJXlj7fjgIHlj43mlpzmnaDjgIHnqbrmoLzjgIHkuK3mlofjgIEk44CB5Y+N5byV5Y+377yJCiAgICAvLyDov5nnsbvlrZfnrKblnKggc2hlbGwg566h6YGT6YeM5a655piT6KKr5ZCD5o6J77yM5omA5Lul5b+F6aG75Zyo5Luj56CB6Lev5b6E5LiK6aqM6K+B44CCCiAgICBsZXQgdHJpY2t5ID0gWyJwQHNzIHcwcmQiLCAid2l0aFwicXVvdGUiLCAid2l0aFxcYmFja3NsYXNoIiwgIuS4reaWh+WvhueggSIsCiAgICAgICAgICAgICAgICAgICIkZG9sbGFyYHRpY2siLCAidGFiXHRoZXJlIl0KICAgIHN0b3JlUGFzc3dvcmRzKHRyaWNreSwgYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBsZXQgdHJpY2t5QmFjayA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IHRlc3RBY2NvdW50KQogICAgZXhwZWN0KCLnibnmrorlrZfnrKbmlbDph4/mraPnoa4iLCB0cmlja3lCYWNrLmNvdW50ID09IHRyaWNreS5jb3VudCwKICAgICAgICAgICAi5YaZ5YWlIFwodHJpY2t5LmNvdW50KSDor7vlm54gXCh0cmlja3lCYWNrLmNvdW50KSIpCiAgICBleHBlY3QoIueJueauiuWtl+espuWGheWuueWOn+agtyIsIHRyaWNreUJhY2sgPT0gdHJpY2t5LCAi5a6e6ZmFIFwodHJpY2t5QmFjaykiKQoKICAgIC8vIOepuuWvhueggeW6lOiiq+i/h+a7pOaOie+8jOS4jeiDveS6p+eUn+S4gOadoeepuuadoeebrgogICAgc3RvcmVQYXNzd29yZHMoWyJrZWVwLW1lIiwgIiIsICIgICJdLCBhY2NvdW50OiB0ZXN0QWNjb3VudCkKICAgIGxldCBmaWx0ZXJlZCA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IHRlc3RBY2NvdW50KQogICAgZXhwZWN0KCLnqbrlr4bnoIHooqvov4fmu6TvvIjku4Xov4fmu6TnqbrkuLLvvIkiLAogICAgICAgICAgIGZpbHRlcmVkLmZpcnN0ID09ICJrZWVwLW1lIiAmJiAhZmlsdGVyZWQuY29udGFpbnMoIiIpLAogICAgICAgICAgICLlrp7pmYUgXChmaWx0ZXJlZC5jb3VudCkg5Liq77yaXChmaWx0ZXJlZCkiKQoKICAgIC8vIOaXp+agvOW8j+WFvOWuue+8mumSpeWMmeS4sumHjOebtOaOpeaUvuaYjuaWhwogICAgXyA9IHdyaXRlS2V5Y2hhaW5QYXNzd29yZCgibGVnYWN5LXBsYWluIiwgYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBsZXQgbGVnYWN5ID0gZmV0Y2hQYXNzd29yZHMoYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBleHBlY3QoIuaXp+agvOW8j+WNleWvhueggeWPr+ivhuWIqyIsIGxlZ2FjeSA9PSBbImxlZ2FjeS1wbGFpbiJdLCAi5a6e6ZmFIFwobGVnYWN5KSIpCgogICAgLy8g5riF56m65ZCO5bqU5Li656m65YiX6KGo77yI5LiN6IO95oqKIEpTT04g5paH5pysICJbXSIg5b2T5a+G56CB77yJCiAgICBzdG9yZVBhc3N3b3JkcyhbXSwgYWNjb3VudDogdGVzdEFjY291bnQpCiAgICBsZXQgZW1wdGllZCA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IHRlc3RBY2NvdW50KQogICAgZXhwZWN0KCLmuIXnqbrlkI7kuLrnqbrliJfooagiLCBlbXB0aWVkLmlzRW1wdHksICLlrp7pmYUgXChlbXB0aWVkLmNvdW50KSDkuKrvvJpcKGVtcHRpZWQpIikKCiAgICAvLyDmuIXnkIbmtYvor5XmnaHnm64KICAgIF8gPSBydW5Qcm9jZXNzKCIvdXNyL2Jpbi9zZWN1cml0eSIsCiAgICAgICAgICAgICAgICAgICBbImRlbGV0ZS1nZW5lcmljLXBhc3N3b3JkIiwgIi1hIiwgdGVzdEFjY291bnQsICItcyIsIGtLZXljaGFpblNlcnZpY2VdKQoKICAgIHByaW50KCkKICAgIGlmIGZhaWxlZCA9PSAwIHsKICAgICAgICBwcmludCgi57uT5p6cOiDlhajpg6jpgJrov4cg4pyTIikKICAgICAgICBleGl0KDApCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLnu5Pmnpw6IFwoZmFpbGVkKSDpobnlpLHotKUg4pyXIikKICAgICAgICBleGl0KDEpCiAgICB9Cn0KCi8vIOWNj+iuruiHquajgO+8mueUqOWbuuWumua1i+ivleWvhumSpeWvuee7meWumueahOWNgeWFrei/m+WItua2iOaBr+iuoeeulyBITUFD77yM5L6b6Leo6K+t6KiA5q+U5a+55L2/55SoCmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLXNlbGZ0ZXN0IiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIGxldCBoZXhTdHJpbmcgPSBhcmdzW2lkeCArIDFdCiAgICB2YXIgbWVzc2FnZSA9IERhdGEoKQogICAgdmFyIGkgPSBoZXhTdHJpbmcuc3RhcnRJbmRleAogICAgd2hpbGUgaSA8IGhleFN0cmluZy5lbmRJbmRleCB7CiAgICAgICAgZ3VhcmQgbGV0IG5leHQgPSBoZXhTdHJpbmcuaW5kZXgoaSwgb2Zmc2V0Qnk6IDIsIGxpbWl0ZWRCeTogaGV4U3RyaW5nLmVuZEluZGV4KSBlbHNlIHsgYnJlYWsgfQogICAgICAgIGxldCBieXRlU3RyaW5nID0gaGV4U3RyaW5nW2kuLjxuZXh0XQogICAgICAgIGd1YXJkIGxldCBieXRlID0gVUludDgoYnl0ZVN0cmluZywgcmFkaXg6IDE2KSBlbHNlIHsKICAgICAgICAgICAgRmlsZUhhbmRsZS5zdGFuZGFyZEVycm9yLndyaXRlKCLml6DmlYjnmoTljYHlha3ov5vliLbovpPlhaVcbiIuZGF0YSh1c2luZzogLnV0ZjgpISkKICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBtZXNzYWdlLmFwcGVuZChieXRlKQogICAgICAgIGkgPSBuZXh0CiAgICB9CiAgICAvLyDkuI4gQW5kcm9pZCDnq68gVmVyaWZ5UHJvdG9jb2wuamF2YSDkvb/nlKjlrozlhajnm7jlkIznmoTmtYvor5Xlr4bpkqXvvJoweDAwLDB4MDEsLi4uLDB4MWYKICAgIHZhciBrZXlCeXRlcyA9IFtVSW50OF0oKQogICAgZm9yIG4gaW4gMC4uPDMyIHsga2V5Qnl0ZXMuYXBwZW5kKFVJbnQ4KG4pKSB9CiAgICBsZXQgdGVzdEtleSA9IFN5bW1ldHJpY0tleShkYXRhOiBEYXRhKGtleUJ5dGVzKSkKICAgIGxldCB0YWcgPSBEYXRhKEhNQUM8U0hBMjU2Pi5hdXRoZW50aWNhdGlvbkNvZGUoZm9yOiBtZXNzYWdlLCB1c2luZzogdGVzdEtleSkpCiAgICBwcmludCh0YWcubWFwIHsgU3RyaW5nKGZvcm1hdDogIiUwMngiLCAkMCkgfS5qb2luZWQoKSkKICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1wcmludC10b2tlbiIpIHsKICAgIGd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICAgICAgcHJpbnQoIuWwmuacquWIneWni+WMlumFjee9ru+8jOivt+WFiOi/kOihjOWuieijheiEmuacrOOAgiIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgcHJpbnQoY29uZmlnLmhtYWNLZXkpCiAgICBleGl0KDApCn0KCmlmIGFyZ3MuY29udGFpbnMoIi0tYWRkLWFjY2Vzc2liaWxpdHkiKSB7CiAgICBsZXQgb2sgPSBhY2Nlc3NpYmlsaXR5R3JhbnRlZChwcm9tcHQ6IHRydWUpCiAgICBwcmludChvayA/ICLlt7LojrflvpfovoXliqnlip/og73mnYPpmZDjgIIiIDogIuW3suW8ueWHuuaOiOadg+ivt+axgu+8jOivt+WcqOOAjOezu+e7n+iuvue9riDihpIg6ZqQ56eB5LiO5a6J5YWo5oCnIOKGkiDovoXliqnlip/og73jgI3kuK3li77pgIkgQkxFVW5sb2NrQ21k44CCIikKICAgIGV4aXQoMCkKfQoKLy8g55Sx5a6I5oqk6L+b56iL6Ieq5bex5Y+R6LW344CM6L6F5Yqp5Yqf6IO944CN5o6I5p2D6K+35rGC44CCCi8vIOeUqCBwcm9tcHQ6dHJ1ZSDorqnns7vnu5/lvLnlh7rmjojmnYPlvJXlr7zlubbmiororrDlvZXnu5HlrprliLDmnKzkuozov5vliLbjgIIKaWYgYXJncy5jb250YWlucygiLS1yZXF1ZXN0LWFjY2Vzc2liaWxpdHkiKSB7CiAgICBsZXQga2V5ID0ga0FYVHJ1c3RlZENoZWNrT3B0aW9uUHJvbXB0LnRha2VVbnJldGFpbmVkVmFsdWUoKSBhcyBTdHJpbmcKICAgIGxldCB0cnVzdGVkID0gQVhJc1Byb2Nlc3NUcnVzdGVkV2l0aE9wdGlvbnMoW2tleTogdHJ1ZV0gYXMgQ0ZEaWN0aW9uYXJ5KQogICAgaWYgdHJ1c3RlZCB7CiAgICAgICAgcHJpbnQoIuW3suaOiOadg++8jOaXoOmcgOWGjeaTjeS9nOOAgiIpCiAgICB9IGVsc2UgewogICAgICAgIHByaW50KCLlt7LlvLnlh7rns7vnu5/mjojmnYPlvJXlr7zjgIIiKQogICAgICAgIHByaW50KCLlpoLmnpzns7vnu5/orr7nva7ph4zmsqHmnInoh6rliqjlh7rnjrDmnaHnm67vvIzor7flnKjjgIzovoXliqnlip/og73jgI3liJfooajkuK3ngrkg77yLIOa3u+WKoO+8miIpCiAgICAgICAgcHJpbnQoQ29tbWFuZExpbmUuYXJndW1lbnRzWzBdKQogICAgICAgIHByaW50KCIiKQogICAgICAgIHByaW50KCLms6jmhI/vvJrlpoLmnpzliJfooajph4zlt7LmnIkgQkxFVW5sb2NrQ21kIOS4lOW8gOWFs+aYr+aJk+W8gOeahO+8jOS9huWvuemSqeaXoOaViO+8jCIpCiAgICAgICAgcHJpbnQoIuivt+WFiOeUqOOAjOKIkuOAjeWIoOmZpOWug++8jOWGjemHjeaWsOa3u+WKoOS4gOasoeKAlOKAlOaXp+aOiOadg+WPr+iDvee7keWumuS6huaXp+eJiOacrOeahOeoi+W6j+OAgiIpCiAgICB9CiAgICBleGl0KHRydXN0ZWQgPyAwIDogMSkKfQoKLy8g6YCa55+l5q2j5Zyo6L+Q6KGM55qE5a6I5oqk6L+b56iL5Yi35paw5p2D6ZmQ54q25oCB5paH5Lu244CCCi8vIOeUqOaIt+WcqOOAjOezu+e7n+iuvue9ruOAjemHjOWImuWLvumAieWujOaXtu+8jOmcgOimgeeUqOi/meS4queri+WIu+abtOaWsCBkYWVtb24tc3RhdHVzLmpzb27vvIwKLy8g5ZCm5YiZ6KaB562J5Yiw5LiL5LiA5qyh6Kej6ZSB5omN5Lya5Yi35paw44CCCmlmIGFyZ3MuY29udGFpbnMoIi0tYXgtcmVmcmVzaCIpIHsKICAgIGxldCBwYXlsb2FkOiBbU3RyaW5nOiBTdHJpbmddID0gWyJhY3Rpb24iOiAicmVmcmVzaC1heCJdCiAgICBpZiBsZXQgZGF0YSA9IHRyeT8gSlNPTlNlcmlhbGl6YXRpb24uZGF0YSh3aXRoSlNPTk9iamVjdDogcGF5bG9hZCkgewogICAgICAgIHRyeT8gZGF0YS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga1JlZnJlc2hSZXF1ZXN0UGF0aCkpCiAgICB9CiAgICBleGl0KDApCn0KCi8vIOWujOaVtOiviuaWre+8muaKiiLov5nkuKrlj6/miafooYzmlofku7boh6rlt7Ei55yL5Yiw55qE5p2D6ZmQ44CB6ZKl5YyZ5Liy44CB6ZSB5bGP54q25oCB5YWo6YOo5omT5Y2w5Ye65p2l44CCCi8vIOS4jiAtLWNoZWNrIOeahOWMuuWIq+aYr+Wug+WQjOaXtuaKpeWRiuabtOe7hueahOWIpOWumuS+neaNru+8jOS+v+S6juWMuuWIhuaYryLmnYPpmZDmsqHnu5nlr7kiCi8vIOi/mOaYryLliKvnmoTnjq/oioLlh7rpl67popgi44CCCmlmIGFyZ3MuY29udGFpbnMoIi0tZGlhZyIpIHsKICAgIGxldCBidW5kbGVJRCA9IEJ1bmRsZS5tYWluLmJ1bmRsZUlkZW50aWZpZXIgPz8gIijml6ApIgogICAgbGV0IGV4ZSA9IENvbW1hbmRMaW5lLmFyZ3VtZW50c1swXQogICAgcHJpbnQoIuWPr+aJp+ihjOaWh+S7tiA6IFwoZXhlKSIpCiAgICBwcmludCgiQnVuZGxlIElEICA6IFwoYnVuZGxlSUQpIikKICAgIHByaW50KCJCdW5kbGUg6Lev5b6EOiBcKEJ1bmRsZS5tYWluLmJ1bmRsZVBhdGgpIikKICAgIHByaW50KCIiKQogICAgbGV0IHRydXN0ZWQgPSBhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpCiAgICBwcmludCgiQVhJc1Byb2Nlc3NUcnVzdGVkIDogXCh0cnVzdGVkKSIpCiAgICBwcmludCgiICDihpIg6L+Z5LiA6aG55pivIFRDQyDlr7nmnKzkuozov5vliLbnmoTliKTlrprvvIzkuI7jgIzns7vnu5/orr7nva7jgI3ph4zmmL7npLrnmoTkuIDoh7QiKQogICAgcHJpbnQoIiIpCiAgICBpZiBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIHsKICAgICAgICBwcmludCgi6YWN572uICAgICAgIDog5q2j5bi477yI6K6+5aSH5ZCNIFwoY29uZmlnLmRldmljZU5hbWUp77yJIikKICAgICAgICBpZiBsZXQgcHcgPSBmZXRjaFBhc3N3b3JkKGFjY291bnQ6IGNvbmZpZy5rZXljaGFpbkFjY291bnQpIHsKICAgICAgICAgICAgcHJpbnQoIumSpeWMmeS4suWvhueggSA6IOWPr+ivu+WPlu+8iFwocHcuY291bnQpIOWtl+espu+8iSIpCiAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgcHJpbnQoIumSpeWMmeS4suWvhueggSA6IOivu+WPluWksei0pSIpCiAgICAgICAgfQogICAgfSBlbHNlIHsKICAgICAgICBwcmludCgi6YWN572uICAgICAgIDog57y65aSxIikKICAgIH0KICAgIHByaW50KCLmmK/lkKbplIHlsY8gICA6IFwoaXNTY3JlZW5Mb2NrZWQoKSA/ICLmmK8iIDogIuWQpiIpIikKICAgIHByaW50KCIiKQogICAgcHJpbnQoIuiLpeS4iumdoiBBWElzUHJvY2Vzc1RydXN0ZWQg5Li6IGZhbHNl77yM5L2G44CM57O757uf6K6+572uIOKGkiDovoXliqnlip/og73jgI3ph4zlvIDlhbPmmK/miZPlvIDnmoTvvIwiKQogICAgcHJpbnQoIuivtOaYjuivpemhueaOiOadg+e7keWumueahOaYr+aXp+eJiOacrOS6jOi/m+WItuOAguivt+WcqOivpeWIl+ihqOmHjOWIoOmZpCBCTEVVbmxvY2tDbWTvvIwiKQogICAgcHJpbnQoIueEtuWQjumHjeaWsOi/kOihjOiuvue9ruWQkeWvvOa3u+WKoOS4gOasoeOAgiIpCiAgICBleGl0KHRydXN0ZWQgPyAwIDogMSkKfQoKLy8g5L6b5a6J6KOF6ISa5pys5p+l6K+i5p2D6ZmQ54q25oCB44CC5b+F6aG755SxIEFwcCBidW5kbGUg5YaF6L+Z5Liq5Y+v5omn6KGM5paH5Lu26Ieq5bex5oql5ZGK77yMCi8vIOWboOS4uuOAjOi+heWKqeWKn+iDveOAjeadg+mZkOaYr+aMieS6jOi/m+WItu+8iFRDQyDkuLvkvZPvvInmjojkuojnmoTvvJrlj6bnvJbkuIDkuKrmjqLmtYvlsI/nqIvluo/ljrvmn6XvvIwKLy8g5b6X5Yiw55qE5piv6YKj5Liq56iL5bqP6Ieq5bex55qE5p2D6ZmQ77yM5Lya5rC46L+c5piv44CM5pyq5o6I5p2D44CN4oCU4oCU6L+Z5q2j5piv5LmL5YmN55qE6K+v5oql5p2l5rqQ44CCCmlmIGFyZ3MuY29udGFpbnMoIi0tYXgtc3RhdHVzIikgewogICAgZXhpdChhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpID8gMCA6IDEpCn0KCi8vIOWkmuWvhueggeeuoeeQhuOAguS+m+iuvue9ruWQkeWvvOS4juWRveS7pOihjOWFseeUqO+8jOmAu+i+keWPquWcqOi/memHjOWunueOsOS4gOS7veOAggovLwovLyAgIC0tcGFzc3dvcmRzIGxpc3QgWy0tanNvbl0gICAgICAgIOWIl+WHuuWvhuegge+8iOm7mOiupOaJk+egge+8iQovLyAgIC0tcGFzc3dvcmRzIGFkZCAgIC0tc3RkaW4gICAgICAgIOS7juagh+WHhui+k+WFpeivu+S4gOihjOS9nOS4uuaWsOWvhueggQovLyAgIC0tcGFzc3dvcmRzIHNldCAgIC0tc3RkaW4gICAgICAgIOaVtOS9k+abv+aNou+8iOivu+S4gOihjOS4gOS4qu+8jOepuuihjOe7k+adn++8iQovLyAgIC0tcGFzc3dvcmRzIHJlbW92ZSAtLWluZGV4IE4gICAgIOWIoOmZpOesrCBOIOS4qu+8iOS7jiAxIOW8gOWni++8iQovLyAgIC0tcGFzc3dvcmRzIGNsZWFyICAgICAgICAgICAgICAgIOa4heepugppZiBsZXQgaWR4ID0gYXJncy5maXJzdEluZGV4KG9mOiAiLS1wYXNzd29yZHMiKSB7CiAgICBsZXQganNvbk91dCA9IGFyZ3MuY29udGFpbnMoIi0tanNvbiIpCiAgICBsZXQgYWNjb3VudCA9IGxvYWRDb25maWcoKT8ua2V5Y2hhaW5BY2NvdW50ID8/IE5TVXNlck5hbWUoKQogICAgbGV0IGFjdGlvbiA9IChpZHggKyAxIDwgYXJncy5jb3VudCkgPyBhcmdzW2lkeCArIDFdIDogImxpc3QiCiAgICB2YXIgbGlzdCA9IGZldGNoUGFzc3dvcmRzKGFjY291bnQ6IGFjY291bnQpCgogICAgLy8vIOivu+WPluagh+WHhui+k+WFpeS4reeahOWvhueggeOAggogICAgLy8vCiAgICAvLy8gLSBQYXJhbWV0ZXIgc2luZ2xlOiB0cnVlIOWPquivu+S4gOihjO+8iGFkZO+8ie+8m2ZhbHNlIOivu+WIsOepuuihjOaIliBFT0Yg5Li65q2i77yIc2V077yJCiAgICAvLy8KICAgIC8vLyDms6jmhI/vvJrovpPlhaXmmK/mjInooYzkvKDovpPnmoTvvIzlm6DmraQqKuWvhueggeacrOi6q+S4jeiDveWMheWQq+aNouihjOespioq4oCU4oCUCiAgICAvLy8g5ZCr5o2i6KGM55qE5a+G56CB5Lya6KKr5ouG5oiQ5Lik5p2h77yM5omA5Lul6L+Z6YeM55u05o6l5ouS57ud5bm25oql6ZSZ77yM6ICM5LiN5piv6Z2Z6buY5ouG5byA44CCCiAgICAvLy8g5a6e6Le15Lit55m75b2V5a+G56CB5ZCr5o2i6KGM5p6B5Li6572V6KeB77yM55WM6Z2i5LiK55qE5a+G56CB5qGG5Lmf5peg5rOV6L6T5YWl5o2i6KGM44CCCiAgICBmdW5jIHJlYWRMaW5lcyhzaW5nbGU6IEJvb2wpIC0+IFtTdHJpbmddIHsKICAgICAgICB2YXIgbGluZXM6IFtTdHJpbmddID0gW10KICAgICAgICB3aGlsZSBsZXQgbGluZSA9IHJlYWRMaW5lKHN0cmlwcGluZ05ld2xpbmU6IHRydWUpIHsKICAgICAgICAgICAgaWYgc2luZ2xlIHsKICAgICAgICAgICAgICAgIGlmICFsaW5lLmlzRW1wdHkgeyBsaW5lcy5hcHBlbmQobGluZSkgfQogICAgICAgICAgICAgICAgYnJlYWsKICAgICAgICAgICAgfQogICAgICAgICAgICBpZiBsaW5lLmlzRW1wdHkgeyBicmVhayB9ICAgLy8g56m66KGM57uT5p2fCiAgICAgICAgICAgIGxpbmVzLmFwcGVuZChsaW5lKQogICAgICAgIH0KICAgICAgICByZXR1cm4gbGluZXMKICAgIH0KCiAgICBzd2l0Y2ggYWN0aW9uIHsKICAgIGNhc2UgImxpc3QiOgogICAgICAgIC8vIC0tdmFsdWVz77ya5LulIEpTT04g5pWw57uE6L6T5Ye65Y6f5aeL5a+G56CB77yM5L6b6K6+572u5ZCR5a+857K+56Gu6K+75Y+W44CCCiAgICAgICAgLy8g5LiN6IO96YCQ6KGM6L6T5Ye64oCU4oCU5a+G56CB5pys6Lqr5Y+v6IO95ZCr5o2i6KGM56ym77yM5Lya5LiA5p2h6KKr5ouG5oiQ5Lik5p2h44CCCiAgICAgICAgLy8gSlNPTiDkvJrmiormjaLooYzovazkuYnvvIzog73nsr7noa7mib/ovb3ku7vmhI/lrZfnrKbjgIIKICAgICAgICBpZiBhcmdzLmNvbnRhaW5zKCItLXZhbHVlcyIpIHsKICAgICAgICAgICAgaWYgbGV0IGRhdGEgPSB0cnk/IEpTT05TZXJpYWxpemF0aW9uLmRhdGEod2l0aEpTT05PYmplY3Q6IGxpc3QpLAogICAgICAgICAgICAgICBsZXQgdGV4dCA9IFN0cmluZyhkYXRhOiBkYXRhLCBlbmNvZGluZzogLnV0ZjgpIHsKICAgICAgICAgICAgICAgIHByaW50KHRleHQpCiAgICAgICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgICAgICBwcmludCgiW10iKQogICAgICAgICAgICB9CiAgICAgICAgICAgIGV4aXQoMCkKICAgICAgICB9CiAgICAgICAgaWYganNvbk91dCB7CiAgICAgICAgICAgIHByaW50SlNPTihbImNvdW50IjogbGlzdC5jb3VudCwgImxlbmd0aHMiOiBsaXN0Lm1hcCB7ICQwLmNvdW50IH1dKQogICAgICAgIH0gZWxzZSB7CiAgICAgICAgICAgIGlmIGxpc3QuaXNFbXB0eSB7CiAgICAgICAgICAgICAgICBwcmludCgi5bCa5pyq5L+d5a2Y5Lu75L2V5a+G56CB44CCIikKICAgICAgICAgICAgfSBlbHNlIHsKICAgICAgICAgICAgICAgIHByaW50KCLlt7Lkv53lrZggXChsaXN0LmNvdW50KSDkuKrlr4bnoIHvvIjmjInlsJ3or5Xpobrluo/vvInvvJoiKQogICAgICAgICAgICAgICAgZm9yIChuLCBwdykgaW4gbGlzdC5lbnVtZXJhdGVkKCkgewogICAgICAgICAgICAgICAgICAgIHByaW50KCIgIFwobiArIDEpLiBcKFN0cmluZyhyZXBlYXRpbmc6ICLigKIiLCBjb3VudDogbWF4KHB3LmNvdW50LCAxKSkpICDvvIhcKHB3LmNvdW50KSDlrZfnrKbvvIkiKQogICAgICAgICAgICAgICAgfQogICAgICAgICAgICB9CiAgICAgICAgfQogICAgICAgIGV4aXQoMCkKCiAgICBjYXNlICJhZGQiOgogICAgICAgIGxldCBuZXdPbmVzID0gcmVhZExpbmVzKHNpbmdsZTogdHJ1ZSkKICAgICAgICBndWFyZCAhbmV3T25lcy5pc0VtcHR5IGVsc2UgewogICAgICAgICAgICBpZiBqc29uT3V0IHsgcHJpbnRKU09OKFsib2siOiBmYWxzZSwgImVycm9yIjogIuayoeacieS7juagh+WHhui+k+WFpeivu+WIsOWvhueggSJdKSB9CiAgICAgICAgICAgIGVsc2UgeyBGaWxlSGFuZGxlLnN0YW5kYXJkRXJyb3Iud3JpdGUoIuayoeacieS7juagh+WHhui+k+WFpeivu+WIsOWvhueggVxuIi5kYXRhKHVzaW5nOiAudXRmOCkhKSB9CiAgICAgICAgICAgIGV4aXQoMikKICAgICAgICB9CiAgICAgICAgbGlzdC5hcHBlbmQoY29udGVudHNPZjogbmV3T25lcykKICAgICAgICBsZXQgb2sgPSBzdG9yZVBhc3N3b3JkcyhsaXN0LCBhY2NvdW50OiBhY2NvdW50KQogICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IG9rLCAiY291bnQiOiBsaXN0LmNvdW50XSkgfQogICAgICAgIGVsc2UgeyBwcmludChvayA/ICLlt7Lmt7vliqDvvIzlhbEgXChsaXN0LmNvdW50KSDkuKrlr4bnoIHjgIIiIDogIuWGmeWFpemSpeWMmeS4suWksei0peOAgiIpIH0KICAgICAgICBleGl0KG9rID8gMCA6IDEpCgogICAgY2FzZSAic2V0IjoKICAgICAgICBsZXQgbmV3TGlzdCA9IHJlYWRMaW5lcyhzaW5nbGU6IGZhbHNlKQogICAgICAgIGd1YXJkICFuZXdMaXN0LmlzRW1wdHkgZWxzZSB7CiAgICAgICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IGZhbHNlLCAiZXJyb3IiOiAi5rKh5pyJ5LuO5qCH5YeG6L6T5YWl6K+75Yiw5a+G56CBIl0pIH0KICAgICAgICAgICAgZWxzZSB7IEZpbGVIYW5kbGUuc3RhbmRhcmRFcnJvci53cml0ZSgi5rKh5pyJ5LuO5qCH5YeG6L6T5YWl6K+75Yiw5a+G56CBXG4iLmRhdGEodXNpbmc6IC51dGY4KSEpIH0KICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBsZXQgb2sgPSBzdG9yZVBhc3N3b3JkcyhuZXdMaXN0LCBhY2NvdW50OiBhY2NvdW50KQogICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IG9rLCAiY291bnQiOiBuZXdMaXN0LmNvdW50XSkgfQogICAgICAgIGVsc2UgeyBwcmludChvayA/ICLlt7Lorr7nva7kuLogXChuZXdMaXN0LmNvdW50KSDkuKrlr4bnoIHjgIIiIDogIuWGmeWFpemSpeWMmeS4suWksei0peOAgiIpIH0KICAgICAgICBleGl0KG9rID8gMCA6IDEpCgogICAgY2FzZSAicmVtb3ZlIjoKICAgICAgICBndWFyZCBsZXQgdmlkeCA9IGFyZ3MuZmlyc3RJbmRleChvZjogIi0taW5kZXgiKSwgdmlkeCArIDEgPCBhcmdzLmNvdW50LAogICAgICAgICAgICAgIGxldCBvbmVCYXNlZCA9IEludChhcmdzW3ZpZHggKyAxXSksIG9uZUJhc2VkID49IDEsIG9uZUJhc2VkIDw9IGxpc3QuY291bnQgZWxzZSB7CiAgICAgICAgICAgIGxldCBtc2cgPSAi57Si5byV5peg5pWI77yI6IyD5Zu05Li6IDEuLlwobGlzdC5jb3VudCnvvIkiCiAgICAgICAgICAgIGlmIGpzb25PdXQgeyBwcmludEpTT04oWyJvayI6IGZhbHNlLCAiZXJyb3IiOiBtc2ddKSB9IGVsc2UgeyBwcmludChtc2cpIH0KICAgICAgICAgICAgZXhpdCgyKQogICAgICAgIH0KICAgICAgICBsaXN0LnJlbW92ZShhdDogb25lQmFzZWQgLSAxKQogICAgICAgIGxldCBvayA9IHN0b3JlUGFzc3dvcmRzKGxpc3QsIGFjY291bnQ6IGFjY291bnQpCiAgICAgICAgaWYganNvbk91dCB7IHByaW50SlNPTihbIm9rIjogb2ssICJjb3VudCI6IGxpc3QuY291bnRdKSB9CiAgICAgICAgZWxzZSB7IHByaW50KG9rID8gIuW3suWIoOmZpO+8jOWJqeS9mSBcKGxpc3QuY291bnQpIOS4quWvhueggeOAgiIgOiAi5YaZ5YWl6ZKl5YyZ5Liy5aSx6LSl44CCIikgfQogICAgICAgIGV4aXQob2sgPyAwIDogMSkKCiAgICBjYXNlICJjbGVhciI6CiAgICAgICAgbGV0IG9rID0gc3RvcmVQYXNzd29yZHMoW10sIGFjY291bnQ6IGFjY291bnQpCiAgICAgICAgaWYganNvbk91dCB7IHByaW50SlNPTihbIm9rIjogb2ssICJjb3VudCI6IDBdKSB9CiAgICAgICAgZWxzZSB7IHByaW50KG9rID8gIuW3sua4heepuuWFqOmDqOWvhueggeOAgiIgOiAi5YaZ5YWl6ZKl5YyZ5Liy5aSx6LSl44CCIikgfQogICAgICAgIGV4aXQob2sgPyAwIDogMSkKCiAgICBkZWZhdWx0OgogICAgICAgIGxldCBtc2cgPSAi5pyq55+l5pON5L2c77yaXChhY3Rpb24p77yI5Y+v55So77yabGlzdC9hZGQvc2V0L3JlbW92ZS9jbGVhcu+8iSIKICAgICAgICBpZiBqc29uT3V0IHsgcHJpbnRKU09OKFsib2siOiBmYWxzZSwgImVycm9yIjogbXNnXSkgfSBlbHNlIHsgcHJpbnQobXNnKSB9CiAgICAgICAgZXhpdCgyKQogICAgfQp9CgppZiBhcmdzLmNvbnRhaW5zKCItLWNoZWNrIikgewogICAgZ3VhcmQgbGV0IGNvbmZpZyA9IGxvYWRDb25maWcoKSBlbHNlIHsKICAgICAgICBwcmludCgi6YWN572uOiDnvLrlpLHvvIhcKGtDb25maWdQYXRoKe+8iSIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgcHJpbnQoIumFjee9rjog5q2j5bi4IikKICAgIHByaW50KCLorr7lpIflkI06IFwoY29uZmlnLmRldmljZU5hbWUpIikKICAgIHByaW50KCLpkqXljJnkuLLotKbmiLc6IFwoY29uZmlnLmtleWNoYWluQWNjb3VudCkiKQogICAgcHJpbnQoIui+heWKqeWKn+iDveadg+mZkDogXChhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpID8gIuW3suaOiOadgyIgOiAi5pyq5o6I5p2D77yI6Kej6ZSB5Lya5aSx6LSl77yJIikiKQogICAgaWYgbGV0IHB3ID0gZmV0Y2hQYXNzd29yZChhY2NvdW50OiBjb25maWcua2V5Y2hhaW5BY2NvdW50KSB7CiAgICAgICAgcHJpbnQoIueZu+W9leWvhueggTog5bey5a2Y5YWl6ZKl5YyZ5Liy77yIXChwdy5jb3VudCkg5Liq5a2X56ym77yJIikKICAgIH0gZWxzZSB7CiAgICAgICAgcHJpbnQoIueZu+W9leWvhueggTog5pyq5om+5YiwIikKICAgIH0KICAgIHByaW50KCLlvZPliY3mmK/lkKbplIHlsY86IFwoaXNTY3JlZW5Mb2NrZWQoKSA/ICLmmK8iIDogIuWQpiIpIikKICAgIHByaW50KCIiKQogICAgcHJpbnQoIuKUgOKUgCDlrojmiqTov5vnqIvlrp7pmYXnirbmgIHvvIjlhrPlrprop6PplIHog73lkKbmiJDlip/vvInilIDilIAiKQogICAgLy8g5rOo5oSP77ya5pys6L+b56iL5LuO57uI56uv5ZCv5Yqo5pe25Y+v6IO957un5om/5LqG57uI56uv55qEIEFYIOS/oeS7u++8jOWboOatpOS4iumdoumCo+S4gOmhuQogICAgLy8g5pyq5b+F5Luj6KGo55yf5q2j5bmy5rS755qE5a6I5oqk6L+b56iL44CC55yf5a6e54q25oCB5Lul5a6I5oqk6L+b56iL6Ieq5bex6JC955uY55qE5YaF5a655Li65YeG44CCCiAgICBpZiBsZXQgZGF0YSA9IEZpbGVNYW5hZ2VyLmRlZmF1bHQuY29udGVudHMoYXRQYXRoOiBrU3RhdHVzUGF0aCksCiAgICAgICBsZXQgb2JqID0gdHJ5PyBKU09OU2VyaWFsaXphdGlvbi5qc29uT2JqZWN0KHdpdGg6IGRhdGEpIGFzPyBbU3RyaW5nOiBBbnldIHsKICAgICAgICBsZXQgYXggPSAob2JqWyJheFRydXN0ZWQiXSBhcz8gQm9vbCkgPz8gZmFsc2UKICAgICAgICBsZXQgcGlkID0gb2JqWyJwaWQiXSBhcz8gSW50ID8/IC0xCiAgICAgICAgbGV0IGF0ID0gb2JqWyJ1cGRhdGVkQXQiXSBhcz8gU3RyaW5nID8/ICI/IgogICAgICAgIHByaW50KCLlrojmiqTov5vnqIsgQVgg5p2D6ZmQOiBcKGF4ID8gIuW3suaOiOadgyDinJMiIDogIuacquaOiOadgyDinJciKSIpCiAgICAgICAgcHJpbnQoIiAg6K6w5b2V5pe26Ze0OiBcKGF0KSAgUElEOiBcKHBpZCkiKQogICAgICAgIGlmICFheCB7CiAgICAgICAgICAgIHByaW50KCIgIOKGkiDop6PplIHkvJrlpLHotKXjgILor7flnKjjgIzns7vnu5/orr7nva4g4oaSIOmakOengeS4juWuieWFqOaApyDihpIg6L6F5Yqp5Yqf6IO944CNIikKICAgICAgICAgICAgcHJpbnQoIiAgICAg5Lit5Yu+6YCJIEJMRVVubG9ja0NtZO+8m+iLpeW8gOWFs+W3suaJk+W8gO+8jOivt+WFiOWIoOmZpOivpemhueWGjemHjeaWsOa3u+WKoOOAgiIpCiAgICAgICAgfQogICAgfSBlbHNlIHsKICAgICAgICBwcmludCgi5a6I5oqk6L+b56iLIEFYIOadg+mZkDog5pyq55+l77yI5a6I5oqk6L+b56iL5bCa5pyq5YaZ6L+H54q25oCB77yM5Y+v6IO95pyq6L+Q6KGM77yJIikKICAgIH0KICAgIGV4aXQoMCkKfQoKLy8gLS1zZXQta2V5CmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLXNldC1rZXkiKSwgaWR4ICsgMSA8IGFyZ3MuY291bnQgewogICAgbGV0IG5ld0tleSA9IGFyZ3NbaWR4ICsgMV0KICAgIGd1YXJkIERhdGEoYmFzZTY0RW5jb2RlZDogbmV3S2V5KT8uY291bnQgPT0gMzIgZWxzZSB7CiAgICAgICAgcHJpbnQoIumUmeivr++8muWvhumSpeW/hemhu+aYryAzMiDlrZfoioLnmoQgYmFzZTY0IOe8lueggeWtl+espuS4suOAgiIpCiAgICAgICAgZXhpdCgxKQogICAgfQogICAgdmFyIGNvbmZpZyA9IGxvYWRDb25maWcoKSA/PyBDb25maWcoaG1hY0tleTogbmV3S2V5LAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAga2V5Y2hhaW5BY2NvdW50OiBOU1VzZXJOYW1lKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZXZpY2VOYW1lOiBIb3N0LmN1cnJlbnQoKS5sb2NhbGl6ZWROYW1lID8/ICJNYWMiKQogICAgY29uZmlnLmhtYWNLZXkgPSBuZXdLZXkKICAgIGxldCBlbmNvZGVyID0gSlNPTkVuY29kZXIoKQogICAgZW5jb2Rlci5vdXRwdXRGb3JtYXR0aW5nID0gWy5wcmV0dHlQcmludGVkLCAuc29ydGVkS2V5c10KICAgIHRyeT8gZW5jb2Rlci5lbmNvZGUoY29uZmlnKS53cml0ZSh0bzogVVJMKGZpbGVVUkxXaXRoUGF0aDoga0NvbmZpZ1BhdGgpKQogICAgdHJ5PyBGaWxlTWFuYWdlci5kZWZhdWx0LnNldEF0dHJpYnV0ZXMoWy5wb3NpeFBlcm1pc3Npb25zOiAwbzYwMF0sIG9mSXRlbUF0UGF0aDoga0NvbmZpZ1BhdGgpCiAgICBwcmludCgi5bey5pu05paw6YWN5a+55a+G6ZKl77yM6K+35Zyo5omL5py6IEFwcCDkuK3lkIzmraXkv67mlLnjgIIiKQogICAgZXhpdCgwKQp9CgovLyAtLXNob3ctdG9rZW7vvJrmiZPljbDlvZPliY3lr4bpkqXvvJvmnKrlronoo4Xml7bnlJ/miJDkuIDkuKrkuLTml7blr4bpkqXvvIjphY3lkIggLS1kcnktcnVuIOa1i+ivleeUqO+8iQppZiBhcmdzLmNvbnRhaW5zKCItLXNob3ctdG9rZW4iKSB7CiAgICBpZiBsZXQgY29uZmlnID0gbG9hZENvbmZpZygpIHsKICAgICAgICBwcmludChjb25maWcuaG1hY0tleSkKICAgIH0gZWxzZSB7CiAgICAgICAgdmFyIGJ5dGVzID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiAzMikKICAgICAgICBmb3IgaSBpbiAwLi48MzIgeyBieXRlc1tpXSA9IFVJbnQ4LnJhbmRvbShpbjogMC4uLjI1NSkgfQogICAgICAgIHByaW50KERhdGEoYnl0ZXMpLmJhc2U2NEVuY29kZWRTdHJpbmcoKSkKICAgIH0KICAgIGV4aXQoMCkKfQoKaWYgYXJncy5jb250YWlucygiLS1kcnktcnVuIikgewogICAgZHJ5UnVuID0gdHJ1ZQp9CgovLyDmtYvor5XmqKHlvI/kuJTmsqHmnInmraPlvI/phY3nva7ml7bvvIznlKjkuLTml7blr4bpkqUgKyDkuLTml7botKbmiLfvvIzmlrnkvr/lnKjmnKrlronoo4XnmoTmnLrlmajkuIrpqozor4EKaWYgZHJ5UnVuICYmIGxvYWRDb25maWcoKSA9PSBuaWwgewogICAgdmFyIGJ5dGVzID0gW1VJbnQ4XShyZXBlYXRpbmc6IDAsIGNvdW50OiAzMikKICAgIGZvciBpIGluIDAuLjwzMiB7IGJ5dGVzW2ldID0gVUludDgucmFuZG9tKGluOiAwLi4uMjU1KSB9CiAgICBsZXQgdGVtcENvbmZpZyA9IENvbmZpZyhobWFjS2V5OiBEYXRhKGJ5dGVzKS5iYXNlNjRFbmNvZGVkU3RyaW5nKCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBrZXljaGFpbkFjY291bnQ6IE5TVXNlck5hbWUoKSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgIGRldmljZU5hbWU6ICJCTEVVbmxvY2stRFJZUlVOIikKICAgIGxldCBlbmNvZGVyID0gSlNPTkVuY29kZXIoKQogICAgZW5jb2Rlci5vdXRwdXRGb3JtYXR0aW5nID0gWy5wcmV0dHlQcmludGVkLCAuc29ydGVkS2V5c10KICAgIHRyeT8gZW5jb2Rlci5lbmNvZGUodGVtcENvbmZpZykud3JpdGUodG86IFVSTChmaWxlVVJMV2l0aFBhdGg6IGtDb25maWdQYXRoKSkKICAgIHRyeT8gRmlsZU1hbmFnZXIuZGVmYXVsdC5zZXRBdHRyaWJ1dGVzKFsucG9zaXhQZXJtaXNzaW9uczogMG82MDBdLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgb2ZJdGVtQXRQYXRoOiBrQ29uZmlnUGF0aCkKICAgIGxvZygiZHJ5LXJ1bu+8muW3sueUn+aIkOS4tOaXtumFjee9riBcKGtDb25maWdQYXRoKSIpCn0KCmd1YXJkIGxldCBjb25maWcgPSBsb2FkQ29uZmlnKCkgZWxzZSB7CiAgICBwcmludCgi6ZSZ6K+v77ya5om+5LiN5Yiw6YWN572u5paH5Lu2IFwoa0NvbmZpZ1BhdGgpIikKICAgIHByaW50KCLor7flhYjov5DooYwgbWFjLWJsZS11bmxvY2suc2ggaW5zdGFsbCDlrozmiJDliJ3lp4vljJbjgIIiKQogICAgZXhpdCgxKQp9CgpndWFyZCBsZXQga2V5RGF0YSA9IERhdGEoYmFzZTY0RW5jb2RlZDogY29uZmlnLmhtYWNLZXkpLCBrZXlEYXRhLmNvdW50ID09IDMyIGVsc2UgewogICAgcHJpbnQoIumUmeivr++8mumFjee9ruaWh+S7tuS4reeahCBobWFjS2V5IOaXoOaViOOAgiIpCiAgICBleGl0KDEpCn0KCmlmIGxldCBpZHggPSBhcmdzLmZpcnN0SW5kZXgob2Y6ICItLWRldmljZS1uYW1lIiksIGlkeCArIDEgPCBhcmdzLmNvdW50IHsKICAgIHZhciB1cGRhdGVkID0gY29uZmlnCiAgICB1cGRhdGVkLmRldmljZU5hbWUgPSBhcmdzW2lkeCArIDFdCiAgICBsZXQgZW5jb2RlciA9IEpTT05FbmNvZGVyKCkKICAgIGVuY29kZXIub3V0cHV0Rm9ybWF0dGluZyA9IFsucHJldHR5UHJpbnRlZCwgLnNvcnRlZEtleXNdCiAgICB0cnk/IGVuY29kZXIuZW5jb2RlKHVwZGF0ZWQpLndyaXRlKHRvOiBVUkwoZmlsZVVSTFdpdGhQYXRoOiBrQ29uZmlnUGF0aCkpCiAgICBwcmludCgi6K6+5aSH5ZCN5bey5pu05paw5Li6IFwodXBkYXRlZC5kZXZpY2VOYW1lKSIpCiAgICBleGl0KDApCn0KCmxldCBzeW1tZXRyaWNLZXkgPSBTeW1tZXRyaWNLZXkoZGF0YToga2V5RGF0YSkKCmlmICFhY2Nlc3NpYmlsaXR5R3JhbnRlZCgpIHsKICAgIGxvZygi6K2m5ZGK77ya5bCa5pyq6I635b6X44CM6L6F5Yqp5Yqf6IO944CN5p2D6ZmQ77yM6Kej6ZSB5LiN5Lya55Sf5pWI44CCIikKICAgIGxvZygi6K+36L+Q6KGM77yaQkxFVW5sb2NrQ21kIC0tYWRkLWFjY2Vzc2liaWxpdHkiKQp9Cgpsb2coIuWQr+WKqCBCTEVVbmxvY2tDbWTvvIzorr7lpIflkI3jgIxcKGNvbmZpZy5kZXZpY2VOYW1lKeOAjSIpCgovLyDmiormnKzov5vnqIvvvIjlrojmiqTov5vnqIvvvInoh6rouqvnmoTmnYPpmZDliKTlrprokL3nm5jvvIzkvpvorr7nva7lkJHlr7zor7vlj5bjgIIKLy8g6L+Z5LiA6aG55omN5piv5Yaz5a6aIuino+mUgeiDveWQpuaIkOWKnyLnmoTnnJ/lrp7nirbmgIHjgIIKd3JpdGVEYWVtb25TdGF0dXMoKQoKbGV0IHNlcnZlciA9IFBlcmlwaGVyYWxTZXJ2ZXIoKQpzZXJ2ZXIuc3RhcnQoa2V5OiBzeW1tZXRyaWNLZXksIGRldmljZU5hbWU6IGNvbmZpZy5kZXZpY2VOYW1lKQoKLy8g6Ziy5q2i57O757uf56m66Zey5LyR55yg77ya5LyR55yg5Lya5YGc5o6J6JOd54mZ5bm/5pKt77yM5omL5py65bCx5YaN5Lmf6L+e5LiN5LiK5LqGCnZhciBzbGVlcEFzc2VydGlvbiA9IElPUE1Bc3NlcnRpb25JRCgwKQpsZXQgYXNzZXJ0aW9uUmVzdWx0ID0gSU9QTUFzc2VydGlvbkNyZWF0ZVdpdGhOYW1lKGtJT1BNQXNzZXJ0aW9uVHlwZU5vSWRsZVNsZWVwIGFzIENGU3RyaW5nLAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSU9QTUFzc2VydGlvbkxldmVsKGtJT1BNQXNzZXJ0aW9uTGV2ZWxPbiksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAiQkxFVW5sb2NrQ21kIOS/neaMgeiTneeJmeWPr+i/nuaOpSIgYXMgQ0ZTdHJpbmcsCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAmc2xlZXBBc3NlcnRpb24pCmlmIGFzc2VydGlvblJlc3VsdCA9PSBrSU9SZXR1cm5TdWNjZXNzIHsKICAgIGxvZygi5bey6Zi75q2i57O757uf56m66Zey5LyR55yg77yM5Lul5L+d5oyB6JOd54mZ5Y+v6L+e5o6l77yI5pi+56S65Zmo5LuN5Lya5q2j5bi45oGv5bGP77yJIikKfSBlbHNlIHsKICAgIGxvZygi6K2m5ZGK77ya5peg5rOV5Yib5bu66Ziy5LyR55yg5pat6KiA77yM57O757uf5LyR55yg5ZCO6JOd54mZ5bCG5pat5byAIikKfQoKLy8g6L+b56iL6YCA5Ye65pe26YeK5pS+5pat6KiACmZ1bmMgY2xlYW51cCgpIHsKICAgIGlmIHNsZWVwQXNzZXJ0aW9uICE9IDAgewogICAgICAgIElPUE1Bc3NlcnRpb25SZWxlYXNlKHNsZWVwQXNzZXJ0aW9uKQogICAgICAgIHNsZWVwQXNzZXJ0aW9uID0gMAogICAgfQogICAgbG9nKCJCTEVVbmxvY2tDbWQg6YCA5Ye6IikKfQoKc2lnbmFsKFNJR0lOVCwgU0lHX0lHTikKc2lnbmFsKFNJR1RFUk0sIFNJR19JR04pCmxldCBzaWdpbnRTb3VyY2UgPSBEaXNwYXRjaFNvdXJjZS5tYWtlU2lnbmFsU291cmNlKHNpZ25hbDogU0lHSU5ULCBxdWV1ZTogLm1haW4pCnNpZ2ludFNvdXJjZS5zZXRFdmVudEhhbmRsZXIgeyBsb2coIuaUtuWIsCBTSUdJTlTvvIzpgIDlh7oiKTsgY2xlYW51cCgpOyBleGl0KDApIH0Kc2lnaW50U291cmNlLnJlc3VtZSgpCmxldCBzaWd0ZXJtU291cmNlID0gRGlzcGF0Y2hTb3VyY2UubWFrZVNpZ25hbFNvdXJjZShzaWduYWw6IFNJR1RFUk0sIHF1ZXVlOiAubWFpbikKc2lndGVybVNvdXJjZS5zZXRFdmVudEhhbmRsZXIgeyBsb2coIuaUtuWIsCBTSUdURVJN77yM6YCA5Ye6Iik7IGNsZWFudXAoKTsgZXhpdCgwKSB9CnNpZ3Rlcm1Tb3VyY2UucmVzdW1lKCkKCi8vIOebkeinhuWIt+aWsOivt+axgu+8muiuvue9ruWQkeWvvOWcqOeUqOaIt+WujOaIkOaOiOadg+WQjuWGmeWFpeivpeaWh+S7tu+8jAovLyDlrojmiqTov5vnqIvmja7mraTnq4vliLvliLfmlrAgZGFlbW9uLXN0YXR1cy5qc29u77yM5peg6ZyA6YeN5ZCv5pyN5Yqh44CCCmxldCByZWZyZXNoVGltZXIgPSBUaW1lci5zY2hlZHVsZWRUaW1lcih3aXRoVGltZUludGVydmFsOiAxLjAsIHJlcGVhdHM6IHRydWUpIHsgXyBpbgogICAgbGV0IGZtID0gRmlsZU1hbmFnZXIuZGVmYXVsdAogICAgZ3VhcmQgZm0uZmlsZUV4aXN0cyhhdFBhdGg6IGtSZWZyZXNoUmVxdWVzdFBhdGgpIGVsc2UgeyByZXR1cm4gfQogICAgdHJ5PyBmbS5yZW1vdmVJdGVtKGF0UGF0aDoga1JlZnJlc2hSZXF1ZXN0UGF0aCkKICAgIGxvZygi5pS25Yiw5p2D6ZmQ5Yi35paw6K+35rGCIikKICAgIHdyaXRlRGFlbW9uU3RhdHVzKCkKICAgIGxvZygi5p2D6ZmQ54q25oCB5bey5pu05paw77yM5omL5py656uv5Lya56uL5Y2z55yL5Yiw5pyA5paw57uT5p6cIikKfQpSdW5Mb29wLm1haW4uYWRkKHJlZnJlc2hUaW1lciwgZm9yTW9kZTogLmNvbW1vbikKClJ1bkxvb3AubWFpbi5ydW4oKQo=
__SWIFT_SOURCE_END__
