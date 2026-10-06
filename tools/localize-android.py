#!/usr/bin/env python3
"""
Android 端本地化：把 Java 里硬编码的中文字符串抽到 strings.xml，
并生成 values-en 英文资源。

- android-src/res/values/strings.xml      中文（默认）
- android-src/res/values-en/strings.xml   英文
- 源码里的 "中文" 替换为 getString(R.string.key)

注意：BleService 里 publish(...) 的文案也会走 getString —— Service 是 Context，
可以直接调用。
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "android-src")
JAVA_DIR = os.path.join(SRC, "java", "com", "bleunlock", "remote")
RES_VALUES = os.path.join(SRC, "res", "values", "strings.xml")
RES_VALUES_EN = os.path.join(SRC, "res", "values-en", "strings.xml")

# 中文原文 -> 英文
EN = {
    # 主界面
    "BLE Unlock": None,          # 保持原样，不翻译
    "点一下按钮即可解锁你的 Mac": "Tap the button to unlock your Mac",
    "尚未配置 Mac": "No Mac configured",
    "点下方「＋ 添加 Mac」开始": "Tap “＋ Add Mac” below to get started",
    "当前：": "Current: ",
    "解 锁": "UNLOCK",
    "重新连接": "Reconnect",
    "锁定 Mac": "Lock Mac",
    "搜索中…": "Searching…",
    "切换 Mac": "Switch Mac",
    "＋ 添加 Mac": "＋ Add Mac",
    "填充密码": "Fill Password",
    "（长按可更换）": "(long-press to change)",
    "每台 Mac 在安装时都会生成自己的配对令牌，": 
        "Each Mac generates its own pairing token during setup. ",
    "在 Mac 上运行 ./mac-ble-unlock.sh token 可查看。": 
        "Run ./mac-ble-unlock.sh token on the Mac to view it. ",
    "这里可以保存多台 Mac，随时切换。": "You can save multiple Macs here and switch anytime.",
    "服务尚未就绪，请稍候": "Service is not ready yet, please wait",
    "请先添加 Mac": "Please add a Mac first",
    "已填充「": "Filled “",

    # 对话框
    "选择要连接的 Mac": "Choose a Mac to connect",
    "选择要填充的密码": "Choose a password to fill",
    "管理 / 删除": "Manage / Delete",
    "取消": "Cancel",
    "管理已保存的 Mac": "Manage saved Macs",
    "返回": "Back",
    "重命名 / 修改令牌": "Rename / Change token",
    "删除": "Delete",
    "删除 ": "Delete ",
    "？": "?",
    "只从手机里移除这条配对信息，不会影响那台 Mac 本身。":
        "This only removes the pairing info from your phone; the Mac itself is unaffected.",
    "已删除": "Deleted",
    "添加 Mac": "Add Mac",
    "编辑 Mac": "Edit Mac",
    "备注名（随便起，用于区分多台 Mac）": "Label (any name, to tell Macs apart)",
    "例如：办公室 iMac": "e.g. Office iMac",
    "配对令牌（在 Mac 上运行 ./mac-ble-unlock.sh token 获取）":
        "Pairing token (run ./mac-ble-unlock.sh token on the Mac)",
    "32 字节密钥的 base64 或十六进制": "base64 or hex of the 32-byte key",
    "令牌格式不对：应为 32 字节的 base64 或 64 位十六进制":
        "Invalid token: expected base64 of 32 bytes, or 64 hex characters",
    "已添加 ": "Added ",
    "已保存": "Saved",
    "用哪个密码解锁": "Which password to use",
    "（Mac 上第 ": " (", 
    " 个）": " on the Mac)",
    "给位次起名": "Name the slots",
    "给密码位起名": "Name password slots",
    "这些名字只显示在手机上，用于区分 Mac 上保存的第几个密码。密码本身不会保存到手机。":
        "These names appear only on the phone, to tell apart the passwords saved on "
        "the Mac. The passwords themselves are never stored on the phone.",
    "Mac 上第 ": "Password #",
    " 个密码，叫：": " on the Mac is called:",
    "例如：当前密码 / 旧密码": "e.g. Current / Old",
    "解锁时将优先使用「": "Unlocking will prefer “",
    "」": "”",
    "已切换到 ": "Switched to ",
    "正在重新连接…": "Reconnecting…",
    "无法启动后台服务：": "Cannot start background service: ",
    "解锁指令已送达 Mac": "Unlock command delivered to Mac",
    "已保存（指纹 ": "Saved (fingerprint ",
    "）": ")",

    # 通知
    "蓝牙连接状态": "Bluetooth connection",
    "保持与 Mac 的蓝牙连接以便随时解锁":
        "Keeps the Bluetooth link to your Mac so you can unlock anytime",
    "BLE Unlock": None,
    "解锁 Mac": "Unlock Mac",

    # 状态
    "扫描中": "Scanning",
    "连接中": "Connecting",
    "已连接": "Connected",
    "未连接": "Disconnected",
    "指令已发送": "Command sent",
    "出错": "Error",
    "正在搜索 ": "Searching for ",
    "…": "…",
    "尚未配置任何 Mac，请先添加": "No Mac configured yet — add one first",
    "尚未配置任何 Mac": "No Mac configured",
    "已切换到 ": "Switched to ",
    "，正在连接…": ", connecting…",
    "蓝牙未开启": "Bluetooth is off",
    "无法获取蓝牙扫描器": "Cannot access the Bluetooth scanner",
    "缺少蓝牙扫描权限": "Missing Bluetooth scan permission",
    "正在连接 ": "Connecting to ",
    "缺少蓝牙连接权限": "Missing Bluetooth connect permission",
    "连接已断开": "Disconnected",
    "已连接，正在发现服务…": "Connected, discovering services…",
    "未找到目标服务，请确认 Mac 端已启动":
        "Target service not found — make sure the Mac side is running",
    "未找到指令特征": "Command characteristic not found",
    "已就绪，可以解锁": "Ready to unlock",
    "指令已送达 Mac": "Command delivered to Mac",
    "写入失败，状态码 ": "Write failed, status ",
    "写入请求被系统拒绝": "Write request rejected by the system",
    "指令已发出": "Command sent",
    "填充指令已发出": "Fill command sent",
    "发送失败: ": "Send failed: ",
    "扫描失败，错误码 ": "Scan failed, error code ",
    "尚未连接到 Mac": "Not connected to a Mac yet",
    "令牌无效，请重新填写": "Invalid token, please re-enter",
    "Mac 正在解锁…": "Mac is unlocking…",
    "Mac 正在锁定…": "Mac is locking…",
    "连接正常 (PONG)": "Connection OK (PONG)",
    "Mac 正在处理上一条指令": "Mac is still processing the previous command",
    "Mac 屏幕当前未锁定": "The Mac screen is not locked right now",
    "Mac 缺少「辅助功能」权限": "Mac lacks Accessibility permission",
    "Mac 钥匙串中没有密码": "No password in the Mac Keychain",
    "Mac 上保存的密码都不对，请检查": "None of the saved passwords worked — please check",
    "指定的密码序号 Mac 上不存在": "That password slot does not exist on the Mac",
    "配对密钥错误": "Wrong pairing key",
    "指令被拒绝（重放）": "Command rejected (replay)",
    "手机与 Mac 时间相差过大，请校准时间":
        "Phone and Mac clocks differ too much — please sync time",
    "Mac: ": "Mac: ",
    "✅ Mac 已解锁": "✅ Mac unlocked",
    "没有蓝牙权限就无法连接 Mac": "Without Bluetooth permission the Mac cannot be reached",
    # ---- 拼接片段与遗漏项 ----
    "   （Mac 上第 ": "   (password #",
    " 的令牌无效": " has an invalid token",
    "保存": "Save",
    "填充密码：": "Fill: ",
    "密码 ": "Password ",
    "密码本身不会保存到手机。": "The passwords themselves are never stored on the phone.",
    "这些名字只显示在手机上，用于区分 Mac 上保存的第几个密码。":
        "These names appear only on the phone, to tell apart the passwords saved on the Mac.",
    "已连接，开始发现服务": "Connected, discovering services",
    "我的 Mac": "My Mac",
    "未命名": "Unnamed",
    "未命名 (": "Unnamed (",
    "还没有保存任何 Mac": "No Mac saved yet",
    "配对密钥必须是 32 字节": "Pairing key must be 32 bytes",
    "Mac 状态: ": "Mac status: ",
    "令牌无效": "Invalid token",
    "发送失败": "Send failed",
    "发现目标设备 ": "Found target device ",
    "扫描失败 code=": "Scan failed code=",
    "连接断开 status=": "Disconnected status=",
}

# 不参与本地化的技术性字符串
SKIP = {"BLEUnlock", "BLEUnlockCmd"}


def canon(s):
    return re.sub(r"\s+", " ", s).strip()


def xml_escape(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
             .replace('"', "&quot;").replace("'", "\\'"))


def key_for(zh):
    """用序号生成稳定的 key，避免中文做 key 带来的转义与可读性问题"""
    return None  # 由调用方按索引生成


# 内部日志，不本地化（只在 logcat 里给自己排查用）
SKIP_CALLS = ("Log.d", "Log.i", "Log.w", "Log.e", "Log.v")


def skipped_ranges(src):
    """按括号配对求出各日志调用所占的字符区间"""
    spans = []
    for call in SKIP_CALLS:
        for m in re.finditer(re.escape(call) + r"\s*\(", src):
            i = m.end() - 1
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


# 不走资源文件的类：
#   Protocol.java      —— 纯静态工具类，异常信息面向开发者，保持英文
#   MacEntryStore.java —— 存储层 POJO，默认名由 UI 层传入本地化后的值
SKIP_FILES = {"Protocol.java"}


def collect():
    """收集所有中文字符串字面量（排除日志与 SKIP_FILES）"""
    found = {}
    for name in sorted(os.listdir(JAVA_DIR)):
        if not name.endswith(".java") or name in SKIP_FILES:
            continue
        path = os.path.join(JAVA_DIR, name)
        src = open(path, encoding="utf-8").read()
        src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
        lines = [l for l in src.split("\n")
                 if not l.strip().startswith("//") and not l.strip().startswith("*")]
        body = "\n".join(lines)
        spans = skipped_ranges(body)
        for m in re.finditer(r'"([^"\\]*[一-龥][^"\\]*)"', body):
            if any(a <= m.start() <= b for a, b in spans):
                continue   # 日志，不本地化
            found.setdefault(m.group(1), 0)
            found[m.group(1)] += 1
    return found


def main():
    found = collect()
    unknown = [k for k in found if k not in EN]
    if unknown:
        print("以下字符串没有英文译文（%d 条）：" % len(unknown))
        for k in sorted(unknown):
            print("   %r" % k)
        return 1
    print("待本地化字符串：%d 条" % len(found))

    # 生成 key：按出现顺序编号，稳定且与语言无关
    keys = {}
    entries = []
    for i, zh in enumerate(sorted(found), start=1):
        k = "s%d" % i
        keys[zh] = k
        entries.append((k, zh, EN[zh]))
    print("生成 key：%d 个" % len(keys))

    # 写 values/strings.xml（中文）
    os.makedirs(os.path.dirname(RES_VALUES), exist_ok=True)
    with open(RES_VALUES, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n')
        f.write('    <string name="app_name">BLE Unlock</string>\n')
        f.write('    <string name="channel_name">蓝牙连接状态</string>\n')
        f.write('    <string name="channel_desc">保持与 Mac 的蓝牙连接以便随时解锁</string>\n')
        for k, zh, en in entries:
            f.write('    <string name="%s">%s</string>\n' % (k, xml_escape(zh)))
        f.write("</resources>\n")

    # 写 values-en/strings.xml
    os.makedirs(os.path.dirname(RES_VALUES_EN), exist_ok=True)
    with open(RES_VALUES_EN, "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="utf-8"?>\n<resources>\n')
        f.write('    <string name="channel_name">Bluetooth connection</string>\n')
        f.write('    <string name="channel_desc">Keeps the Bluetooth link to your Mac '
                'so you can unlock anytime</string>\n')
        for k, zh, en in entries:
            if en is None:
                continue
            f.write('    <string name="%s">%s</string>\n' % (k, xml_escape(en)))
        f.write("</resources>\n")

    # 替换源码
    total = 0
    for name in sorted(os.listdir(JAVA_DIR)):
        if not name.endswith(".java") or name in SKIP_FILES:
            continue
        path = os.path.join(JAVA_DIR, name)
        src = open(path, encoding="utf-8").read()
        n = 0
        for zh, k in keys.items():
            # 只替换独立的字符串字面量
            lit = '"%s"' % zh
            if lit in src:
                cnt = src.count(lit)
                src = src.replace(lit, 'getString(R.string.%s)' % k)
                n += cnt
        if n:
            open(path, "w", encoding="utf-8").write(src)
            print("  %-18s 替换 %d 处" % (name, n))
            total += n
    print("合计替换 %d 处" % total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
