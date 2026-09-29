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

let kPacketLen  = 62                        // 2 magic + 1 ver + 1 cmd + 8 ts + 16 nonce + 32 hmac
let kHmacOffset = 30                        // HMAC 覆盖前 30 字节

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
let kKeychainService = "ble-unlock-cmd"

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

func fetchPassword(account: String) -> String? {
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
    return pw.isEmpty ? nil : pw
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
func performUnlock(reply: @escaping (String) -> Void) {
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
    guard let config = loadConfig(), let password = fetchPassword(account: config.keychainAccount) else {
        log("解锁失败：钥匙串中读不到密码")
        reply("ERR_NO_PW")
        return
    }

    if dryRun {
        log("[dry-run] 校验通过，本应执行解锁（密码 \(password.count) 字符）")
        reply("OK")
        return
    }

    unlockInFlight = true
    log("收到解锁指令，开始执行")

    wakeDisplay()

    // 显示器唤醒后需要一点时间才真正点亮，重试几轮
    var attempt = 0
    let maxAttempts = 8

    func finish(password: String, attempt: Int) {
        log("屏幕已锁定，注入密码（第 \(attempt) 次尝试）")
        fakeKeyStrokes(password)
        unlockInFlight = false
        log("已注入密码并回车，解锁指令完成")
        reply("OK")
    }

    func tick() {
        attempt += 1
        wakeDisplay()

        if isScreenLocked() {
            // 再等 0.4s 让密码输入框获得焦点
            let current = attempt
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                finish(password: password, attempt: current)
            }
            return
        }

        if attempt >= maxAttempts {
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
    case ok(command: UInt8)
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

    return .ok(command: bytes[3])
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

            case .ok(let command):
                switch command {
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
    case .ok(let c): expect("合法解锁包通过校验", c == kCmdUnlock, "命令=\(c)")
    case .failed(let r): expect("合法解锁包通过校验", false, r)
    }

    switch verifyPacket(makePacket(command: kCmdPing), key: testKey) {
    case .ok(let c): expect("PING 包通过校验", c == kCmdPing, "命令=\(c)")
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

RunLoop.main.run()
