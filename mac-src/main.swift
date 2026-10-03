// BLEUnlockCmd — Mac BLE 解锁服务端
//
// 作用：作为 BLE 外设(GATT Server)广播，手机 App 连接后写入一条带 HMAC-SHA256 签名的
//       指令；校验通过则调用与 BLEUnlock 相同的机制自动输入登录密码来解锁屏幕。
//
// 编译：swiftc -O main.swift -o BLEUnlockCmd
// 依赖：CoreBluetooth / CryptoKit / CoreGraphics / IOKit（全部为系统框架）

import Foundation
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

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

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
        try? data.write(to: URL(fileURLWithPath: kStatusPath))
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: kStatusPath)
    }
    log("守护进程权限自检：AXIsProcessTrusted = \(trusted)")
    if !trusted {
        log("  ⚠️ 本进程无法模拟键盘输入，解锁会失败。")
        log("     请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 BLEUnlockCmd；")
        log("     若开关已是打开状态，请先删除该项再重新添加（旧授权可能绑定到旧版本）。")
    }
}

func log(_ message: String) {
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

var unlockInFlight = false

/// 自动解锁：唤醒屏幕 -> 确认处于锁屏 -> 注入密码
/// - Parameter preferredIndex: 优先尝试第几个密码（0 基）。为 nil 时按保存顺序。
///   手机端可以指定"用哪个密码解锁"；若指定的序号越界或该密码不对，
///   会自动回退到按原顺序继续尝试其余密码。
func performUnlock(preferredIndex: UInt8? = nil,
                   reply: @escaping (String) -> Void) {
    guard !unlockInFlight else {
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
        log("[dry-run] 校验通过，共 \(passwords.count) 个密码，本应逐个尝试")
        reply("OK")
        return
    }

    unlockInFlight = true
    writeDaemonStatus()
    log("收到解锁指令，开始执行（\(passwords.count) 个密码待尝试）")

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
            log("已注入密码并回车，解锁指令完成")
        } else {
            log("第 \(tried + 1) 个密码生效，解锁指令完成")
        }
        reply("OK")
    }

    /// 依次尝试每个密码；全部失败则回报
    func tryPassword(at index: Int) {
        guard index < passwords.count else {
            unlockInFlight = false
            log("已尝试全部 \(passwords.count) 个密码，屏幕仍未解锁")
            reply("ERR_ALL_PW")
            return
        }

        let isLast = (index == passwords.count - 1)
        log("注入第 \(index + 1)/\(passwords.count) 个密码（\(passwords[index].count) 字符）")

        // 尝试前先清空输入框：上一个密码若错误，字段里可能残留内容。
        // 用 Esc 清空比逐字符删除可靠。
        if index > 0 {
            sendKey(0x35)   // Esc
            Thread.sleep(forTimeInterval: 0.25)
        }

        fakeKeyStrokes(passwords[index])

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                tryPassword(at: 0)
            }
            return
        }

        if wakeAttempt >= maxWakeAttempts {
            unlockInFlight = false
            log("解锁中止：屏幕未处于锁定状态（可能已由用户手动解锁）")
            reply("NOT_LOCKED")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tick)
    }

    tick()
}

func performLock(reply: @escaping (String) -> Void) {
    if dryRun {
        log("[dry-run] 本应锁定屏幕，已跳过")
        reply("OK")
        return
    }
    log("收到锁定指令")
    // 通过锁屏私有 API 锁定；若不可用则退回屏保
    let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW)
    if let handle = handle, let sym = dlsym(handle, "SACLockScreenImmediate") {
        typealias LockFn = @convention(c) () -> Int32
        let lock = unsafeBitCast(sym, to: LockFn.self)
        let result = lock()
        dlclose(handle)
        log("SACLockScreenImmediate 返回 \(result)")
        reply(result == 0 ? "OK" : "ERR_LOCK")
    } else {
        log("login.framework 不可用，改用屏保锁定")
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
    /// command 指令；index 为字节 28 的密码序号（仅指定密码时有效）
    case ok(command: UInt8, index: UInt8?)
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

    return .ok(command: bytes[3], index: extractPasswordIndex(bytes))
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

    func start(key: SymmetricKey, deviceName: String) {
        self.key = key
        self.deviceName = deviceName
        manager = CBPeripheralManager(delegate: self, queue: nil)
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
        manager.add(service)
    }

    private func startAdvertising() {
        guard manager.state == .poweredOn else { return }
        guard !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [kServiceUUID],
            CBAdvertisementDataLocalNameKey: deviceName,
        ])
    }

    func setStatus(_ text: String) {
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

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            log("蓝牙已就绪，注册 GATT 服务")
            buildService()
            startAdvertising()
            // 定期重新广播，避免锁屏/系统休眠后广播被停掉
            advertiseTimer?.invalidate()
            advertiseTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.startAdvertising()
            }
            RunLoop.main.add(advertiseTimer!, forMode: .common)
            setStatus("READY")
        case .poweredOff:
            log("蓝牙已关闭，等待重新开启")
        case .unauthorized:
            log("蓝牙权限被拒绝，请在「系统设置 → 隐私与安全性 → 蓝牙」中授权")
        default:
            break
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            log("广播失败: \(error.localizedDescription)")
        } else {
            log("正在广播，等待手机连接（设备名 \(deviceName)）")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            log("添加服务失败: \(error.localizedDescription)")
        } else {
            log("GATT 服务已就绪（Service \(kServiceUUID.uuidString)）")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        log("手机已订阅状态特征: \(central.identifier.uuidString)")
        setStatus("CONNECTED")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        log("手机取消订阅状态特征")
    }

    private var pendingStatus: String?

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        // 上一次 updateValue 因发送队列满而失败，这里补发
        guard let text = pendingStatus, manager.state == .poweredOn, let characteristic = statusChar else { return }
        pendingStatus = nil
        manager.updateValue(text.data(using: .utf8)!, for: characteristic, onSubscribedCentrals: nil)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard request.characteristic.uuid == kCharCommandUUID else { continue }
            let data = request.value ?? Data()
            log("收到写入 \(data.count) 字节")

            // 无论校验结果如何都要应答；带应答写不回会让手机端卡住
            peripheral.respond(to: request, withResult: .success)

            let result = verifyPacket(data, key: key)
            switch result {
            case .failed(let reason):
                log("校验失败: \(reason)")
                setStatus(reason)

            case .ok(let command, let index):
                switch command {
                case kCmdUnlockFrom:
                    // 手机指定了要用第几个密码
                    setStatus("UNLOCKING")
                    performUnlock(preferredIndex: index) { status in
                        self.setStatus(status)
                        log("解锁结果: \(status)")
                    }
                case kCmdUnlock:
                    setStatus("UNLOCKING")
                    performUnlock { status in
                        self.setStatus(status)
                        log("解锁结果: \(status)")
                    }
                case kCmdLock:
                    setStatus("LOCKING")
                    performLock { status in
                        self.setStatus(status)
                        log("锁定结果: \(status)")
                    }
                case kCmdPing:
                    log("收到 PING")
                    setStatus("PONG")
                default:
                    log("未知指令 0x\(String(command, radix: 16))")
                    setStatus("ERR_CMD")
                }
            }
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveRead request: CBATTRequest) {
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
    print("BLEUnlockCmd 1.0.0")
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
    case .ok(let c, let i):
        expect("合法解锁包通过校验", c == kCmdUnlock, "命令=\(c)")
        expect("普通解锁不带密码序号", i == nil, "实际 \(String(describing: i))")
    case .failed(let r): expect("合法解锁包通过校验", false, r)
    }

    switch verifyPacket(makePacket(command: kCmdPing), key: testKey) {
    case .ok(let c, _): expect("PING 包通过校验", c == kCmdPing, "命令=\(c)")
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
