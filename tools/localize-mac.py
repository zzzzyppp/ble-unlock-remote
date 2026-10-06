#!/usr/bin/env python3
"""
生成本地化资源并替换源码中的硬编码文案。

- installer-src/strings/<lang>.lproj/Localizable.strings  供 App 读取
- 把 installer-src/app/*.swift 里的 "中文" 替换为 L("中文")

中文原文即 key，这样即使漏译也能回退到中文而不是显示 key。
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRINGS_DIR = os.path.join(ROOT, "installer-src", "strings")
APP_DIR = os.path.join(ROOT, "installer-src", "app")

# 中文原文 -> 英文译文
EN = {
    # ---- 通用 ----
    "好": "OK",
    "退出": "Quit",
    "取消": "Cancel",
    "完成": "Done",
    "关闭": "Close",
    "继续": "Continue",
    "添加": "Add",
    "删除选中": "Remove Selected",
    "保存": "Save",
    "保存失败": "Save Failed",
    "失败": "Failed",
    "密码": "Password",
    "长度": "Length",
    "新增：": "Add: ",
    "登录密码：": "Login password: ",

    # ---- 窗口标题 / 标题 ----
    "BLE Unlock 设置": "BLE Unlock Setup",
    "管理登录密码": "Manage Login Passwords",
    "登录密码（按顺序尝试）": "Login Passwords (tried in order)",
    "输入你的 Mac 登录密码": "Enter Your Mac Login Password",
    "更新 BLE Unlock": "Update BLE Unlock",
    "欢迎使用 BLE Unlock": "Welcome to BLE Unlock",
    "尚未安装": "Not Installed Yet",
    "没有密码": "No Passwords",
    "设置完成": "Setup Complete",
    "设置未完成": "Setup Incomplete",
    "正在设置…": "Setting up…",

    # ---- 按钮 ----
    "管理密码（可添加多个）": "Manage Passwords (multiple allowed)",
    "开始更新": "Start Update",
    "开始设置": "Start Setup",
    "复制配对令牌": "Copy Pairing Token",
    "打开系统设置授权": "Open System Settings to Authorize",
    "打开系统设置": "Open System Settings",
    "打开日志": "Open Log",
    "保存到钥匙串": "Save to Keychain",

    # ---- 向导主界面 ----
    "检测到已安装。继续操作会更新服务端，并保留你原有的配对密钥。":
        "An existing installation was found. Continuing will update the service "
        "and keep your current pairing key.",
    "接下来会在这台 Mac 上完成以下配置，全程不需要终端：":
        "The following will be configured on this Mac. No terminal needed:",
    "检测到已有安装": "Existing installation detected",
    "未检测到已有安装": "No existing installation detected",
    "检测到服务端与辅助功能权限均已就绪":
        "Service and Accessibility permission are both ready",
    "检测到服务端已安装，但守护进程缺少「辅助功能」权限":
        "Service is installed, but the daemon lacks Accessibility permission",
    "输入登录密码": "Enter login password",
    "等待输入登录密码…": "Waiting for login password…",

    # ---- 安装步骤 ----
    "安装服务端程序": "Install service",
    "保留配对密钥": "Keep pairing key",
    "生成配对密钥": "Generate pairing key",
    "设置开机自启": "Enable launch at login",
    "保存登录密码到钥匙串": "Save login password to Keychain",
    "检测已有安装": "Existing install detected",
    "密码管理窗口已关闭": "Password manager closed",
    "✗ 密码不能为空，请重新输入": "✗ Password cannot be empty, please re-enter",
    "✓ 配对令牌已复制到剪贴板": "✓ Pairing token copied to clipboard",
    "✓ 「辅助功能」权限已生效": "✓ Accessibility permission is now active",

    # ---- 失败与提示 ----
    "请先完成设置，之后即可在这里管理密码。":
        "Please finish setup first; you can manage passwords here afterwards.",
    "安装过程中出错，服务端可能未正确配置：":
        "An error occurred during setup. The service may not be configured correctly:",
    "详细信息见日志：": "See the log for details: ",
    "⚠️ 守护进程未报告权限状态，请确认它已启动":
        "⚠️ The daemon did not report its permission state — make sure it is running",
    "→ 打开「系统设置 → 隐私与安全性 → 辅助功能」":
        "→ Open System Settings → Privacy & Security → Accessibility",
    "  请把下面这个文件拖进列表（或点 ＋ 选择它）：":
        "  Drag the file below into the list (or click + and choose it):",
    "  ⚠️ 要添加的是上面这个路径，不是「应用程序」里的 BLE Unlock。":
        "  ⚠️ Add the path above — NOT the BLE Unlock in /Applications.",
    "     两者是不同的程序；授权给 App 不会让后台服务获得权限。":
        "     They are different programs; authorizing the app does not "
        "grant the background service.",
    "  若列表里已有一条 BLEUnlockCmd 且开关是打开的却仍无效，":
        "  If BLEUnlockCmd is already listed and toggled on but still ineffective,",
    "  请先用「−」删除它，再重新添加一次。":
        "  remove it with − first, then add it again.",
    "✗ 等待超时，守护进程仍未获得权限":
        "✗ Timed out — the daemon still does not have permission",
    "  可重新打开本 App，它会再次引导并复查":
        "  You can reopen this app; it will guide you again and re-check",
    "  仍在等待授权…（已等待 %d 秒）":
        "  Still waiting for authorization… (%d seconds elapsed)",
    "  提示：授权对象是 BLEUnlockCmd，不是本设置 App":
        "  Tip: the target is BLEUnlockCmd, not this setup app",
    "还差最后一步：「辅助功能」权限尚未授予**真正运行的守护进程**。\n注意：这一项必须授予 BLEUnlockCmd，而不是本设置 App。\n若系统设置里该项开关已是打开状态，请先删除它再重新添加——\n旧授权可能绑定到了旧版本的程序。":
        "One last step: Accessibility permission has not been granted to the "
        "**actual background daemon**.\n"
        "Note: this must be granted to BLEUnlockCmd, not to this setup app.\n"
        "If the entry is already present and toggled on, remove it and add it "
        "again — the old grant may be bound to a previous version.",
    "蓝牙解锁需要用你的登录密码来自动解锁屏幕。\n密码只存入 macOS 钥匙串，不写入任何文件，也不通过网络传输。":
        "BLE Unlock needs your login password to unlock the screen automatically.\n"
        "It is stored only in the macOS Keychain — never written to a file, "
        "never sent over the network.",
    "密码写入后无法回读，钥匙串可能处于锁定状态。\n请解锁「钥匙串访问」后重试。":
        "The password could not be read back; the Keychain may be locked.\n"
        "Unlock Keychain Access and try again.",
    "警告：App 正运行于随机只读路径（Gatekeeper 路径随机化）":
        "Warning: the app is running from a randomized read-only path "
        "(Gatekeeper translocation)",
    "如果刚改过密码，可以把新旧密码都留在列表里，避免某天忘记更新。":
        "If you recently changed your password, keep both old and new here "
        "so you are never locked out.",
    "全部就绪！现在可以用手机解锁这台 Mac 了。\n───── 配对令牌 ─────\n%@\n───────────────────\n在手机 App 里点「＋ 添加 Mac」粘贴令牌，然后点「解锁」。\n如果解锁没反应：\n• 确认 Mac 屏幕已锁定（未锁定时会返回 NOT_LOCKED）\n• 确认手机与 Mac 的蓝牙都已开启":
        "All set! You can now unlock this Mac from your phone.\n\n───── Pairing Token ─────\n%@\n───────────────────────\n\nOpen the phone app, tap “＋ Add Mac”, paste the token, then tap Unlock.\n\nIf unlocking does not work:\n• Make sure the Mac screen is actually locked (otherwise it returns NOT_LOCKED)\n• Make sure Bluetooth is on for both the phone and the Mac",
    "安装包内缺少服务端（Resources/BLEUnlockCmd.app）":
        "The service is missing from this installer (Resources/BLEUnlockCmd.app)",
    "检测到已安装，正在更新…": "Existing installation found, updating…",
    "包内服务端未签名，补签一次": "Bundled service is unsigned; signing it now",
    "服务端 Info.plist 缺失，安装包可能不完整":
        "Service Info.plist is missing — the installer may be incomplete",
    "服务端已安装（嵌套 app）": "Service installed (nested app)",
    "服务端已安装": "Service installed",
    "保留原有配对密钥": "Kept the existing pairing key",
    "已保留原有配对密钥": "Kept the existing pairing key",
    "已生成配对密钥": "Pairing key generated",
    "已设置开机自启": "Launch at login enabled",
    "密码写入后无法回读，钥匙串可能处于锁定状态。\n请解锁「钥匙串访问」后重试。":
        "The password could not be read back; the Keychain may be locked.\n"
        "Unlock Keychain Access and try again.",
    "密码已保存并验证": "Password saved and verified",
    "密码数据格式异常": "Password data is malformed",
    "至少要保留一个密码，否则解锁会失败。":
        "Keep at least one password, otherwise unlocking will fail.",
    "拒绝保存：密码含换行符": "Refused to save: password contains a newline",
    "服务端版本过旧，无法查询权限状态（需重新安装）":
        "Service is too old to report permission state (reinstall required)",
    "服务端未安装": "Service is not installed",
    "复制到剪贴板": "Copied to clipboard",

    # ---- 密码管理窗口 ----
    "解锁时会从上到下逐个尝试，直到屏幕解开。如果刚改过密码，可以把新旧密码都留在列表里，避免某天忘记更新。":
        "Passwords are tried from top to bottom until the screen unlocks. "
        "If you recently changed your password, keep both the old and new ones "
        "here so you are never locked out.",
    "输入一个登录密码后点「添加」": "Type a login password, then click Add",
    "尚未添加任何密码": "No passwords added yet",
    "共 %d 个密码": "%d password(s)",
    "密码不能为空": "Password cannot be empty",
    "密码不能包含换行符": "Password cannot contain a newline",
    "这个密码已经在列表里了": "This password is already in the list",
    "已添加（尚未保存）": "Added (not saved yet)",
    "已删除（尚未保存）": "Removed (not saved yet)",
    "已保存 %d 个密码到钥匙串 ✓": "Saved %d password(s) to the Keychain ✓",

    # ---- 服务端状态（显示给用户看的结果）----
    "关于 %@": "About %@",
    "退出 %@": "Quit %@",
    "退出码 %d": "exit code %d",
    "已授权": "granted",
    "已授权": "granted",
    "未授权": "not granted",
    "未报告": "not reported",

    # ---- 含插值的文案（用 %d / %@ 表示占位，脚本会归一到源码的 \(...) 形式）----
    "1. 安装服务端程序\n2. 生成你的专属配对密钥\n3. 把你的登录密码存入钥匙串\n4. 设置开机自启":
        "1. Install the service\n2. Generate your pairing key\n"
        "3. Save your login password to the Keychain\n4. Enable launch at login",
    "1. 更新服务端程序\n2. 保留原有配对密钥\n3. 重新写入登录密码\n4. 设置开机自启":
        "1. Update the service\n2. Keep your pairing key\n"
        "3. Re-save your login password\n4. Enable launch at login",
    "服务端已就绪。\n───── 配对令牌 ─────\n%@\n───────────────────\n在手机 App 里点「＋ 添加 Mac」，粘贴上面的令牌，然后点「解锁」。":
        "The service is ready.\n\n───── Pairing Token ─────\n%@\n"
        "───────────────────────\n\nOpen the phone app, tap “＋ Add Mac”, "
        "paste the token above, then tap Unlock.",
    "全部就绪！现在可以用手机解锁这台 Mac 了。\n───── 配对令牌 ─────\n%@\n───────────────────\n在手机 App 里点「＋ 添加 Mac」粘贴令牌，然后点「解锁」。":
        "All set! You can now unlock this Mac from your phone.\n\n"
        "───── Pairing Token ─────\n%@\n"
        "───────────────────────\n\nOpen the phone app, tap “＋ Add Mac”, "
        "paste the token, then tap Unlock.",
    "\n\n「辅助功能」权限已确认，一切就绪。":
        "\n\nAccessibility permission confirmed — everything is ready.",
    "安装过程中出错，服务端可能未正确配置：\n%@\n详细信息见日志：%@":
        "An error occurred during setup; the service may not be configured "
        "correctly:\n%@\n\nSee the log for details: %@",
    "钥匙串回读的内容与输入不一致：\n输入长度 %d，回读长度 %d\n请重新运行本 App 再试一次。":
        "The Keychain returned different content than what was entered:\n"
        "entered %d characters, read back %d\n\nPlease run this app again.",
    "写入钥匙串失败（%@）。\n最常见的原因是钥匙串被锁定。请打开「钥匙串访问」解锁后重试。":
        "Failed to write to the Keychain (%@).\n"
        "The most common cause is a locked Keychain. Open Keychain Access, "
        "unlock it, and try again.",
    "密码不能包含换行符。\n其中有 %d 个字符的密码含换行，请重新输入。":
        "Passwords cannot contain newlines.\n"
        "One of them (%d characters) contains a newline — please re-enter it.",
    "警告：回读内容与输入不一致（长度 %d vs %d）":
        "Warning: read-back differs from input (%d vs %d characters)",
    "登录密码已存入钥匙串（长度 %d，已回读确认）":
        "Login password saved to Keychain (%d characters, verified)",
    "仍在等待授权…（已等待 %d) 秒）":
        "Still waiting for authorization… (%d seconds elapsed)",
    "回读密码失败（退出码 %d）": "Failed to read back the password (exit code %d)",
    "已回读钥匙串密码，长度 %d": "Read back Keychain password, %d characters",
    "✗ %@ 失败：%@": "✗ %@ failed: %@",
    "共 %d 个密码": "%d password(s)",
    "已保存 %d 个密码到钥匙串 ✓": "Saved %d password(s) to the Keychain ✓",
    "解锁时会从上到下逐个尝试，直到屏幕解开。":
        "Passwords are tried from top to bottom until the screen unlocks.",
    "写入开机自启配置失败：%@": "Failed to write the launch-at-login config: %@",
    "复制服务端失败：%@": "Failed to copy the service: %@",
    "写入配置失败：%@": "Failed to write the config: %@",
    "服务端可执行文件缺失：%@": "Service executable is missing: %@",
    "守护进程授权请求：%@": "Daemon authorization request: %@",
    "权限查询异常：%@": "Permission query failed: %@",
    "读取密码失败：%@": "Failed to read passwords: %@",
    "写入钥匙串失败：%@": "Failed to write to the Keychain: %@",
    "已保存 %d 个密码": "Saved %d password(s)",
    "保存失败": "Save Failed",
}


# 需要同时生成本地化资源，但源串已是英文/技术标识、无需翻译的，不列入。


PLACEHOLDER = "\x00ARG\x00"


def norm_placeholders(s):
    """把插值/格式占位符统一成同一个记号。

    源码里是 Swift 插值 `\(expr)`，字典里常写作 `%d`/`%@`。
    两者归一到同一记号后即可互相匹配，不必逐条手抄插值表达式。
    """
    s = re.sub(r"\\\([^)]*\)", PLACEHOLDER, s)   # \( ... )
    s = re.sub(r"%(?:\d+\$)?[@dflus]", PLACEHOLDER, s)  # %d / %@ / %1$s ...
    return s


def canon(s):
    """把多行文案的空白归一，避免因源码缩进不同而匹配不上。

    只在**查找译文时**使用；写入 .strings 的仍是原样的 key，
    这样源码里的字符串无需改动即可命中。
    """
    # 字面 "\n"（Swift 转义）与真实换行视为同一件事，
    # 否则字典里写 \n、源码里是真实换行时会匹配不上。
    t = s.replace("\\n", "\n")
    lines = [l.strip() for l in t.split("\n")]
    joined = "\n".join(l for l in lines if l)
    # 剥离首尾空行：源码常写作 "...\n\n内容"，字典里可能不带这些空行
    return norm_placeholders(joined.strip("\n"))


def swift_files():
    for name in sorted(os.listdir(APP_DIR)):
        if name.endswith(".swift") and name != "Localization.swift":
            yield os.path.join(APP_DIR, name)


# 内部诊断日志，不本地化（只在 ~/Library/Logs 里给自己排查用）
SKIP_CALLS = ("diag",)


def skipped_ranges(src):
    """返回 SKIP_CALLS 里各调用所占的字符区间。

    按括号配对找出调用范围，而不是靠字符串内容判断——
    后者容易漏判或误判。
    """
    spans = []
    for call in SKIP_CALLS:
        for m in re.finditer(r"\b" + re.escape(call) + r"\s*\(", src):
            i = m.end() - 1          # 指向 "("
            depth = 0
            j = i
            while j < len(src):
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            spans.append((m.start(), j))
    return spans


def collect_keys():
    """收集所有需要本地化的字符串。

    在"已包裹"的源码上收集——它已经是 L("...") 形式，跨行拼接也已被合并，
    因此用 canon 归一后即可作为字典键。这样与 wrap_source 的判定口径一致。
    """
    keys = set()
    for path in swift_files():
        src = open(path, encoding="utf-8").read()
        src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
        lines = [l for l in src.split("\n") if not l.strip().startswith("//")]
        src = "\n".join(lines)
        spans = skipped_ranges(src)
        # 同时支持 L("...") 与 L("""...""")，后者是多行字符串
        for m in re.finditer(r'L\("""(.*?)"""|L\("([^"]*)"', src, re.S):
            text = m.group(1) if m.group(1) is not None else m.group(2)
            if any(a <= m.start() <= b for a, b in spans):
                continue   # 内部日志，不本地化
            keys.add(canon(text))
    return keys


def write_strings():
    keys = collect_keys()
    missing = []
    for lang, table in (("en", EN),):
        d = os.path.join(STRINGS_DIR, "%s.lproj" % lang)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
            f.write("/* BLE Unlock — %s */\n\n" % lang)
            lookup = {canon(kk): vv for kk, vv in table.items()}
            for k in sorted(keys):
                v = lookup.get(canon(k))
                if v is None:
                    missing.append(k)
                    continue
                f.write('"%s" = "%s";\n\n' % (escape(k), escape(v)))
    # 中文：key 即原文，显式写出便于校对与后续调整
    d = os.path.join(STRINGS_DIR, "zh-Hans.lproj")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        f.write("/* BLE Unlock — zh-Hans（原文即键，此处为显式副本）*/\n\n")
        for k in sorted(keys):
            f.write('"%s" = "%s";\n\n' % (escape(k), escape(k)))
    return len(keys), missing


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def wrap_source():
    """把源码里的 "中文" 换成 L("中文")。

    关键：必须跳过已经被 L(...) 包裹的字符串，否则重复运行会变成 L(L(".."))。
    这里逐字符扫描而不是用正则 lookbehind——lookbehind 无法可靠跳过
    中间的空白与已有括号。
    """
    changed = 0
    for path in swift_files():
        src = open(path, encoding="utf-8").read()
        spans = skipped_ranges(src)
        out = []
        i = 0
        n = 0
        while i < len(src):
            ch = src[i]
            # 多行字符串 """ ... """ 必须整体处理，
            # 否则开头的三个引号会被当成"空字符串"，把内容切坏。
            if src.startswith('"""', i):
                close = src.find('"""', i + 3)
                if close == -1:
                    out.append(ch); i += 1; continue
                literal = src[i + 3:close]
                end = close + 2  # 指向收尾的第三个引号
                k = i - 1
                while k >= 0 and src[k] in " \t\n":
                    k -= 1
                already = (k >= 0 and src[k] == "(" and k - 1 >= 0 and src[k - 1] == "L")
                in_skip = any(a <= i <= b for a, b in spans)
                if re.search(r"[一-龥]", literal) and not already and not in_skip:
                    # 保留原样的三引号形式，只在外层包 L(...)
                    out.append('L("""' + literal + '""")')
                    n += 1
                else:
                    out.append('"""' + literal + '"""')
                i = end + 1
                continue

            if ch == '"':
                # 读取整个字符串字面量
                j = i + 1
                buf = []
                while j < len(src) and src[j] != '"':
                    if src[j] == "\\" and j + 1 < len(src):
                        buf.append(src[j]); buf.append(src[j + 1]); j += 2; continue
                    buf.append(src[j]); j += 1
                literal = "".join(buf)
                end = j  # 指向收尾引号
                # 判断是否已被 L( 包裹：向左跳过空白找 "("，再向左找 "L"
                k = i - 1
                while k >= 0 and src[k] in " \t\n":
                    k -= 1
                already = (k >= 0 and src[k] == "(" and k - 1 >= 0 and src[k - 1] == "L")
                in_skip = any(a <= i <= b for a, b in spans)
                if re.search(r"[一-龥]", literal) and not already and not in_skip:
                    out.append('L("' + literal + '")')
                    n += 1
                else:
                    out.append('"' + literal + '"')
                i = end + 1
                continue
            out.append(ch)
            i += 1
        if n:
            open(path, "w", encoding="utf-8").write("".join(out))
            print("  %-28s 替换 %d 处" % (os.path.basename(path), n))
            changed += n
    return changed


def main():
    # 顺序很重要：先把源码包成 L("...")，再据此收集键。
    # 反过来的话收集不到任何东西——源码里还没有 L(。
    print("替换源码：")
    n = wrap_source()
    print("  合计 %d 处" % n)
    print()

    keys, missing = write_strings()
    print("本地化资源：%d 个键" % keys)
    if missing:
        print()
        print("缺少英文译文 %d 条：" % len(missing))
        for m in sorted(missing, key=len, reverse=True):
            print("    %s" % m.replace("\n", "\\n")[:100])
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
