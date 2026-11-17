// BLEUnlockCmd — Mac BLE 解锁服务端
//
// 作用：作为 BLE 外设(GATT Server)广播，手机 App 连接后写入一条带 HMAC-SHA256 签名的
//       指令；校验通过则调用与 BLEUnlock 相同的机制自动输入登录密码来解锁屏幕。
//
// 编译：swiftc -O main.swift -o BLEUnlockCmd
// 依赖：CoreBluetooth / CryptoKit / CoreGraphics / IOKit（全部为系统框架）

import Foundation
import AppKit
import CoreBluetooth
import CryptoKit
import CoreGraphics
import Darwin
import IOKit.pwr_mgt
import ApplicationServices

// MARK: - 协议常量（必须与 Android 端一致）

let kServiceUUID        = CBUUID(string: "B1E0A100-0001-4A00-8000-00805F9B0001")
let kCharCommandUUID    = CBUUID(string: "B1E0A100-0002-4A00-8000-00805F9B0002")
let kCharStatusUUID     = CBUUID(string: "B1E0A100-0003-4A00-8000-00805F9B0003")
let kCharInfoUUID       = CBUUID(string: "B1E0A100-0004-4A00-8000-00805F9B0004")

let kMagic: [UInt8] = [0x42, 0x55]          // "BU"
let kVersion: UInt8 = 0x01
let kCmdUnlock: UInt8 = 0x01
let kCmdLock: UInt8 = 0x02
let kCmdPing: UInt8 = 0x03
/// 指定用第几个密码解锁（手机端选择"填充哪个密码"）
let kCmdUnlockFrom: UInt8 = 0x04

let kPacketLen  = 62                        // 2 magic + 1 ver + 1 cmd + 8 ts + 16 nonce + 32 hmac
let kHmacOffset = 30                        // HMAC 覆盖前 30 字节
/// 字节 28：密码序号（0 基）。仅 kCmdUnlockFrom 使用；位于 HMAC 覆盖范围内，长度不变。
let kIndexOffset = 28
/// 字节 29：是否跳过"锁屏校验"。
///
/// 手机端「填充密码」是人工明确下达的指令，不需要再判断屏幕是否处于锁定状态——
/// 用户就是要现在把这些字符送进去。置 1 时 Mac 会直接注入，不因未锁屏而中止。
/// 同样位于 HMAC 覆盖范围内。
let kForceOffset = 29

let kTimestampSkew: Int64 = 120             // 允许的时钟偏差（秒）
let kNonceCacheLimit = 512

// MARK: - 运行环境路径
//
// 默认使用 ~/Library/Application Support/BLEUnlockCmd。
// 环境变量 BLEUNLOCK_APP_SUPPORT 可覆盖该目录（测试/沙箱环境用）。

let kAppSupport: String = {
    if let override = ProcessInfo.processInfo.environment["BLEUNLOCK_APP_SUPPORT"],
       !override.isEmpty {
        return override
    }
    return ("~/Library/Application Support/BLEUnlockCmd" as NSString).expandingTildeInPath
}()
let kConfigPath = kAppSupport + "/config.json"
let kLogPath    = kAppSupport + "/ble-unlock.log"
/// 钥匙串服务名。可用环境变量覆盖，便于自动化测试用独立条目验证。
let kKeychainService: String = {
    if let o = ProcessInfo.processInfo.environment["BLEUNLOCK_KEYCHAIN_SERVICE"], !o.isEmpty {
        return o
    }
    return "ble-unlock-cmd"
}()
/// 守护进程把自己的 TCC 权限状态写在这里，供设置向导读取。
///
/// 为什么不直接问进程：TCC 的 AX 信任会从父进程继承。设置向导从 Finder/终端
/// 启动时本身是受信任的，它 fork 出来的子进程也会报告「已授权」——
/// 但真正干活的守护进程由 launchd 启动，不受此信任，实际是未授权。
/// 因此必须让守护进程自己把判定结果落盘。
let kStatusPath = kAppSupport + "/daemon-status.json"
/// 外部请求刷新权限状态的信号文件（设置向导在用户授权后写入）
let kRefreshRequestPath = kAppSupport + "/refresh.request"

/// 日志文件是否可用（目录不可写时退化为只输出到 stderr）
let kLogFileWritable: Bool = {
    FileManager.default.createFile(atPath: kLogPath, contents: nil,
                                   attributes: [.posixPermissions: 0o600])
    return FileManager.default.isWritableFile(atPath: kLogPath)
}()

// MARK: - 日志

/// 日志时间戳精确到毫秒：连接/广播是秒级甚至百毫秒级的事，
/// 只有整秒精度无法判断「唤醒→广播恢复」到底花了多久。
let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// 日志会同时来自 CoreBluetooth 回调队列（主队列）与解锁专用队列，
/// 加锁保证一行日志不会被另一次写入截断（tail/log show 解析时更可靠）。
let logLock = NSLock()

/// daemon-status.json 的写入串行锁：现在既会从主队列（刷新定时器 / 启动）写，
/// 也会从 unlockQueue（解锁开始时）写；原子写 + 串行化避免设置向导读到半截 JSON。
let daemonStatusLock = NSLock()

/// 记录守护进程自身的 TCC 权限状态，供设置向导判断"真正干活的进程"能否输入。
func writeDaemonStatus() {
    let trusted = accessibilityGranted()
    let payload: [String: Any] = [
        "pid": Int(getpid()),
        "axTrusted": trusted,
        "updatedAt": ISO8601DateFormatter().string(from: Date()),
        "bundlePath": Bundle.main.bundlePath,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
        // .atomic：先写临时文件再 rename，读取方（设置向导）不会看到半截内容。
        daemonStatusLock.lock()
        defer { daemonStatusLock.unlock() }
        do {
            try data.write(to: URL(fileURLWithPath: kStatusPath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: kStatusPath)
        } catch {
            log("[状态] 写入 daemon-status.json 失败：\(error.localizedDescription)")
        }
    }
    log("守护进程权限自检：AXIsProcessTrusted = \(trusted)")
    if !trusted {
        log("  ⚠️ 本进程无法模拟键盘输入，解锁会失败。")
        log("     请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 BLEUnlockCmd；")
        log("     若开关已是打开状态，请先删除该项再重新添加（旧授权可能绑定到旧版本）。")
    }
}

func log(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if kLogFileWritable, let handle = FileHandle(forWritingAtPath: kLogPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    }
}

// MARK: - 配置

struct Config: Codable {
    var hmacKey: String          // base64 编码的 32 字节预共享密钥
    var keychainAccount: String  // 登录密码所在的钥匙串账户名
    var deviceName: String       // 广播出去的设备名
}

func loadConfig() -> Config? {
    guard let data = FileManager.default.contents(atPath: kConfigPath) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: data)
}

func ensureSupportDirectory() {
    try? FileManager.default.createDirectory(atPath: kAppSupport,
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
}

// MARK: - 密码读取（keychain）

/// 把结果按 JSON 输出，便于设置向导解析（避免两端各写一套逻辑）
func printJSON(_ payload: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

// MARK: - 多密码存储
//
// 每台设备可以保存多个登录密码（例如刚改过密码、或同时用多个账户）。
// 解锁时按顺序逐个尝试，直到屏幕解开为止。
//
// 存储格式：钥匙串里放一个 JSON 数组。这样单个条目就能装下全部密码，
// 也天然兼容"只有一个密码"的旧格式——读取时若解析失败就当作单个明文密码。

/// 读取全部密码。顺序即尝试顺序。
func fetchPasswords(account: String) -> [String] {
    guard let raw = readKeychainPassword(account: account) else { return [] }

    // 新格式：JSON 数组。
    // 注意：只要解析成功就以它为准，即使结果是空数组——
    // 否则「[]」会被当成一个两字符的密码（曾踩过这个坑）。
    if let data = raw.data(using: .utf8),
       let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
        return arr.filter { !$0.isEmpty }.map(normalizePassword)
    }

    // 旧格式：单个明文密码
    return raw.isEmpty ? [] : [normalizePassword(raw)]
}

/// 写回全部密码。始终写 JSON 数组，便于日后增删。
@discardableResult
func storePasswords(_ passwords: [String], account: String) -> Bool {
    let list = passwords.filter { !$0.isEmpty }.map(normalizePassword)
    guard let data = try? JSONSerialization.data(withJSONObject: list, options: []),
          let json = String(data: data, encoding: .utf8) else {
        log("密码序列化失败")
        return false
    }
    return writeKeychainPassword(json, account: account)
}

/// 是否要求跳过锁屏校验（字节 29 非 0）
func extractForceFlag(_ bytes: [UInt8]) -> Bool {
    guard bytes.count > kForceOffset, bytes[3] == kCmdUnlockFrom else { return false }
    return bytes[kForceOffset] != 0
}

/// 从报文中取出密码序号。
///
/// 只有「指定密码解锁」（kCmdUnlockFrom）会用到字节 28。
/// 其他指令该字节为 0，这里返回 nil，避免被误当成"第 0 个密码"。
func extractPasswordIndex(_ bytes: [UInt8]) -> UInt8? {
    guard bytes.count > kIndexOffset, bytes[3] == kCmdUnlockFrom else { return nil }
    return bytes[kIndexOffset]
}

/// 把第 index 个密码提到最前面，其余保持相对顺序。
/// 序号越界时原样返回，不抛错——调用方据此回退到默认顺序。
func promotePassword(_ list: [String], toFront index: Int) -> [String] {
    guard index > 0, index < list.count else { return list }
    var out = list
    let picked = out.remove(at: index)
    out.insert(picked, at: 0)
    return out
}

/// 兼容旧接口：返回第一个密码
func fetchPassword(account: String) -> String? {
    fetchPasswords(account: account).first
}

func readKeychainPassword(account: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = ["find-generic-password",
                         "-a", account,
                         "-s", kKeychainService,
                         "-w"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        log("无法执行 security 命令: \(error)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    var pw = String(data: data, encoding: .utf8) ?? ""
    // security -w 会附带一个换行
    while pw.hasSuffix("\n") || pw.hasSuffix("\r") { pw.removeLast() }
    guard !pw.isEmpty else { return nil }
    return decodeHexIfNeeded(pw)
}

/// `security -w` 对**非 ASCII** 的密码会输出十六进制串而不是原文
/// （例如「中文密码」会读成 "e4b8ade69687e5af86e7a081"）。
/// 这里把它还原。
///
/// 判定条件刻意保守，避免误伤"本来就是十六进制"的 ASCII 密码：
/// 只有整串是合法十六进制、长度为偶数，**且解码后含非 ASCII 字符**时才还原。
/// 纯 ASCII 的密码解码后仍是 ASCII，因此不会被误改。
func decodeHexIfNeeded(_ value: String) -> String {
    let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
    guard value.count >= 2, value.count % 2 == 0,
          value.unicodeScalars.allSatisfy({ hexDigits.contains($0) }) else {
        return value
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(value.count / 2)
    var idx = value.startIndex
    while idx < value.endIndex {
        let next = value.index(idx, offsetBy: 2)
        guard let byte = UInt8(value[idx..<next], radix: 16) else { return value }
        bytes.append(byte)
        idx = next
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8) else { return value }
    // 只有解码结果含非 ASCII 时才认定是 hex 编码；
    // 否则保留原文，避免把形如 "deadbeef" 的密码改掉。
    guard decoded.unicodeScalars.contains(where: { $0.value > 127 }) else { return value }
    log("钥匙串返回的是十六进制编码，已还原为原文（\(value.count) → \(decoded.count) 字符）")
    return decoded
}

/// 统一规范化形式。
///
/// macOS 钥匙串会把非 ASCII 字符存成 NFD（分解式，é = e + 组合重音），
/// 而输入往往是 NFC（预组合）。两种形式渲染相同、NFC 归一后相等，
/// 但码点不同会让字符串比较出现假失败。这里统一成 NFC，让存取确定。
func normalizePassword(_ s: String) -> String {
    s.precomposedStringWithCanonicalMapping
}

/// 用 security 命令写入钥匙串（-U 表示存在则原地更新）
func writeKeychainPassword(_ value: String, account: String) -> Bool {
    let r = runProcess("/usr/bin/security",
                       ["add-generic-password", "-U",
                        "-a", account,
                        "-s", kKeychainService,
                        "-l", "BLEUnlockCmd",
                        "-w", value])
    if r.code != 0 {
        let detail = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        log("写入钥匙串失败：退出码 \(r.code)" + (detail.isEmpty ? "" : "：\(detail)"))
        return false
    }
    return true
}

/// 执行外部命令并同时返回 stderr，便于诊断
func runProcess(_ path: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do { try p.run() } catch {
        return (-1, "", error.localizedDescription)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

// MARK: - 屏幕状态 / 显示器控制

func isScreenLocked() -> Bool {
    // 公开 API：CGSessionCopyCurrentDictionary（Quartz 私有但被广泛使用的 session 字典）
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Int { return locked == 1 }
    if let locked = dict["CGSSessionScreenIsLocked"] as? Bool { return locked }
    return false
}

var displayAssertionID = IOPMAssertionID(0)

func wakeDisplay() {
    IOPMAssertionDeclareUserActivity("BLEUnlockCmd" as CFString, kIOPMUserActiveLocal, &displayAssertionID)
}

func sleepDisplay() {
    // IORegistryEntryFromPath 需要 C 字符串路径
    let entry = IORegistryEntryFromPath(kIOMasterPortDefault,
                                        "IOService:/IOResources/IODisplayWrangler")
    if entry != 0 {
        IORegistryEntrySetCFProperty(entry, "IORequestIdle" as CFString, kCFBooleanTrue)
        IOObjectRelease(entry)
    }
}

// MARK: - 全局开关

/// 安全测试模式：完整走一遍 BLE 收包与校验，但不真的注入密码
var dryRun = false

// MARK: - 键盘事件注入（解锁的核心）

/// 发送一个单独的按键（用虚拟键码），例如 Esc 用来清空密码输入框
func sendKey(_ virtualKey: CGKeyCode) {
    if dryRun { return }
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)?
        .post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)?
        .post(tap: .cghidEventTap)
}

func fakeKeyStrokes(_ string: String) {
    if dryRun {
        log("[dry-run] 本应注入 \(string.count) 个字符的密码并回车，已跳过")
        return
    }
    guard let source = CGEventSource(stateID: .hidSystemState) else {
        log("无法创建 CGEventSource")
        return
    }
    let units = Array(string.utf16)
    let perChunk = 20   // 单个键盘事件最多携带 20 个 UTF-16 字符

    var index = 0
    while index < units.count {
        let count = min(perChunk, units.count - index)
        var buffer = Array(units[index ..< index + count])

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true) else { break }
        down.keyboardSetUnicodeString(stringLength: count, unicodeString: &buffer)
        down.post(tap: .cghidEventTap)

        CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)?
            .post(tap: .cghidEventTap)
        index += count
    }

    // 回车键（virtualKey 52 = Return）
    CGEvent(keyboardEventSource: source, virtualKey: 52, keyDown: true)?
        .post(tap: .cghidEventTap)
    CGEvent(keyboardEventSource: source, virtualKey: 52, keyDown: false)?
        .post(tap: .cghidEventTap)
}

func accessibilityGranted(prompt: Bool = false) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}

// MARK: - 解锁 / 锁定

/// 解锁/锁定专用的串行队列。
///
/// BLE 回调跑在主队列（`CBPeripheralManager(delegate:queue:)` 传 nil 即主队列），
/// 而解锁流程里有 fork/exec（`/usr/bin/security`）、`Thread.sleep`、`dlopen` 等阻塞操作。
/// 直接在回调里同步执行会堵住 `didReceiveWrite` / `didSubscribeTo` / 状态通知，
/// 手机端表现为「已经连上，却迟迟等不到响应/确认」——这是连接慢的主要放大器之一。
///
/// 所有指令处理都放到这个串行队列：既离开主队列，又保持指令串行执行，
/// `unlockInFlight` 仍是单线程语义，无需额外加锁。
let unlockQueue = DispatchQueue(label: "jp.sone.bleunlockcmd.unlock", qos: .userInitiated)

var unlockInFlight = false

/// 自动解锁：唤醒屏幕 -> 确认处于锁屏 -> 注入密码
/// - Parameters:
///   - preferredIndex: 优先尝试第几个密码（0 基）。为 nil 时按保存顺序。
///     手机端可以指定"用哪个密码解锁"；若指定的序号越界或该密码不对，
///     会自动回退到按原顺序继续尝试其余密码。
///   - force: 跳过"锁屏校验"。
///     手机端「填充密码」是人工明确下达的指令——用户就是要现在把字符送进去，
///     不需要（也不应该）再判断屏幕是否处于锁定状态。为 true 时直接注入，
///     不等待锁屏、不轮询唤醒。
func performUnlock(preferredIndex: UInt8? = nil,
                   force: Bool = false,
                   reply: @escaping (String) -> Void) {
    // 本函数只应在 unlockQueue 上执行（BLE 指令统一由 PeripheralServer 转过来）。
    // 下面的 fork/exec（读钥匙串）、Thread.sleep、dlopen 都不会占用 CB 回调队列。
    log("[UNLOCK] 处理解锁请求（force=\(force)，preferredIndex=\(preferredIndex.map { String($0) } ?? "无")）")
    guard !unlockInFlight else {
        log("[UNLOCK] 拒绝：上一次解锁尚未结束")
        reply("BUSY")
        return
    }
    // dry-run 下不检查辅助功能权限，因为不会真的注入事件
    guard dryRun || accessibilityGranted() else {
        log("解锁失败：缺少「辅助功能」权限")
        reply("ERR_NO_AX")
        return
    }
    guard let config = loadConfig() else {
        log("解锁失败：配置缺失")
        reply("ERR_CONFIG")
        return
    }

    let saved = fetchPasswords(account: config.keychainAccount)
    guard !saved.isEmpty else {
        log("解锁失败：钥匙串中读不到密码")
        reply("ERR_NO_PW")
        return
    }

    // 手机可以指定优先用哪个密码：把该密码提到最前面，
    // 其余保持原顺序作为回退——这样指定的密码不对时仍能自动试到对的。
    var passwords = saved
    if let idx = preferredIndex {
        let i = Int(idx)
        if i >= 0 && i < saved.count {
            passwords = promotePassword(saved, toFront: i)
            log("手机指定优先使用第 \(i + 1) 个密码（共 \(saved.count) 个）")
        } else {
            log("手机指定的密码序号 \(i + 1) 越界（共 \(saved.count) 个），按默认顺序尝试")
        }
    }

    if dryRun {
        log("[dry-run] 校验通过，共 \(passwords.count) 个密码，本应逐个尝试"
            + (force ? "（强制填充，跳过锁屏校验）" : ""))
        reply("OK")
        return
    }

    unlockInFlight = true
    writeDaemonStatus()

    if force {
        // 强制填充：不判断是否锁屏，直接把选中的密码注入并回车。
        // 这条路径只做一次，不逐个回退——人工指定用哪个就用哪个。
        //
        // 注意：force 可能不带序号（手机只要求"跳过校验"），
        // 此时 passwords[0] 就是保存顺序里的第一个，即默认密码。
        let chosen = passwords[0]
        log("[UNLOCK] 收到强制填充指令（跳过锁屏校验，共 \(passwords.count) 个密码）")
        // 屏幕若在息屏状态，输入框收不到按键，因此仍先点亮屏幕
        wakeDisplay()
        unlockQueue.asyncAfter(deadline: .now() + 0.35) {
            log("[UNLOCK] 注入 \(chosen.count) 个字符并回车")
            fakeKeyStrokes(chosen)
            unlockInFlight = false
            reply("OK")
        }
        return
    }

    log("[UNLOCK] 开始执行（\(passwords.count) 个密码待尝试）")

    wakeDisplay()

    // 显示器唤醒后需要一点时间才真正点亮，重试几轮
    var wakeAttempt = 0
    let maxWakeAttempts = 8
    /// 每个密码注入后，等待多久再判断是否解锁成功
    let settleDelay = 1.2

    /// 解锁成功收尾
    func succeeded(after tried: Int) {
        unlockInFlight = false
        if tried == 0 {
            log("[UNLOCK] 完成：已注入密码并回车")
        } else {
            log("[UNLOCK] 完成：第 \(tried + 1) 个密码生效")
        }
        reply("OK")
    }

    /// 依次尝试每个密码；全部失败则回报
    func tryPassword(at index: Int) {
        guard index < passwords.count else {
            unlockInFlight = false
            log("[UNLOCK] 失败：已尝试全部 \(passwords.count) 个密码，屏幕仍未解锁")
            reply("ERR_ALL_PW")
            return
        }

        let isLast = (index == passwords.count - 1)
        log("注入第 \(index + 1)/\(passwords.count) 个密码（\(passwords[index].count) 字符）")

        // 尝试前先清空输入框：上一个密码若错误，字段里可能残留内容。
        // 用 Esc 清空比逐字符删除可靠。
        //
        // 这里的阻塞式 sleep 只占用 unlockQueue（专用串行队列），
        // 不会阻塞 CoreBluetooth 回调队列；保留它可维持原有的注入节奏。
        if index > 0 {
            sendKey(0x35)   // Esc
            Thread.sleep(forTimeInterval: 0.25)
        }

        fakeKeyStrokes(passwords[index])

        unlockQueue.asyncAfter(deadline: .now() + settleDelay) {
            if !isScreenLocked() {
                succeeded(after: index)
            } else {
                if !isLast { log("  该密码无效，继续尝试下一个") }
                tryPassword(at: index + 1)
            }
        }
    }

    func tick() {
        wakeAttempt += 1
        wakeDisplay()

        if isScreenLocked() {
            // 再等 0.4s 让密码输入框获得焦点
            unlockQueue.asyncAfter(deadline: .now() + 0.4) {
                tryPassword(at: 0)
            }
            return
        }

        if wakeAttempt >= maxWakeAttempts {
            unlockInFlight = false
            log("[UNLOCK] 中止：屏幕未处于锁定状态（可能已由用户手动解锁）")
            reply("NOT_LOCKED")
            return
        }
        unlockQueue.asyncAfter(deadline: .now() + 0.5, execute: tick)
    }

    tick()
}

func performLock(reply: @escaping (String) -> Void) {
    if dryRun {
        log("[dry-run] 本应锁定屏幕，已跳过")
        reply("OK")
        return
    }
    // 与 performUnlock 一样，本函数只在 unlockQueue 上执行：
    // dlopen/SACLockScreenImmediate 首次加载可能有几十毫秒，不能拖住 CB 回调。
    log("[LOCK] 开始执行锁定")
    // 通过锁屏私有 API 锁定；若不可用则退回屏保
    let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
    if let handle = handle, let sym = dlsym(handle, "SACLockScreenImmediate") {
        typealias LockFn = @convention(c) () -> Int32
        let lock = unsafeBitCast(sym, to: LockFn.self)
        let result = lock()
        dlclose(handle)
        log("[LOCK] SACLockScreenImmediate 返回 \(result)")
        reply(result == 0 ? "OK" : "ERR_LOCK")
    } else {
        log("[LOCK] login.framework 不可用，改用屏保锁定")
        Process.launchedProcess(launchPath: "/usr/bin/open",
                                arguments: ["-a", "ScreenSaverEngine"])
        reply("OK_SS")
    }
    sleepDisplay()
}

// MARK: - 防重放

final class NonceCache {
    private var seen: [String: Date] = [:]
    private let lock = NSLock()

    /// 返回 true 表示该 nonce 是新的（未被重放）
    func accept(_ nonce: Data) -> Bool {
        let key = nonce.base64EncodedString()
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 300 }
        if seen[key] != nil { return false }
        if seen.count >= kNonceCacheLimit {
            if let oldest = seen.min(by: { $0.value < $1.value })?.key { seen.removeValue(forKey: oldest) }
        }
        seen[key] = now
        return true
    }
}

let nonceCache = NonceCache()

// MARK: - 数据包校验

enum VerifyResult {
    /// command 指令；index 为字节 28 的密码序号；force 为字节 29 的跳过锁屏校验标志
    case ok(command: UInt8, index: UInt8?, force: Bool)
    case failed(String)
}

func verifyPacket(_ data: Data, key: SymmetricKey) -> VerifyResult {
    guard data.count >= kPacketLen else { return .failed("ERR_LEN") }
    let bytes = [UInt8](data)

    guard bytes[0] == kMagic[0], bytes[1] == kMagic[1] else { return .failed("ERR_MAGIC") }
    guard bytes[2] == kVersion else { return .failed("ERR_VER") }

    let now = Int64(Date().timeIntervalSince1970)
    var ts: Int64 = 0
    for i in 0..<8 { ts = (ts << 8) | Int64(bytes[4 + i]) }
    guard abs(now - ts) <= kTimestampSkew else { return .failed("ERR_TIME") }

    let nonce = Data(bytes[12..<28])
    guard nonceCache.accept(nonce) else { return .failed("ERR_REPLAY") }

    let message = Data(bytes[0..<kHmacOffset])
    let expected = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    let received = Data(bytes[kHmacOffset..<kPacketLen])
    // 常量时间比较
    guard expected.count == received.count else { return .failed("ERR_HMAC") }
    var diff: UInt8 = 0
    for i in 0..<expected.count { diff |= expected[i] ^ received[i] }
    guard diff == 0 else { return .failed("ERR_HMAC") }

    return .ok(command: bytes[3],
               index: extractPasswordIndex(bytes),
               force: extractForceFlag(bytes))
}

// MARK: - BLE 外设

final class PeripheralServer: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager!
    private var commandChar: CBMutableCharacteristic!
    private var statusChar: CBMutableCharacteristic!
    private var key: SymmetricKey!
    private var deviceName: String = "BLEUnlock-Mac"
    private var advertiseTimer: Timer?
    private var statusValue = "READY"

    // MARK: 广播生命周期状态（全部只在 CoreBluetooth 回调队列 / 主队列上读写）

    /// GATT 服务是否已被 didAdd 确认注册成功。**只有为 true 才允许广播。**
    private var serviceBuilt = false
    /// add(service) 已提交、didAdd 尚未回调；用于防止重复 add。
    private var serviceAddPending = false
    /// 提交 add(service) 的时刻。didAdd 迟迟不来（系统刚唤醒时可能丢回调）时用它超时重试。
    private var serviceAddStartedAt: Date?
    /// 服务注册连续失败次数（didAdd 报错，或超过 2 s 没等到 didAdd）。
    /// 达到上限后重建 CBPeripheralManager：唤醒后 CoreBluetooth 偶发彻底不再回调 didAdd，
    /// 只重复 add/remove 会变成「永不广播 + 每 2.5 s 无限重建」。
    private var serviceAddFailCount = 0
    /// 广播失败后的降级标志：去掉 localName，只保留 service UUID。
    private var reducedAdvertising = false
    private var advertisingStartCount = 0
    private var advertisingFailCount = 0
    /// 最近一次 startAdvertising 的时刻，用于计算「开始广播 → 手机连上」的耗时。
    private var lastAdvertisingStartedAt: Date?
    /// 已订阅（即已连接）的手机。用于判断唤醒时能否安全地重建 GATT 数据库。
    private var subscribedCentrals: Set<UUID> = []
    private var pendingStatus: String?

    // MARK: 「假在线」兜底状态（主队列）

    /// 最近一次手机侧活动（订阅 / 读 / 写 / 取消订阅）的时刻。
    /// t9 已证明 CoreBluetooth 会返回 didStartAdvertising 成功、isAdvertising=true，
    /// 但 controller 层可能根本没有广播；此时唯一能观察到的“活着”迹象就是手机侧活动。
    private var lastCentralActivity = Date()
    /// idle 强制 re-arm 的定时器（5 s tick）。
    private var idleRearmTimer: Timer?
    /// 最近一次强制 re-arm 的时刻，保证两次 re-arm 至少间隔 20 s。
    private var lastRearmAt: Date?
    /// 连续 re-arm 次数（期间没有任何手机活动）。≥2 且最近一次广播后仍长时间无活动时，
    /// 才判定 controller“假在线”并升级为移除服务重建。
    private var consecutiveRearms = 0
    /// 广播操作串行闸门：stop → 延迟 start / 深度重建期间置位，
    /// 避免 watchdog、2.5 s 健康检查、唤醒重建在同一窗口里互相打断。
    private var advertisingOperationUntil: Date?
    /// 深度重建后的冷却期：避免「一直没人连」时每 40 s 就 removeAllServices 一次
    /// （反复重建 GATT 数据库会让手机侧缓存反复失效，得不偿失）。
    private var deepRebuildCooldownUntil: Date?
    /// 深度重建的指数退避档位：60 s → 5 min → 30 min。只有「确实像 controller 卡死」
    /// 时才会升级重建，升级一次后退避档 +1，避免正常无人使用时周期性重建污染测量。
    private var deepRebuildBackoffIndex = 0
    /// 已完成的深度重建次数（日志/状态用）。
    private var deepRebuildCount = 0
    /// 待办：深度重建（闸门忙时登记，闸门释放后重试，不得静默丢弃）。
    private var pendingDeepRebuild = false
    private var pendingDeepRebuildReason: String?
    /// 深度重建的静默确认时刻：最后一次 CB 回调后至少 3 s 才 removeAllServices，
    /// 覆盖「链路已建立、但服务发现/订阅还没完成」这段对代码不可见的窗口。
    private var deepRebuildConfirmAt: Date?
    /// 待办：轻量重建广播（闸门忙时登记）。
    private var pendingRestartReason: String?
    /// 待办：确保广播（闸门忙时登记）。
    private var pendingEnsureReason: String?
    /// 待办：强制 re-arm（闸门忙时登记；必须在闸门释放后真正重跑 forceRearm，
    /// 因为 isAdvertising 可能是假 true，走 ensureAdvertising 会被它挡住）。
    private var pendingRearmReason: String?
    /// 待办刷新是否已排期 / 已重试次数（防止无界重试）。
    private var pendingFlushScheduled = false
    private var pendingFlushAttempts = 0
    /// 连续 startAdvertising 成功次数：降级载荷后连续 2 次成功即恢复完整载荷。
    private var advertisingSuccessStreak = 0
    /// 健康检查日志去抖：只在「广播是否在跑」翻转时写，避免重建循环时每 2.5 s 刷屏。
    private var lastHealthAdvertisingOK: Bool?

    func start(key: SymmetricKey, deviceName: String) {
        self.key = key
        self.deviceName = deviceName
        log("[BLE] 守护进程启动：创建 CBPeripheralManager（回调队列=主队列），就绪后立即注册服务并广播")
        manager = CBPeripheralManager(delegate: self, queue: nil)

        // 启动自检：即使 poweredOn 回调因系统刚唤醒而迟到/丢失，
        // 500 ms 后也会再确认一次广播状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.ensureAdvertising(reason: "启动自检")
        }
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:    return "poweredOn"
        case .poweredOff:   return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported:  return "unsupported"
        case .resetting:    return "resetting"
        case .unknown:      return "unknown"
        @unknown default:   return "unknown(\(state.rawValue))"
        }
    }

    // MARK: 广播时序：addService → didAdd 成功 → startAdvertising

    /// 确保（在服务就绪的前提下）处于广播状态。可从任意主队列回调/定时器调用。
    func ensureAdvertising(reason: String) {
        guard manager != nil else { return }
        guard manager.state == .poweredOn else {
            log("[ADV] 暂不广播（\(reason)）：蓝牙状态=\(stateName(manager.state))")
            return
        }
        // 串行闸门：watchdog / 2.5 s 健康检查 / 唤醒重建正在 stop→start 时，
        // 不再插入新的广播操作，避免重复 start/stop 互相打断。
        // 注意：这里必须“登记待办 + 重试”，不能只 return——上一版就是自己安排的
        // 延迟回调被自己的闸门挡掉且不重试，导致取消订阅/唤醒后出现 1.3–3.5 s 盲区（t11 F1）。
        guard !advertisingOperationInFlight() else {
            log("[ADV][ERROR] ensureAdvertising(\(reason)) 被串行闸门挡掉：登记待办，闸门释放后重试")
            pendingEnsureReason = reason
            schedulePendingFlush()
            return
        }
        // 关键顺序：add(service) 是异步的。必须等 didAdd 成功后再 startAdvertising，
        // 否则手机可能在 GATT 数据库还没注册好时就连上，服务发现失败 → 断开重连，
        // 表现为「第一次连接总是很慢/失败」。
        if !serviceBuilt {
            if !serviceAddPending {
                log("[GATT] 服务尚未就绪（\(reason)）：先注册服务，didAdd 成功后再广播")
                buildService()
            }
            return
        }
        guard !manager.isAdvertising else { return }   // 已在广播：不做多余调用
        startAdvertising(reason: reason)
    }

    /// 广播载荷。降级后去掉本地名：Android 端按 service UUID 过滤，不影响发现。
    private func advertisePayload() -> [String: Any] {
        var payload: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [kServiceUUID]]
        if !reducedAdvertising {
            payload[CBAdvertisementDataLocalNameKey] = deviceName
        }
        return payload
    }

    /// 真正调用 `startAdvertising` 的唯一入口（全文件只在 ::782 调一次 CB API）。
    /// - Parameter force: 为 true 时跳过「已在广播」守卫。
    ///   「假在线」场景下 CoreBluetooth 会认为 isAdvertising=true，但 controller 从未广播，
    ///   这时必须无视该状态重新下发布广播请求，否则永远不会自愈。
    private func startAdvertising(reason: String, force: Bool = false) {
        guard manager.state == .poweredOn, serviceBuilt else { return }
        if !force {
            guard !manager.isAdvertising else { return }
        }
        advertisingStartCount += 1
        lastAdvertisingStartedAt = Date()
        let name = reducedAdvertising ? "(已降级，不带名称)" : deviceName
        log("[ADV] 开始广播 #\(advertisingStartCount)（\(reason)）service=\(kServiceUUID.uuidString) name=\(name)"
            + " isAdvertising=\(manager.isAdvertising) 订阅数=\(subscribedCentrals.count)"
            + " re-arm=\(consecutiveRearms) force=\(force)")
        manager.startAdvertising(advertisePayload())
    }

    /// 立即重建广播（不会主动断开已连接的手机）。
    /// - Parameter deep: 为 true 且当前没有手机连着时，连 GATT 服务一起移除并重新注册
    ///   （系统睡眠唤醒后数据库可能已失效，只重启广播未必能被发现）。
    func restartAdvertising(reason: String, deep: Bool = false) {
        guard manager != nil, manager.state == .poweredOn else {
            log("[ADV] 跳过重建广播（\(reason)）：蓝牙状态未就绪")
            return
        }
        if deep && subscribedCentrals.isEmpty {
            // 深重建统一入口：冷却期内一律降级为轻量重启。否则系统每次唤醒都会
            // removeAllServices，合盖/自动唤醒频繁时等于周期性自毁手机侧 GATT 缓存。
            if let cooldown = deepRebuildCooldownUntil, Date() < cooldown {
                log("[ADV] 深度重建冷却中（\(reason)）：剩余 \(Int(cooldown.timeIntervalSinceNow))s，改为轻量重建")
                restartAdvertising(reason: reason + "·冷却中降级", deep: false)
                return
            }
            // 深度重建统一走 requestDeepRebuild：闸门忙时排队、removeAllServices 前做静默确认。
            requestDeepRebuild(reason: reason)
            return
        }
        guard !advertisingOperationInFlight() else {
            log("[ADV][ERROR] restartAdvertising(\(reason), deep=\(deep)) 被串行闸门挡掉：登记待办后重试")
            pendingRestartReason = reason
            schedulePendingFlush()
            return
        }
        if manager.isAdvertising {
            log("[ADV] 重建广播（\(reason)）：先停止旧广播"
                + " isAdvertising=\(manager.isAdvertising) 订阅数=\(subscribedCentrals.count)")
            manager.stopAdvertising()
        }
        // stopAdvertising 之后立刻 start 有时会被系统忽略，间隔 100 ms 再启动。
        // t11 F1：回调必须排在闸门到期之后，并在回调里先清掉闸门，否则
        // ensureAdvertising 会被上一次操作自己设的闸门挡掉，广播要等 2.5 s 健康检查才恢复。
        advertisingOperationUntil = Date().addingTimeInterval(0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.advertisingOperationUntil = nil
            guard self.manager.state == .poweredOn else {
                log("[ADV] 重建广播的延迟启动被跳过：蓝牙状态已变为 \(self.stateName(self.manager.state))")
                return
            }
            if self.serviceBuilt {
                // 直接强制下发布广请求：不受 isAdvertising 假值影响（假在线时它是 true）。
                self.startAdvertising(reason: reason + "·延迟重启", force: true)
            } else {
                self.ensureAdvertising(reason: reason + "·延迟重启（等待服务就绪）")
            }
        }
    }

    // MARK: 「假在线」兜底：idle 强制 re-arm / 深度重建

    /// 广播操作串行闸门。所有停止/重启/重建都必须先过这一层，
    /// 保证同一时刻只有一条广播操作在跑（watchdog、健康检查、唤醒重建不会互相打断）。
    private func advertisingOperationInFlight(now: Date = Date()) -> Bool {
        if let until = advertisingOperationUntil {
            if now < until { return true }
            advertisingOperationUntil = nil
        }
        return false
    }

    /// 给日志用的广播/连接概况。t7 可直接 grep `[ADV]` 判定兜底是否生效。
    private func advStateDescription() -> String {
        let idle = Int(Date().timeIntervalSince(lastCentralActivity))
        var text = "isAdvertising=\(manager?.isAdvertising ?? false) serviceBuilt=\(serviceBuilt)"
            + " 订阅数=\(subscribedCentrals.count) 空闲=\(idle)s re-arm=\(consecutiveRearms)"
            + " 启动次数=\(advertisingStartCount) 重建=\(deepRebuildCount)"
        if pendingDeepRebuild { text += " 待重建=是" }
        if pendingRestartReason != nil || pendingEnsureReason != nil { text += " 待重播=是" }
        return text
    }

    // MARK: 深度重建的排队 / 静默确认 / 退避

    /// 深度重建的指数退避间隔（秒）：60 → 300 → 1800。
    private var deepRebuildBackoff: TimeInterval {
        switch deepRebuildBackoffIndex {
        case 0:  return 60
        case 1:  return 300
        default: return 1800
        }
    }

    /// 请求深度重建：闸门忙时排队；否则等「最后一次 CB 回调后 ≥3 s」再真正 removeAllServices。
    /// - 闸门忙时不再静默 return（t11 F2：唤醒深度重建曾被直接丢弃）。
    /// - 静默确认（t11 F4）：peripheral 角色没有 didConnect 回调，手机「已连上但还没订阅」
    ///   的那段时间代码是看不见的；此时 removeAllServices 会让首次服务发现失败后重连。
    /// 深度重建前的静默窗口：peripheral 角色看不到 didConnect，手机「已连上、正在发现服务」
    /// 这一两秒对代码不可见；窗口太短会在服务发现途中 removeAllServices，导致首次连接失败重连。
    private let deepRebuildQuietWindow: TimeInterval = 10.0

    private func requestDeepRebuild(reason: String) {
        guard manager != nil, manager.state == .poweredOn else {
            log("[ADV] 跳过深度重建（\(reason)）：蓝牙状态未就绪")
            return
        }
        guard subscribedCentrals.isEmpty else {
            log("[ADV] 跳过深度重建（\(reason)）：仍有 \(subscribedCentrals.count) 个订阅，避免打断连接")
            return
        }
        if advertisingOperationInFlight() {
            pendingDeepRebuild = true
            pendingDeepRebuildReason = reason
            log("[ADV][ERROR] 深度重建(\(reason)) 被串行闸门挡掉：已排队，闸门释放后重试 \(advStateDescription())")
            schedulePendingFlush()
            return
        }
        let quietFor = Date().timeIntervalSince(lastCentralActivity)
        if quietFor >= deepRebuildQuietWindow {
            // 距最后一次 CB 回调已 ≥3 s：没有「正在发现服务」的手机，立即重建。
            performDeepRebuild(reason: reason)
            return
        }
        // 最近 3 s 内还有 CB 活动：排队到「最后一次回调 + 3 s」再确认一次。
        pendingDeepRebuild = true
        pendingDeepRebuildReason = reason
        deepRebuildConfirmAt = lastCentralActivity.addingTimeInterval(deepRebuildQuietWindow)
        let delay = max(0.05, deepRebuildQuietWindow - quietFor + 0.05)
        log("[ADV] 深度重建排队（\(reason)）：最近 \(String(format: "%.1f", quietFor))s 内有手机活动，"
            + "等 \(String(format: "%.1f", delay))s 静默确认后再移除服务 \(advStateDescription())")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.performDeepRebuildIfQuiet()
        }
    }

    /// 静默确认后执行深度重建；若确认期间手机又活动/闸门仍忙，则放弃或重试。
    private func performDeepRebuildIfQuiet() {
        guard pendingDeepRebuild else { return }
        guard manager != nil, manager.state == .poweredOn else {
            log("[ADV] 取消深度重建：蓝牙状态未就绪")
            pendingDeepRebuild = false
            pendingDeepRebuildReason = nil
            deepRebuildConfirmAt = nil
            return
        }
        if advertisingOperationInFlight() {
            log("[ADV] 深度重建确认时闸门仍忙：继续排队重试 \(advStateDescription())")
            schedulePendingFlush()
            return
        }
        guard subscribedCentrals.isEmpty else {
            log("[ADV] 取消深度重建：确认期间手机已订阅，避免打断连接 \(advStateDescription())")
            pendingDeepRebuild = false
            pendingDeepRebuildReason = nil
            deepRebuildConfirmAt = nil
            return
        }
        if let confirmAt = deepRebuildConfirmAt, Date() < confirmAt {
            let delay = confirmAt.timeIntervalSinceNow + 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.performDeepRebuildIfQuiet()
            }
            return
        }
        if Date().timeIntervalSince(lastCentralActivity) < deepRebuildQuietWindow {
            log("[ADV] 取消深度重建：确认期间仍有手机活动 \(advStateDescription())")
            pendingDeepRebuild = false
            pendingDeepRebuildReason = nil
            deepRebuildConfirmAt = nil
            return
        }
        let reason = pendingDeepRebuildReason ?? "深度重建"
        pendingDeepRebuild = false
        pendingDeepRebuildReason = nil
        deepRebuildConfirmAt = nil
        performDeepRebuild(reason: reason)
    }

    /// 真正的深度重建：stopAdvertising → removeAllServices → buildService → didAdd 后广播。
    /// 顺序上必须「先 removeAllServices 再 buildService」，否则可能重复 add 同一个服务。
    private func performDeepRebuild(reason: String) {
        guard manager != nil, manager.state == .poweredOn, subscribedCentrals.isEmpty else { return }
        deepRebuildCount += 1
        log("[ADV] 深度重建 #\(deepRebuildCount)（\(reason)）：removeAllServices → buildService → didAdd 后广播"
            + " \(advStateDescription())")
        manager.stopAdvertising()
        manager.removeAllServices()
        serviceBuilt = false
        serviceAddPending = false
        serviceAddStartedAt = nil
        statusValue = "READY"
        pendingStatus = nil
        // 闸门只覆盖 removeAllServices → 重新注册 之间的窗口；didAdd 回来时必须已经放开，
        // 否则 didAdd → ensureAdvertising 会被当成「上一次操作尚未完成」挡掉（t11 F1 deep 分支）。
        advertisingOperationUntil = Date().addingTimeInterval(0.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, self.manager.state == .poweredOn else { return }
            self.advertisingOperationUntil = nil
            log("[ADV] 深度重建：重新注册 GATT 服务（didAdd 成功后会自动广播）")
            self.buildService()
        }
    }

    // MARK: 待办合并：闸门忙时的请求登记与重试

    /// 排队一个待办刷新：0.5 s 后尝试；若闸门仍忙则继续退避重试（最多 8 次，绝不静默丢弃）。
    private func schedulePendingFlush(after delay: TimeInterval = 0.5) {
        guard !pendingFlushScheduled else { return }
        pendingFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.pendingFlushScheduled = false
            self.flushPendingWork()
        }
    }

    private func flushPendingWork() {
        guard manager != nil, manager.state == .poweredOn else {
            pendingDeepRebuild = false
            pendingDeepRebuildReason = nil
            pendingRestartReason = nil
            pendingEnsureReason = nil
            pendingRearmReason = nil
            deepRebuildConfirmAt = nil
            pendingFlushAttempts = 0
            return
        }
        if advertisingOperationInFlight() {
            pendingFlushAttempts += 1
            if pendingFlushAttempts > 8 {
                log("[ADV][ERROR] 待办重试 8 次仍被闸门挡住，放弃本轮（等 watchdog/健康检查兜底）"
                    + " 待重建=\(pendingDeepRebuild) 待重播=\(pendingRestartReason ?? "-") \(advStateDescription())")
                pendingFlushAttempts = 0
                pendingDeepRebuild = false
                pendingDeepRebuildReason = nil
                pendingRestartReason = nil
                pendingEnsureReason = nil
                pendingRearmReason = nil
                return
            }
            log("[ADV] 待办重试第 \(pendingFlushAttempts) 次：闸门仍忙，0.5 s 后再试")
            schedulePendingFlush()
            return
        }
        pendingFlushAttempts = 0
        performOnePendingWork()
        // 一次只做一件：若还有其他待办（例如深度重建期间又来了唤醒请求），
        // 顺延 0.3 s 再做，绝不静默丢弃。
        if hasPendingWork {
            schedulePendingFlush(after: 0.3)
        }
    }

    private var hasPendingWork: Bool {
        pendingDeepRebuild || pendingRestartReason != nil
            || pendingEnsureReason != nil || pendingRearmReason != nil
    }

    private func performOnePendingWork() {
        if pendingDeepRebuild {
            log("[ADV] 执行排队的深度重建（reason=\(pendingDeepRebuildReason ?? "-")）")
            performDeepRebuildIfQuiet()
            return
        }
        if let reason = pendingRearmReason {
            pendingRearmReason = nil
            log("[ADV] 执行排队的强制 re-arm（reason=\(reason)）")
            forceRearm(reason: reason + "·排队重试")
            return
        }
        if let reason = pendingRestartReason {
            pendingRestartReason = nil
            log("[ADV] 执行排队的广播重建（reason=\(reason)）")
            restartAdvertising(reason: reason + "·排队重试")
            return
        }
        if let reason = pendingEnsureReason {
            pendingEnsureReason = nil
            log("[ADV] 执行排队的广播确认（reason=\(reason)）")
            ensureAdvertising(reason: reason + "·排队重试")
        }
    }

    /// 蓝牙关闭/重置时清空所有待办：这些请求依赖 poweredOn 状态，留着只会在下次启动时误触发。
    private func clearPendingAdvertisingWork() {
        if pendingDeepRebuild || pendingRestartReason != nil || pendingEnsureReason != nil || pendingRearmReason != nil {
            log("[ADV] 蓝牙状态变化：清空待办的广播工作（待重建=\(pendingDeepRebuild)）")
        }
        pendingDeepRebuild = false
        pendingDeepRebuildReason = nil
        pendingRestartReason = nil
        pendingEnsureReason = nil
        pendingRearmReason = nil
        deepRebuildConfirmAt = nil
        pendingFlushAttempts = 0
        deepRebuildCooldownUntil = nil
        consecutiveRearms = 0
        advertisingSuccessStreak = 0
    }

    /// idle watchdog：5 s tick。**不看 isAdvertising**，因为「假在线」时它是 true。
    /// 触发条件：蓝牙就绪 + 当前无订阅 + 距上次手机活动 > 10 s + 距上次 re-arm ≥ 60 s。
    private func startIdleRearmTimer() {
        idleRearmTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.idleRearmCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleRearmTimer = timer
        log("[ADV] idle re-arm watchdog 已启动（tick=5s，静默>10s 触发，间隔≥60s）")
    }

    private func stopIdleRearmTimer() {
        guard idleRearmTimer != nil else { return }
        idleRearmTimer?.invalidate()
        idleRearmTimer = nil
        log("[ADV] idle re-arm watchdog 已停止（蓝牙未就绪）")
    }

    private func idleRearmCheck() {
        guard manager != nil, manager.state == .poweredOn else { return }
        // 有手机连着就绝不打断（真正在服务时优先保障连接稳定性）。
        // 但睡眠/异常断开时可能收不到 didUnsubscribeFrom，订阅记录会永久残留，
        // 让整套自愈永久失效——这里按「长时间零活动」判定为残留并清空。
        if !subscribedCentrals.isEmpty {
            let silence = Date().timeIntervalSince(lastCentralActivity)
            if silence > 1800 {
                log("[CONN][WARN] 订阅记录 \(subscribedCentrals.count) 个已 \(Int(silence)) s 无任何活动："
                    + "判定为残留（未收到取消订阅回调），清空以恢复自愈能力")
                subscribedCentrals.removeAll()
            } else {
                return
            }
        }
        let now = Date()
        let idle = now.timeIntervalSince(lastCentralActivity)
        guard idle > 10 else { return }
        if let last = lastRearmAt, now.timeIntervalSince(last) < 60 { return }
        // 刚做过深度重建：按指数退避（60 s → 5 min → 30 min）冷静，避免反复 removeAllServices。
        if let cooldown = deepRebuildCooldownUntil {
            if now < cooldown { return }
            deepRebuildCooldownUntil = nil
        }
        forceRearm(reason: String(format: "idle %.0f s 无手机活动", idle))
    }

    /// 强制 re-arm：**绕过 isAdvertising 门控**，先 stopAdvertising 再 startAdvertising。
    /// 只有在「连续 re-arm 且确实像 controller 卡死」时才升级为深度重建：
    /// 要求最近一次 startAdvertising 之后 ≥15 s 没有任何手机活动，并按 60 s→5 min→30 min 指数退避，
    /// 避免正常无人使用时周期性 removeAllServices（t11 F3：会反复失效手机侧 GATT 缓存并污染测量）。
    /// 所有操作都在主队列（CB 委托队列）上串行执行。
    func forceRearm(reason: String) {
        guard manager != nil else { return }
        guard manager.state == .poweredOn else {
            log("[ADV] 跳过强制 re-arm（\(reason)）：蓝牙状态=\(stateName(manager.state))")
            return
        }
        if advertisingOperationInFlight() {
            log("[ADV][ERROR] 强制 re-arm(\(reason)) 被串行闸门挡掉：登记待办后重试")
            pendingRearmReason = reason
            schedulePendingFlush()
            return
        }
        guard serviceBuilt else {
            log("[ADV] 强制 re-arm 推迟（\(reason)）：GATT 服务尚未就绪，先注册服务")
            ensureAdvertising(reason: reason + "·等待服务就绪")
            return
        }
        guard subscribedCentrals.isEmpty else {
            log("[ADV] 跳过强制 re-arm（\(reason)）：仍有 \(subscribedCentrals.count) 个订阅，避免打断连接")
            return
        }

        consecutiveRearms += 1
        lastRearmAt = Date()
        log("[ADV] 强制 re-arm #\(consecutiveRearms)（\(reason)）绕过 isAdvertising 门控：\(advStateDescription())")

        // 升级判据：必须同时满足「连续 ≥2 次 re-arm」+「最近一次广播后 ≥15 s 完全无手机活动」。
        // 后者就是 controller 侧未真正广播的最直接证据（假在线时 CB 永远不会告诉我们真相）。
        let sinceLastStart = lastAdvertisingStartedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let idleSinceActivity = Date().timeIntervalSince(lastCentralActivity)
        if consecutiveRearms >= 2, sinceLastStart >= 15, idleSinceActivity >= 15 {
            consecutiveRearms = 0
            let backoff = deepRebuildBackoff
            deepRebuildCooldownUntil = Date().addingTimeInterval(backoff)
            deepRebuildBackoffIndex = min(deepRebuildBackoffIndex + 1, 2)
            log("[ADV] 连续 2 次 re-arm 且最近一次广播后 \(Int(sinceLastStart))s 无任何手机活动，"
                + "判定 controller 侧“假在线”，请求深度重建（下次升级冷却 \(Int(backoff))s）\(advStateDescription())")
            requestDeepRebuild(reason: "连续 re-arm 无活动")
            return
        }
        if consecutiveRearms >= 2 {
            log("[ADV] 连续 \(consecutiveRearms) 次 re-arm 仍无订阅，但最近一次广播后仅 "
                + "\(String(format: "%.1f", sinceLastStart))s / 空闲 \(Int(idleSinceActivity))s，"
                + "证据不足以判定 controller 卡死，继续轻量 re-arm（不重建 GATT）")
        }

        manager.stopAdvertising()
        advertisingOperationUntil = Date().addingTimeInterval(0.4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            guard self.manager.state == .poweredOn, self.serviceBuilt, self.subscribedCentrals.isEmpty else {
                // 手机刚好连上/状态变化：这是正常情况，但必须留痕，不能静默消失。
                log("[ADV] 强制 re-arm 的重新广播被跳过：状态已变化 \(self.advStateDescription())")
                return
            }
            log("[ADV] 强制 re-arm 重新广播（\(reason)）：\(self.advStateDescription())")
            self.startAdvertising(reason: "强制 re-arm·" + reason, force: true)
        }
    }

    private func buildService() {
        commandChar = CBMutableCharacteristic(type: kCharCommandUUID,
                                              properties: [.write, .writeWithoutResponse],
                                              value: nil,
                                              permissions: [.writeable])

        // 注意：带 .notify/.read 的特征不能预置缓存值（CoreBluetooth 会抛
        // "Characteristics with cached values must be read-only"），
        // 因此这里 value 必须是 nil，读取时在 didReceiveRead 里动态返回。
        statusChar = CBMutableCharacteristic(type: kCharStatusUUID,
                                             properties: [.read, .notify],
                                             value: nil,
                                             permissions: [.readable])

        // 只读且值固定的特征可以预置缓存值，对手机端更省一次交互
        let info = "BLEUnlockCmd v1;\(deviceName)"
        let infoChar = CBMutableCharacteristic(type: kCharInfoUUID,
                                               properties: [.read],
                                               value: info.data(using: .utf8),
                                               permissions: [.readable])

        let service = CBMutableService(type: kServiceUUID, primary: true)
        service.characteristics = [commandChar, statusChar, infoChar]
        serviceBuilt = false
        serviceAddPending = true
        serviceAddStartedAt = Date()
        manager.add(service)
        log("[GATT] 已提交 GATT 服务注册（\(kServiceUUID.uuidString)），等待 didAdd 回调")
    }

    // MARK: 服务注册失败的重试与 manager 重建

    /// 服务注册失败后的重试延迟：0.5 → 1 → 2 → 4 s（上限 4 s）。
    private func serviceAddRetryDelay() -> TimeInterval {
        min(0.5 * pow(2.0, Double(max(0, serviceAddFailCount - 1))), 4.0)
    }

    /// 安排一次服务重新注册；连续失败达到 3 次时重建 CBPeripheralManager。
    /// 唤醒后 CoreBluetooth 不再回调 didAdd 时，add/remove 的任何组合都不会恢复，
    /// 只有换一个新的 manager 才能重新获得广播能力（否则手机永远扫不到）。
    private func scheduleServiceRebuild(delay: TimeInterval) {
        guard manager != nil else { return }
        if serviceAddFailCount >= 3 {
            rebuildPeripheralManager()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ensureAdvertising(reason: "服务注册重试")
        }
    }

    /// 重建 CBPeripheralManager。旧实例的回调由各 delegate 里的 `peripheral === manager` 守卫忽略。
    private func rebuildPeripheralManager() {
        log("[BLE][WARN] 重建 CBPeripheralManager：连续 \(serviceAddFailCount) 次服务注册未成功，"
            + "按经验这比继续 add/remove 更可靠 \(advStateDescription())")
        serviceAddFailCount = 0
        serviceBuilt = false
        serviceAddPending = false
        serviceAddStartedAt = nil
        subscribedCentrals.removeAll()
        pendingStatus = nil
        deepRebuildCooldownUntil = nil
        manager.stopAdvertising()
        manager.removeAllServices()
        manager = CBPeripheralManager(delegate: self, queue: nil)
        // 新 manager 的 poweredOn 回调会重新注册服务；1 s 后仍无进展就主动自检一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.ensureAdvertising(reason: "重建 manager 后自检")
        }
    }

    /// 更新状态特征。
    ///
    /// 线程安全：可能从 CB 回调队列（主队列）调用，也可能从 unlockQueue 的
    /// 解锁流程里调用；真正的状态改动与 updateValue 一律回到主队列执行
    /// （CBPeripheralManager 的 delegate 队列即主队列）。
    func setStatus(_ text: String) {
        if Thread.isMainThread {
            applyStatus(text)
        } else {
            DispatchQueue.main.async { [weak self] in self?.applyStatus(text) }
        }
    }

    private func applyStatus(_ text: String) {
        guard manager != nil else { return }
        statusValue = text
        // 注意：不要给 statusChar.value 赋值。带 .notify 的特征一旦被赋予缓存值，
        // 之后 manager.add(service) 会抛 "Characteristics with cached values must be read-only"。
        // 读取由 didReceiveRead 动态返回，推送走 updateValue。
        guard manager.state == .poweredOn, let characteristic = statusChar else { return }
        if !manager.updateValue(text.data(using: .utf8)!, for: characteristic, onSubscribedCentrals: nil) {
            // 队列已满，等 peripheralManagerIsReady 时补发
            pendingStatus = text
        }
    }

    // MARK: 周期健康检查（2.5 s）

    private func startAdvertisingHealthTimer() {
        advertiseTimer?.invalidate()
        // 20 s 的旧周期意味着广播一旦被系统停掉，手机最长有 20 s 扫不到设备。
        // 2.5 s 健康检查把这段盲区压到 2.5 s 以内；只有状态发生翻转时才写日志，避免刷屏。
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.advertisingHealthCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        advertiseTimer = timer
    }

    private func advertisingHealthCheck() {
        guard manager != nil, manager.state == .poweredOn else { return }
        if !serviceBuilt {
            // didAdd 正常应在毫秒级返回；系统刚唤醒时可能丢回调。
            // 超过 2 s 没有 didAdd 就视为注册失败，重新提交（2.5 s 检查周期内可自愈）。
            if serviceAddPending, let started = serviceAddStartedAt,
               Date().timeIntervalSince(started) > 2.0 {
                // 先 removeAllServices 再重新 add：如果服务其实已经注册、只是 didAdd 回调丢了，
                // 直接 add 会得到重复服务（手机侧看到两套特征）；移除一次再注册最稳。
                serviceAddFailCount += 1
                log("[GATT] didAdd 超过 2 s 未回调（连续第 \(serviceAddFailCount) 次）："
                    + "先 removeAllServices 再重新注册服务")
                manager?.removeAllServices()
                serviceAddPending = false
                serviceAddStartedAt = nil
                serviceBuilt = false
                if serviceAddFailCount >= 3 {
                    log("[GATT][ERROR] didAdd 连续 \(serviceAddFailCount) 次丢失：重建 CBPeripheralManager 以恢复广播")
                    rebuildPeripheralManager()
                } else {
                    scheduleServiceRebuild(delay: serviceAddRetryDelay())
                }
                return
            }
            if !serviceAddPending { buildService() }   // 服务丢失（例如 removeAllServices 后）→ 重新注册
            return
        }
        guard !manager.isAdvertising else {
            lastHealthAdvertisingOK = true
            return
        }
        if lastHealthAdvertisingOK != false {
            lastHealthAdvertisingOK = false
            // 统一走 ensureAdvertising：经过串行闸门 + 服务就绪检查，避免与 watchdog 的
            // stop→start 窗口重叠。注意这里仍然看不到「假在线」——那种情况由 idle watchdog 兜底。
            log("[ADV] 周期重播：检测到广播已停止，立即重新开始 \(advStateDescription())")
        }
        ensureAdvertising(reason: "周期重播")
    }

    // MARK: CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        // 重建 manager 后旧实例可能仍回调：只处理当前实例，避免把新状态机打乱。
        guard peripheral === manager else { return }
        switch peripheral.state {
        case .poweredOn:
            log("[BLE] 蓝牙已就绪（poweredOn）：注册 GATT 服务，注册成功后再广播")
            serviceBuilt = false
            serviceAddPending = false
            serviceAddStartedAt = nil
            serviceAddFailCount = 0
            pendingStatus = nil
            buildService()                 // didAdd 成功后会立即 startAdvertising
            startAdvertisingHealthTimer()
            // 「假在线」兜底：isAdvertising 可能是 true 但 controller 没广播，
            // 所以必须有一个不看 isAdvertising 的 idle watchdog。
            startIdleRearmTimer()
        case .poweredOff:
            log("[BLE] 蓝牙已关闭（poweredOff）：停止广播并移除所有 GATT 服务，等待重新开启")
            advertiseTimer?.invalidate()
            advertiseTimer = nil
            stopIdleRearmTimer()
            clearPendingAdvertisingWork()
            manager.stopAdvertising()
            manager.removeAllServices()
            serviceBuilt = false
            serviceAddPending = false
            serviceAddStartedAt = nil
            subscribedCentrals.removeAll()
            pendingStatus = nil
            statusValue = "READY"
        case .unauthorized:
            log("[BLE] 蓝牙权限被拒绝（unauthorized）：请在「系统设置 → 隐私与安全性 → 蓝牙」中授权")
        case .resetting:
            log("[BLE] 蓝牙状态重置中（resetting）：停止广播并丢弃服务状态，等待下一次 poweredOn 自动恢复")
            advertiseTimer?.invalidate()
            advertiseTimer = nil
            stopIdleRearmTimer()
            clearPendingAdvertisingWork()
            serviceBuilt = false
            serviceAddPending = false
            serviceAddStartedAt = nil
            subscribedCentrals.removeAll()
        default:
            log("[BLE] 蓝牙状态变化：\(stateName(peripheral.state))，等待就绪")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard peripheral === manager else { return }
        guard let error = error else {
            let roundTrip: String
            if let started = lastAdvertisingStartedAt {
                roundTrip = String(format: "%.3f s", Date().timeIntervalSince(started))
            } else {
                roundTrip = "-"
            }
            log("[ADV] 广播已生效 #\(advertisingStartCount)（startAdvertising 往返 \(roundTrip)），等待手机连接")
            advertisingSuccessStreak += 1
            // 降级只是临时降风险：连续 2 次启动成功说明广播链路正常，恢复完整载荷（带设备名）。
            if reducedAdvertising, advertisingSuccessStreak >= 2 {
                reducedAdvertising = false
                log("[ADV] 连续 \(advertisingSuccessStreak) 次广播成功：恢复完整广播载荷（重新带上设备名 \(deviceName)）")
                if subscribedCentrals.isEmpty {
                    restartAdvertising(reason: "恢复完整广播载荷")
                }
            }
            // 只在空闲态刷新 READY：force 重播/恢复载荷可能发生在刚发完指令时，
            // 无条件写 READY 会把 UNLOCKING/OK 洗掉，手机端读到的状态就不对了。
            if subscribedCentrals.isEmpty, statusValue == "CONNECTED" || statusValue == "READY" {
                setStatus("READY")
            }
            return
        }
        advertisingFailCount += 1
        advertisingSuccessStreak = 0
        lastAdvertisingStartedAt = nil
        log("[ADV] 广播失败 #\(advertisingFailCount)：\(error.localizedDescription)")
        if !reducedAdvertising {
            // 常见原因是广播数据过大/系统繁忙。降级为只带 service UUID：
            // Android 端按 service UUID 过滤，不影响发现；只是人工用设备名扫描会看不到。
            reducedAdvertising = true
            log("[ADV] 降级广播载荷：去掉本地名，只保留 service UUID")
        }
        // 300 ms 后重试；仍失败则交给 2.5 s 周期健康检查持续兜底。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.ensureAdvertising(reason: "广播失败重试")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard peripheral === manager else { return }
        // 没有待处理的 add 时，这个回调只能来自已经被 removeAllServices 移除的旧服务
        // （唤醒/关闭蓝牙时可能迟到）。直接采纳会让 serviceBuilt 与实际数据库不一致，
        // 进而「广播了但手机发现不了服务」，所以这里忽略，交给健康检查自愈。
        guard serviceAddPending else {
            log("[GATT] 忽略过期的 didAdd 回调（\(service.uuid.uuidString)），由周期检查自愈")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.ensureAdvertising(reason: "过期 didAdd 后自检")
            }
            return
        }
        serviceAddPending = false
        serviceAddStartedAt = nil
        if let error = error {
            serviceBuilt = false
            serviceAddFailCount += 1
            let delay = serviceAddRetryDelay()
            // 重复 add 会持续失败：重试前必须先 removeAllServices，并指数退避，
            // 否则就是 0.5 s 无限重试（日志/CPU 双爆，且永远等不到 didAdd）。
            log("[GATT] 添加服务失败（连续第 \(serviceAddFailCount) 次）：\(error.localizedDescription)，"
                + "\(String(format: "%.2f", delay)) s 后 removeAllServices 再重试")
            manager.removeAllServices()
            scheduleServiceRebuild(delay: delay)
            return
        }
        guard service.uuid == kServiceUUID else { return }
        serviceBuilt = true
        serviceAddFailCount = 0
        log("[GATT] 服务已就绪（\(kServiceUUID.uuidString)），立即开始广播")
        ensureAdvertising(reason: "didAdd 完成")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard peripheral === manager else { return }
        let sinceAdvertising: String
        if let started = lastAdvertisingStartedAt {
            sinceAdvertising = String(format: "%.2f s", Date().timeIntervalSince(started))
        } else {
            sinceAdvertising = "-"
        }
        log("[CONN] 手机已连接并订阅（central=\(central.identifier.uuidString)，距上次开始广播 \(sinceAdvertising)）")
        subscribedCentrals.insert(central.identifier)
        noteCentralActivity("订阅")
        // 只有已连接的 central 才能设置期望连接延迟：.low 表示更频繁的链路事件
        // （更低延迟、更高功耗）。这是 macOS 的 CBPeripheralManager API，只是「期望」，
        // 系统不保证一定采用；但对解锁这种秒级交互通常有收益。
        peripheral.setDesiredConnectionLatency(CBPeripheralManagerConnectionLatency.low, for: central)
        log("[CONN] 已请求低延迟连接（CBPeripheralManagerConnectionLatency.low）")
        setStatus("CONNECTED")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard peripheral === manager else { return }
        log("[DISC] 手机取消订阅（central=\(central.identifier.uuidString)）：立即重建广播")
        subscribedCentrals.remove(central.identifier)
        noteCentralActivity("取消订阅")
        setStatus("READY")
        restartAdvertising(reason: "取消订阅后重建广播")
    }

    /// 记录一次手机侧活动。idle watchdog 只在「长时间没有任何手机活动」时才强制 re-arm，
    /// 因此真实连接/读写期间不会被误触发。活动本身也证明广播链路是通的：清零连续 re-arm 计数。
    private func noteCentralActivity(_ what: String) {
        lastCentralActivity = Date()
        if consecutiveRearms != 0 {
            log("[ADV] 检测到手机活动（\(what)）：广播链路正常，清零连续 re-arm 计数（原 \(consecutiveRearms)）")
            consecutiveRearms = 0
        }
        // 有手机活动 = 广播确实在 air：把深度重建的退避档位也复位，
        // 下次真的再“假在线”时仍然从 60 s 起步。
        deepRebuildBackoffIndex = 0
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        // 上一次 updateValue 因发送队列满而失败，这里补发
        guard let text = pendingStatus, manager.state == .poweredOn, let characteristic = statusChar else { return }
        pendingStatus = nil
        manager.updateValue(text.data(using: .utf8)!, for: characteristic, onSubscribedCentrals: nil)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager else { return }
        // 「假在线」兜底：收到真实写入就说明广播/连接链路是通的，刷新活动时间。
        noteCentralActivity("写入指令")
        // 关键：先把 ATT 应答发回去，再做任何校验/执行。
        // 校验、fork/exec（读钥匙串）、Thread.sleep、AX 注入都是慢操作；在这条
        // 委托队列（主队列）上同步执行会堵住后续 CB 回调与状态通知，手机端表现为
        // 「写成功了却迟迟等不到状态回推」——这是连接/解锁慢的主要放大器之一。
        var pending: [Data] = []
        for request in requests {
            guard request.characteristic.uuid == kCharCommandUUID else {
                peripheral.respond(to: request, withResult: .attributeNotFound)
                continue
            }
            // 必须先取载荷再回应答：respond 之后 request.value 的可用性没有保证，
            // 取到空包会让校验直接走 ERR_LEN（手机显示已发送，但永远不解锁）。
            // 带应答写：不回会让手机端卡在 writeValue 的回调上。
            let payload = request.value ?? Data()
            peripheral.respond(to: request, withResult: .success)
            pending.append(payload)
        }
        guard !pending.isEmpty else { return }
        // 交给专用串行队列处理：既离开主队列，又保证指令串行、unlockInFlight 语义不变
        unlockQueue.async { [weak self] in
            guard let self = self else { return }
            for data in pending { self.handleCommand(data) }
        }
    }

    /// 解析并执行一条指令。
    ///
    /// 必须运行在 `unlockQueue` 上：里面的 verifyPacket / performUnlock / performLock
    /// 都可能阻塞，而这正是我们要避开的 CB 委托队列。
    private func handleCommand(_ data: Data) {
        log("[CMD] 收到写入 \(data.count) 字节，开始校验")
        switch verifyPacket(data, key: key) {
        case .failed(let reason):
            log("[CMD] 校验失败：\(reason)")
            setStatus(reason)

        case .ok(let command, let index, let force):
            switch command {
            case kCmdUnlockFrom:
                // 手机指定了要用第几个密码；force 时跳过锁屏校验
                let which = (index ?? 0) + 1
                log("[UNLOCK] 开始（指定第 \(which) 个密码，force=\(force)）")
                setStatus("UNLOCKING")
                performUnlock(preferredIndex: index, force: force) { [weak self] status in
                    guard let self = self else { return }
                    log("[UNLOCK] 结束：\(status)")
                    self.setStatus(status)
                }
            case kCmdUnlock:
                log("[UNLOCK] 开始（默认顺序）")
                setStatus("UNLOCKING")
                performUnlock { [weak self] status in
                    guard let self = self else { return }
                    log("[UNLOCK] 结束：\(status)")
                    self.setStatus(status)
                }
            case kCmdLock:
                log("[LOCK] 开始（收到锁定指令）")
                setStatus("LOCKING")
                performLock { [weak self] status in
                    guard let self = self else { return }
                    log("[LOCK] 结束：\(status)")
                    self.setStatus(status)
                }
            case kCmdPing:
                log("[CMD] 收到 PING，回复 PONG")
                setStatus("PONG")
            default:
                log("[CMD] 未知指令 0x\(String(command, radix: 16))")
                setStatus("ERR_CMD")
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
        // 「假在线」兜底：能读到特征说明手机确实连上了，刷新活动时间。
        noteCentralActivity("读取特征")
        if request.characteristic.uuid == kCharStatusUUID {
            let data = statusValue.data(using: .utf8)!
            if request.offset > data.count {
                peripheral.respond(to: request, withResult: .invalidOffset)
                return
            }
            request.value = data.subdata(in: request.offset..<data.count)
            peripheral.respond(to: request, withResult: .success)
        } else if request.characteristic.uuid == kCharInfoUUID {
            let data = "BLEUnlockCmd v1;\(deviceName)".data(using: .utf8)!
            request.value = data
            peripheral.respond(to: request, withResult: .success)
        } else {
            peripheral.respond(to: request, withResult: .attributeNotFound)
        }
    }
}

// MARK: - 入口

func printUsage() {
    print("""
    BLEUnlockCmd — 用手机通过蓝牙解锁这台 Mac

    用法: BLEUnlockCmd [选项]

      --print-token        打印配对令牌（在手机 App 中填写这个值）
      --set-key <base64>   写入指定的配对密钥
      --device-name <名>   广播的设备名
      --add-accessibility  打开「辅助功能」授权提示
      --check              自检：打印权限、钥匙串与配置状态
      --dry-run            安全测试模式：走完 BLE 收包与校验，但不真的解锁
      --show-token         打印配对令牌（未安装时自动生成一个临时密钥）
      --selftest <hex>     协议自检：对给定的十六进制消息输出 HMAC-SHA256
      --version            显示版本
    """)
}

ensureSupportDirectory()

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--version") {
    print("BLEUnlockCmd 1.4.2")
    exit(0)
}

// 协议闭环自检：不依赖蓝牙，直接走"收包 -> 校验 -> 执行"全流程
if args.contains("--selftest-protocol") {
    dryRun = true
    var failed = 0

    func expect(_ label: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)  \(detail)")
            failed += 1
        }
    }

    // 用临时密钥构造测试包
    var keyBytes = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { keyBytes[i] = UInt8(i) }
    let testKey = SymmetricKey(data: Data(keyBytes))

    func makePacket(command: UInt8, timestamp: Int64 = Int64(Date().timeIntervalSince1970),
                    nonce: Data? = nil, tamper: Bool = false) -> Data {
        var message = Data([0x42, 0x55, 0x01, command])
        var ts = UInt64(bitPattern: timestamp).bigEndian
        withUnsafeBytes(of: &ts) { message.append(contentsOf: $0) }
        var n = nonce ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        if n.count != 16 { n = Data(repeating: 0, count: 16) }
        message.append(n)
        message.append(contentsOf: [0x00, 0x00])
        var tag = Data(HMAC<SHA256>.authenticationCode(for: message, using: testKey))
        if tamper { tag[0] ^= 0xFF }
        return message + tag
    }

    print("== 报文校验 ==")

    switch verifyPacket(makePacket(command: kCmdUnlock), key: testKey) {
    case .ok(let c, let i, let f):
        expect("合法解锁包通过校验", c == kCmdUnlock, "命令=\(c)")
        expect("普通解锁不带密码序号", i == nil, "实际 \(String(describing: i))")
        expect("普通解锁不跳过锁屏校验", f == false)
    case .failed(let r): expect("合法解锁包通过校验", false, r)
    }

    switch verifyPacket(makePacket(command: kCmdPing), key: testKey) {
    case .ok(let c, _, _): expect("PING 包通过校验", c == kCmdPing, "命令=\(c)")
    case .failed(let r): expect("PING 包通过校验", false, r)
    }

    switch verifyPacket(makePacket(command: kCmdUnlock, tamper: true), key: testKey) {
    case .ok: expect("篡改的 HMAC 必须被拒绝", false, "居然通过了")
    case .failed(let r): expect("篡改的 HMAC 被拒绝", r == "ERR_HMAC", r)
    }

    let wrongKey = SymmetricKey(data: Data(repeating: 0xAB, count: 32))
    switch verifyPacket(makePacket(command: kCmdUnlock), key: wrongKey) {
    case .ok: expect("错误密钥必须被拒绝", false, "居然通过了")
    case .failed(let r): expect("错误密钥被拒绝", r == "ERR_HMAC", r)
    }

    switch verifyPacket(Data([0x42, 0x55, 0x01]), key: testKey) {
    case .ok: expect("过短的包必须被拒绝", false, "居然通过了")
    case .failed(let r): expect("过短的包被拒绝", r == "ERR_LEN", r)
    }

    var badMagic = makePacket(command: kCmdUnlock)
    badMagic[0] = 0x00
    switch verifyPacket(badMagic, key: testKey) {
    case .ok: expect("错误魔数必须被拒绝", false, "居然通过了")
    case .failed(let r): expect("错误魔数被拒绝", r == "ERR_MAGIC", r)
    }

    let stale = Int64(Date().timeIntervalSince1970) - 600
    switch verifyPacket(makePacket(command: kCmdUnlock, timestamp: stale), key: testKey) {
    case .ok: expect("过期时间戳必须被拒绝", false, "居然通过了")
    case .failed(let r): expect("过期时间戳被拒绝", r == "ERR_TIME", r)
    }

    print()
    print("== 防重放 ==")
    let fixedNonce = Data(repeating: 0x5A, count: 16)
    let p1 = makePacket(command: kCmdUnlock, nonce: fixedNonce)
    switch verifyPacket(p1, key: testKey) {
    case .ok: expect("同一 nonce 首次通过", true)
    case .failed(let r): expect("同一 nonce 首次通过", false, r)
    }
    switch verifyPacket(p1, key: testKey) {
    case .ok: expect("同一 nonce 重放必须被拒绝", false, "居然通过了")
    case .failed(let r): expect("同一 nonce 重放被拒绝", r == "ERR_REPLAY", r)
    }

    print()
    print("== 解锁流程（dry-run，不会真的注入密码）==")
    // 造一个临时配置，指向一个不存在的钥匙串账户，预期得到 ERR_NO_PW
    let tempConfig = Config(hmacKey: Data(keyBytes).base64EncodedString(),
                            keychainAccount: "__bleunlock_selftest_nonexistent__",
                            deviceName: "SELFTEST")
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(tempConfig).write(to: URL(fileURLWithPath: kConfigPath))

    var unlockResult = ""
    let sem = DispatchSemaphore(value: 0)
    performUnlock { status in
        unlockResult = status
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)
    expect("缺少钥匙串密码时返回 ERR_NO_PW", unlockResult == "ERR_NO_PW", "实际 \(unlockResult)")

    // 多密码：dry-run 应能识别出全部密码并逐个尝试
    let testAccount = "__bleunlock_selftest_multi__"
    storePasswords(["selftest-pw-1", "selftest-pw-2", "selftest-pw-3"], account: testAccount)
    let readBack = fetchPasswords(account: testAccount)
    expect("多密码可写入并读回 3 个", readBack.count == 3, "实际 \(readBack.count)")
    expect("顺序保持", readBack.first == "selftest-pw-1" && readBack.last == "selftest-pw-3",
           "实际 \(readBack)")

    let multiConfig = Config(hmacKey: Data(keyBytes).base64EncodedString(),
                             keychainAccount: testAccount,
                             deviceName: "SELFTEST")
    try? enc.encode(multiConfig).write(to: URL(fileURLWithPath: kConfigPath))

    var multiResult = ""
    let sem2 = DispatchSemaphore(value: 0)
    performUnlock { status in
        multiResult = status
        sem2.signal()
    }
    _ = sem2.wait(timeout: .now() + 20)
    expect("多密码 dry-run 返回 OK", multiResult == "OK", "实际 \(multiResult)")

    // 特殊字符必须能原样往返（引号、反斜杠、空格、中文、$、反引号）
    // 这类字符在 shell 管道里容易被吃掉，所以必须在代码路径上验证。
    let tricky = ["p@ss w0rd", "with\"quote", "with\\backslash", "中文密码",
                  "$dollar`tick", "tab\there"]
    storePasswords(tricky, account: testAccount)
    let trickyBack = fetchPasswords(account: testAccount)
    expect("特殊字符数量正确", trickyBack.count == tricky.count,
           "写入 \(tricky.count) 读回 \(trickyBack.count)")
    expect("特殊字符内容原样", trickyBack == tricky, "实际 \(trickyBack)")

    // 空密码应被过滤掉，不能产生一条空条目
    storePasswords(["keep-me", "", "  "], account: testAccount)
    let filtered = fetchPasswords(account: testAccount)
    expect("空密码被过滤（仅过滤空串）",
           filtered.first == "keep-me" && !filtered.contains(""),
           "实际 \(filtered.count) 个：\(filtered)")

    // 旧格式兼容：钥匙串里直接放明文
    _ = writeKeychainPassword("legacy-plain", account: testAccount)
    let legacy = fetchPasswords(account: testAccount)
    expect("旧格式单密码可识别", legacy == ["legacy-plain"], "实际 \(legacy)")

    // 报文里的"跳过锁屏校验"标志
    func packetWithForce(_ flag: UInt8, command: UInt8 = kCmdUnlockFrom) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: kPacketLen)
        b[0] = 0x42; b[1] = 0x55; b[2] = 0x01; b[3] = command
        b[kIndexOffset] = 1
        b[kForceOffset] = flag
        return b
    }
    expect("标志 1 → 解析为强制", extractForceFlag(packetWithForce(1)))
    expect("标志 0 → 不强制", extractForceFlag(packetWithForce(0)) == false)
    expect("标志 2 → 视为强制（非 0 即真）", extractForceFlag(packetWithForce(2)))
    expect("普通解锁不解析强制标志",
           extractForceFlag(packetWithForce(1, command: kCmdUnlock)) == false)
    expect("锁定指令不解析强制标志",
           extractForceFlag(packetWithForce(1, command: kCmdLock)) == false)

    // 报文里的密码序号解析
    func packetWithIndex(_ idx: UInt8, command: UInt8 = kCmdUnlockFrom) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: kPacketLen)
        b[0] = 0x42; b[1] = 0x55; b[2] = 0x01; b[3] = command
        b[kIndexOffset] = idx
        return b
    }
    expect("从报文中解析出序号 0",
           extractPasswordIndex(packetWithIndex(0)) == 0)
    expect("从报文中解析出序号 5",
           extractPasswordIndex(packetWithIndex(5)) == 5)
    expect("从报文中解析出序号 255",
           extractPasswordIndex(packetWithIndex(255)) == 255)
    expect("普通解锁不解析序号",
           extractPasswordIndex(packetWithIndex(3, command: kCmdUnlock)) == nil)
    expect("锁定指令不解析序号",
           extractPasswordIndex(packetWithIndex(3, command: kCmdLock)) == nil)

    // 手机指定密码时的排序逻辑
    let base = ["pw-A", "pw-B", "pw-C", "pw-D"]
    expect("指定第 3 个 → 它排到最前",
           promotePassword(base, toFront: 2) == ["pw-C", "pw-A", "pw-B", "pw-D"],
           "实际 \(promotePassword(base, toFront: 2))")
    expect("指定第 1 个 → 顺序不变",
           promotePassword(base, toFront: 0) == base,
           "实际 \(promotePassword(base, toFront: 0))")
    expect("指定最后一个 → 它排到最前",
           promotePassword(base, toFront: 3) == ["pw-D", "pw-A", "pw-B", "pw-C"],
           "实际 \(promotePassword(base, toFront: 3))")
    expect("序号越界 → 原样返回（回退默认顺序）",
           promotePassword(base, toFront: 99) == base,
           "实际 \(promotePassword(base, toFront: 99))")
    expect("负数序号 → 原样返回",
           promotePassword(base, toFront: -1) == base)
    expect("单元素列表不受影响",
           promotePassword(["only"], toFront: 0) == ["only"])
    expect("空列表不崩溃", promotePassword([], toFront: 0).isEmpty)

    // 指定序号后仍应能试到全部密码（回退链完整）
    let promoted = promotePassword(base, toFront: 2)
    expect("排序后仍是同一组密码（无丢失）",
           Set(promoted) == Set(base) && promoted.count == base.count,
           "实际 \(promoted)")

    // 清空后应为空列表（不能把 JSON 文本 "[]" 当密码）
    storePasswords([], account: testAccount)
    let emptied = fetchPasswords(account: testAccount)
    expect("清空后为空列表", emptied.isEmpty, "实际 \(emptied.count) 个：\(emptied)")

    // 清理测试条目
    _ = runProcess("/usr/bin/security",
                   ["delete-generic-password", "-a", testAccount, "-s", kKeychainService])

    print()
    if failed == 0 {
        print("结果: 全部通过 ✓")
        exit(0)
    } else {
        print("结果: \(failed) 项失败 ✗")
        exit(1)
    }
}

// 协议自检：用固定测试密钥对给定的十六进制消息计算 HMAC，供跨语言比对使用
if let idx = args.firstIndex(of: "--selftest"), idx + 1 < args.count {
    let hexString = args[idx + 1]
    var message = Data()
    var i = hexString.startIndex
    while i < hexString.endIndex {
        guard let next = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex) else { break }
        let byteString = hexString[i..<next]
        guard let byte = UInt8(byteString, radix: 16) else {
            FileHandle.standardError.write("无效的十六进制输入\n".data(using: .utf8)!)
            exit(2)
        }
        message.append(byte)
        i = next
    }
    // 与 Android 端 VerifyProtocol.java 使用完全相同的测试密钥：0x00,0x01,...,0x1f
    var keyBytes = [UInt8]()
    for n in 0..<32 { keyBytes.append(UInt8(n)) }
    let testKey = SymmetricKey(data: Data(keyBytes))
    let tag = Data(HMAC<SHA256>.authenticationCode(for: message, using: testKey))
    print(tag.map { String(format: "%02x", $0) }.joined())
    exit(0)
}

if args.contains("--print-token") {
    guard let config = loadConfig() else {
        print("尚未初始化配置，请先运行安装脚本。")
        exit(1)
    }
    print(config.hmacKey)
    exit(0)
}

if args.contains("--add-accessibility") {
    let ok = accessibilityGranted(prompt: true)
    print(ok ? "已获得辅助功能权限。" : "已弹出授权请求，请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 BLEUnlockCmd。")
    exit(0)
}

// 由守护进程自己发起「辅助功能」授权请求。
// 用 prompt:true 让系统弹出授权引导并把记录绑定到本二进制。
if args.contains("--request-accessibility") {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    if trusted {
        print("已授权，无需再操作。")
    } else {
        print("已弹出系统授权引导。")
        print("如果系统设置里没有自动出现条目，请在「辅助功能」列表中点 ＋ 添加：")
        print(CommandLine.arguments[0])
        print("")
        print("注意：如果列表里已有 BLEUnlockCmd 且开关是打开的，但对钩无效，")
        print("请先用「−」删除它，再重新添加一次——旧授权可能绑定了旧版本的程序。")
    }
    exit(trusted ? 0 : 1)
}

// 通知正在运行的守护进程刷新权限状态文件。
// 用户在「系统设置」里刚勾选完时，需要用这个立刻更新 daemon-status.json，
// 否则要等到下一次解锁才会刷新。
if args.contains("--ax-refresh") {
    let payload: [String: String] = ["action": "refresh-ax"]
    if let data = try? JSONSerialization.data(withJSONObject: payload) {
        try? data.write(to: URL(fileURLWithPath: kRefreshRequestPath))
    }
    exit(0)
}

// 完整诊断：把"这个可执行文件自己"看到的权限、钥匙串、锁屏状态全部打印出来。
// 与 --check 的区别是它同时报告更细的判定依据，便于区分是"权限没给对"
// 还是"别的环节出问题"。
if args.contains("--diag") {
    let bundleID = Bundle.main.bundleIdentifier ?? "(无)"
    let exe = CommandLine.arguments[0]
    print("可执行文件 : \(exe)")
    print("Bundle ID  : \(bundleID)")
    print("Bundle 路径: \(Bundle.main.bundlePath)")
    print("")
    let trusted = accessibilityGranted()
    print("AXIsProcessTrusted : \(trusted)")
    print("  → 这一项是 TCC 对本二进制的判定，与「系统设置」里显示的一致")
    print("")
    if let config = loadConfig() {
        print("配置       : 正常（设备名 \(config.deviceName)）")
        if let pw = fetchPassword(account: config.keychainAccount) {
            print("钥匙串密码 : 可读取（\(pw.count) 字符）")
        } else {
            print("钥匙串密码 : 读取失败")
        }
    } else {
        print("配置       : 缺失")
    }
    print("是否锁屏   : \(isScreenLocked() ? "是" : "否")")
    print("")
    print("若上面 AXIsProcessTrusted 为 false，但「系统设置 → 辅助功能」里开关是打开的，")
    print("说明该项授权绑定的是旧版本二进制。请在该列表里删除 BLEUnlockCmd，")
    print("然后重新运行设置向导添加一次。")
    exit(trusted ? 0 : 1)
}

// 供安装脚本查询权限状态。必须由 App bundle 内这个可执行文件自己报告，
// 因为「辅助功能」权限是按二进制（TCC 主体）授予的：另编一个探测小程序去查，
// 得到的是那个程序自己的权限，会永远是「未授权」——这正是之前的误报来源。
if args.contains("--ax-status") {
    exit(accessibilityGranted() ? 0 : 1)
}

// 多密码管理。供设置向导与命令行共用，逻辑只在这里实现一份。
//
//   --passwords list [--json]        列出密码（默认打码）
//   --passwords add   --stdin        从标准输入读一行作为新密码
//   --passwords set   --stdin        整体替换（读一行一个，空行结束）
//   --passwords remove --index N     删除第 N 个（从 1 开始）
//   --passwords clear                清空
if let idx = args.firstIndex(of: "--passwords") {
    let jsonOut = args.contains("--json")
    let account = loadConfig()?.keychainAccount ?? NSUserName()
    let action = (idx + 1 < args.count) ? args[idx + 1] : "list"
    var list = fetchPasswords(account: account)

    /// 读取标准输入中的密码。
    ///
    /// - Parameter single: true 只读一行（add）；false 读到空行或 EOF 为止（set）
    ///
    /// 注意：输入是按行传输的，因此**密码本身不能包含换行符**——
    /// 含换行的密码会被拆成两条，所以这里直接拒绝并报错，而不是静默拆开。
    /// 实践中登录密码含换行极为罕见，界面上的密码框也无法输入换行。
    func readLines(single: Bool) -> [String] {
        var lines: [String] = []
        while let line = readLine(strippingNewline: true) {
            if single {
                if !line.isEmpty { lines.append(line) }
                break
            }
            if line.isEmpty { break }   // 空行结束
            lines.append(line)
        }
        return lines
    }

    switch action {
    case "list":
        // --values：以 JSON 数组输出原始密码，供设置向导精确读取。
        // 不能逐行输出——密码本身可能含换行符，会一条被拆成两条。
        // JSON 会把换行转义，能精确承载任意字符。
        if args.contains("--values") {
            if let data = try? JSONSerialization.data(withJSONObject: list),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                print("[]")
            }
            exit(0)
        }
        if jsonOut {
            printJSON(["count": list.count, "lengths": list.map { $0.count }])
        } else {
            if list.isEmpty {
                print("尚未保存任何密码。")
            } else {
                print("已保存 \(list.count) 个密码（按尝试顺序）：")
                for (n, pw) in list.enumerated() {
                    print("  \(n + 1). \(String(repeating: "•", count: max(pw.count, 1)))  （\(pw.count) 字符）")
                }
            }
        }
        exit(0)

    case "add":
        let newOnes = readLines(single: true)
        guard !newOnes.isEmpty else {
            if jsonOut { printJSON(["ok": false, "error": "没有从标准输入读到密码"]) }
            else { FileHandle.standardError.write("没有从标准输入读到密码\n".data(using: .utf8)!) }
            exit(2)
        }
        list.append(contentsOf: newOnes)
        let ok = storePasswords(list, account: account)
        if jsonOut { printJSON(["ok": ok, "count": list.count]) }
        else { print(ok ? "已添加，共 \(list.count) 个密码。" : "写入钥匙串失败。") }
        exit(ok ? 0 : 1)

    case "set":
        let newList = readLines(single: false)
        guard !newList.isEmpty else {
            if jsonOut { printJSON(["ok": false, "error": "没有从标准输入读到密码"]) }
            else { FileHandle.standardError.write("没有从标准输入读到密码\n".data(using: .utf8)!) }
            exit(2)
        }
        let ok = storePasswords(newList, account: account)
        if jsonOut { printJSON(["ok": ok, "count": newList.count]) }
        else { print(ok ? "已设置为 \(newList.count) 个密码。" : "写入钥匙串失败。") }
        exit(ok ? 0 : 1)

    case "remove":
        guard let vidx = args.firstIndex(of: "--index"), vidx + 1 < args.count,
              let oneBased = Int(args[vidx + 1]), oneBased >= 1, oneBased <= list.count else {
            let msg = "索引无效（范围为 1..\(list.count)）"
            if jsonOut { printJSON(["ok": false, "error": msg]) } else { print(msg) }
            exit(2)
        }
        list.remove(at: oneBased - 1)
        let ok = storePasswords(list, account: account)
        if jsonOut { printJSON(["ok": ok, "count": list.count]) }
        else { print(ok ? "已删除，剩余 \(list.count) 个密码。" : "写入钥匙串失败。") }
        exit(ok ? 0 : 1)

    case "clear":
        let ok = storePasswords([], account: account)
        if jsonOut { printJSON(["ok": ok, "count": 0]) }
        else { print(ok ? "已清空全部密码。" : "写入钥匙串失败。") }
        exit(ok ? 0 : 1)

    default:
        let msg = "未知操作：\(action)（可用：list/add/set/remove/clear）"
        if jsonOut { printJSON(["ok": false, "error": msg]) } else { print(msg) }
        exit(2)
    }
}

if args.contains("--check") {
    guard let config = loadConfig() else {
        print("配置: 缺失（\(kConfigPath)）")
        exit(1)
    }
    print("配置: 正常")
    print("设备名: \(config.deviceName)")
    print("钥匙串账户: \(config.keychainAccount)")
    print("辅助功能权限: \(accessibilityGranted() ? "已授权" : "未授权（解锁会失败）")")
    if let pw = fetchPassword(account: config.keychainAccount) {
        print("登录密码: 已存入钥匙串（\(pw.count) 个字符）")
    } else {
        print("登录密码: 未找到")
    }
    print("当前是否锁屏: \(isScreenLocked() ? "是" : "否")")
    print("")
    print("── 守护进程实际状态（决定解锁能否成功）──")
    // 注意：本进程从终端启动时可能继承了终端的 AX 信任，因此上面那一项
    // 未必代表真正干活的守护进程。真实状态以守护进程自己落盘的内容为准。
    if let data = FileManager.default.contents(atPath: kStatusPath),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let ax = (obj["axTrusted"] as? Bool) ?? false
        let pid = obj["pid"] as? Int ?? -1
        let at = obj["updatedAt"] as? String ?? "?"
        print("守护进程 AX 权限: \(ax ? "已授权 ✓" : "未授权 ✗")")
        print("  记录时间: \(at)  PID: \(pid)")
        if !ax {
            print("  → 解锁会失败。请在「系统设置 → 隐私与安全性 → 辅助功能」")
            print("     中勾选 BLEUnlockCmd；若开关已打开，请先删除该项再重新添加。")
        }
    } else {
        print("守护进程 AX 权限: 未知（守护进程尚未写过状态，可能未运行）")
    }
    exit(0)
}

// --set-key
if let idx = args.firstIndex(of: "--set-key"), idx + 1 < args.count {
    let newKey = args[idx + 1]
    guard Data(base64Encoded: newKey)?.count == 32 else {
        print("错误：密钥必须是 32 字节的 base64 编码字符串。")
        exit(1)
    }
    var config = loadConfig() ?? Config(hmacKey: newKey,
                                        keychainAccount: NSUserName(),
                                        deviceName: Host.current().localizedName ?? "Mac")
    config.hmacKey = newKey
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(config).write(to: URL(fileURLWithPath: kConfigPath))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: kConfigPath)
    print("已更新配对密钥，请在手机 App 中同步修改。")
    exit(0)
}

// --show-token：打印当前密钥；未安装时生成一个临时密钥（配合 --dry-run 测试用）
if args.contains("--show-token") {
    if let config = loadConfig() {
        print(config.hmacKey)
    } else {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        print(Data(bytes).base64EncodedString())
    }
    exit(0)
}

if args.contains("--dry-run") {
    dryRun = true
}

// 测试模式且没有正式配置时，用临时密钥 + 临时账户，方便在未安装的机器上验证
if dryRun && loadConfig() == nil {
    var bytes = [UInt8](repeating: 0, count: 32)
    for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
    let tempConfig = Config(hmacKey: Data(bytes).base64EncodedString(),
                            keychainAccount: NSUserName(),
                            deviceName: "BLEUnlock-DRYRUN")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(tempConfig).write(to: URL(fileURLWithPath: kConfigPath))
    try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                           ofItemAtPath: kConfigPath)
    log("dry-run：已生成临时配置 \(kConfigPath)")
}

guard let config = loadConfig() else {
    print("错误：找不到配置文件 \(kConfigPath)")
    print("请先运行 mac-ble-unlock.sh install 完成初始化。")
    exit(1)
}

guard let keyData = Data(base64Encoded: config.hmacKey), keyData.count == 32 else {
    print("错误：配置文件中的 hmacKey 无效。")
    exit(1)
}

if let idx = args.firstIndex(of: "--device-name"), idx + 1 < args.count {
    var updated = config
    updated.deviceName = args[idx + 1]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(updated).write(to: URL(fileURLWithPath: kConfigPath))
    print("设备名已更新为 \(updated.deviceName)")
    exit(0)
}

let symmetricKey = SymmetricKey(data: keyData)

if !accessibilityGranted() {
    log("警告：尚未获得「辅助功能」权限，解锁不会生效。")
    log("请运行：BLEUnlockCmd --add-accessibility")
}

log("启动 BLEUnlockCmd，设备名「\(config.deviceName)」")

// 把本进程（守护进程）自身的权限判定落盘，供设置向导读取。
// 这一项才是决定"解锁能否成功"的真实状态。
writeDaemonStatus()

let server = PeripheralServer()
server.start(key: symmetricKey, deviceName: config.deviceName)

// 系统唤醒后蓝牙子系统会重新初始化，之前的广播/服务注册常常已经失效，
// 手机端表现为「刚唤醒那几分钟怎么都连不上」。
// 这里监听唤醒通知，立即深度重建 GATT 服务与广播，把盲区压到一次回调的时间。
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    log("[WAKE] 系统唤醒：立即深度重建 BLE 广播")
    server.restartAdvertising(reason: "系统唤醒", deep: true)
}

// 显示器唤醒（合盖/息屏后）不一定伴随 didWake，单独补一条，只做轻量确认。
let screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
) { _ in
    log("[WAKE] 显示器唤醒：确认广播在线")
    server.ensureAdvertising(reason: "显示器唤醒")
}

// 观察者必须一直存活；显式持有，避免被优化掉
_ = (wakeObserver, screenWakeObserver)

// 防止系统空闲休眠：休眠会停掉蓝牙广播，手机就再也连不上了
var sleepAssertion = IOPMAssertionID(0)
let assertionResult = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "BLEUnlockCmd 保持蓝牙可连接" as CFString,
                                                 &sleepAssertion)
if assertionResult == kIOReturnSuccess {
    log("已阻止系统空闲休眠，以保持蓝牙可连接（显示器仍会正常息屏）")
} else {
    log("警告：无法创建防休眠断言，系统休眠后蓝牙将断开")
}

// 进程退出时释放断言
func cleanup() {
    if sleepAssertion != 0 {
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
    }
    log("BLEUnlockCmd 退出")
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { log("收到 SIGINT，退出"); cleanup(); exit(0) }
sigintSource.resume()
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { log("收到 SIGTERM，退出"); cleanup(); exit(0) }
sigtermSource.resume()

// 监视刷新请求：设置向导在用户完成授权后写入该文件，
// 守护进程据此立刻刷新 daemon-status.json，无需重启服务。
let refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    let fm = FileManager.default
    guard fm.fileExists(atPath: kRefreshRequestPath) else { return }
    try? fm.removeItem(atPath: kRefreshRequestPath)
    log("收到权限刷新请求")
    writeDaemonStatus()
    log("权限状态已更新，手机端会立即看到最新结果")
}
RunLoop.main.add(refreshTimer, forMode: .common)

RunLoop.main.run()
