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
__SWIFT_SOURCE_END__
