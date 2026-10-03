// BLE Unlock 安装器
//
// 一个带图形界面的自安装 App：双击后完成全部配置，不需要终端，
// 也不需要用户预先安装 Xcode 命令行工具（服务端二进制已预编译在包内）。
//
// 安装内容：
//   ~/Library/Application Support/BLEUnlockCmd/BLEUnlockCmd.app   服务端
//   ~/Library/Application Support/BLEUnlockCmd/config.json        配对密钥
//   ~/Library/LaunchAgents/jp.sone.bleunlockcmd.plist             开机自启
//   钥匙串 ble-unlock-cmd / <用户名>                               登录密码

import Cocoa

// MARK: - 常量

enum Const {
    /// 支持重定位，便于自动化测试在临时目录里跑同一份安装逻辑。
    /// 正常运行时这两个环境变量不存在，路径就是标准用户目录。
    static var supportDir: URL {
        if let o = ProcessInfo.processInfo.environment["BLEUNLOCK_SUPPORT_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BLEUnlockCmd")
    }
    static var serviceApp: URL { supportDir.appendingPathComponent("BLEUnlockCmd.app") }
    static var serviceBin: URL {
        serviceApp.appendingPathComponent("Contents/MacOS/BLEUnlockCmd")
    }
    static var configFile: URL { supportDir.appendingPathComponent("config.json") }
    static var launchAgent: URL {
        if let o = ProcessInfo.processInfo.environment["BLEUNLOCK_LAUNCH_AGENT"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/jp.sone.bleunlockcmd.plist")
    }
    static var keychainService: String {
        if let o = ProcessInfo.processInfo.environment["BLEUNLOCK_KEYCHAIN_SERVICE"], !o.isEmpty {
            return o
        }
        return "ble-unlock-cmd"
    }
    static let serviceLabel = "jp.sone.bleunlockcmd"
    static let bundleID = "jp.sone.bleunlockcmd"
}

// MARK: - 小工具

/// 带 stderr 的执行结果。失败时 stderr 往往就是原因，不能丢。
struct RunResult {
    var code: Int32
    var out: String
    var err: String
    /// 便于诊断的一行摘要
    var summary: String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == 0 { return "ok" }
        return "退出码 \(code)" + (e.isEmpty ? "" : "：\(e)")
    }
}

func runFull(_ path: String, _ args: [String], input: String? = nil) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    if input != nil {
        let inPipe = Pipe()
        p.standardInput = inPipe
        do { try p.run() } catch {
            return RunResult(code: -1, out: "", err: "\(error.localizedDescription)")
        }
        inPipe.fileHandleForWriting.write(input!.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    } else {
        do { try p.run() } catch {
            return RunResult(code: -1, out: "", err: "\(error.localizedDescription)")
        }
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return RunResult(code: p.terminationStatus,
                     out: String(data: outData, encoding: .utf8) ?? "",
                     err: String(data: errData, encoding: .utf8) ?? "")
}

func run(_ path: String, _ args: [String], input: String? = nil) -> (code: Int32, out: String) {
    let r = runFull(path, args, input: input)
    return (r.code, r.out)
}

/// 安装 App 内遗留的旧版本文件（重启服务用）
func killServiceProcess() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-f", "BLEUnlockCmd.app/Contents/MacOS/BLEUnlockCmd"]
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    try? p.run()
    p.waitUntilExit()
}

/// 把 App 带到前台。
///
/// 从 Finder／挂载的 DMG 启动时，App 常常不在前台，此时 NSAlert.runModal()
/// 的窗口可能根本不显示（表现为「进程在跑但没有窗口」）。
/// macOS 14 起 activate(ignoringOtherApps:) 已废弃，需要配合
/// NSRunningApplication.activate 与 activateAllWindows 才可靠。
func bringToFront() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
}

/// 统一对话框入口：负责置前 + 显示 + 记录日志。
///
/// NSAlert 自己会弹面板，无需另建窗口；真正容易出问题的是「App 不在前台」，
/// 此时面板可能根本不显示（表现为「进程在跑但没有窗口」）。
func present(title: String,
             message: String,
             buttons: [String],
             accessory: NSView? = nil,
             style: NSAlert.Style = .informational) -> Int {
    diag("显示对话框: \(title)")

    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = style
    for b in buttons { alert.addButton(withTitle: b) }
    if let accessory = accessory { alert.accessoryView = accessory }

    bringToFront()
    let response = alert.runModal()
    diag("对话框返回: \(response.rawValue)")
    return response.rawValue
}

func alert(_ title: String, _ message: String, style: NSAlert.Style = .informational) {
    _ = present(title: title, message: message, buttons: ["好"], style: style)
}

/// 诊断日志。写入 ~/Library/Logs/BLEUnlockSetup.log。
/// 安装器在图形环境下出错时没有任何终端输出，必须留痕才能排查。
func diag(_ message: String) {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BLEUnlockSetup.log")
    let line = "[\(Date())] \(message)\n"
    if let h = try? FileHandle(forWritingTo: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.write(to: path, atomically: true, encoding: .utf8)
    }
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

func confirm(_ title: String, _ message: String, okTitle: String) -> Bool {
    present(title: title, message: message, buttons: [okTitle, "退出"])
        == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}

// MARK: - 安装逻辑

enum StepResult {
    case ok(String)
    case failed(String)
}

struct Installer {

    var log: (String) -> Void

    // ---- 1. 复制服务端 ----

    func installService() -> StepResult {
        let fm = FileManager.default
        let res = Bundle.main.resourceURL!

        // 已存在则先停服务并移除旧版本
        if fm.fileExists(atPath: Const.serviceApp.path) {
            log("检测到已安装，正在更新…")
            stopService()
            try? fm.removeItem(at: Const.serviceApp)
        }

        do {
            try fm.createDirectory(at: Const.supportDir,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // 只复制服务端可执行文件，App 外壳（Info.plist 等）由安装器生成，
            // 这样版本升级时结构可控，也避免依赖包内的相对布局
            let binDir = Const.serviceApp.appendingPathComponent("Contents/MacOS")
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: Const.serviceApp.appendingPathComponent("Contents/Resources"),
                withIntermediateDirectories: true)

            guard let srcBin = Bundle.main.url(forResource: "BLEUnlockCmd", withExtension: nil) else {
                return .failed("安装包内缺少服务端程序（BLEUnlockCmd）")
            }
            try fm.copyItem(at: srcBin, to: Const.serviceBin)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Const.serviceBin.path)
        } catch {
            return .failed("复制服务端失败：\(error.localizedDescription)")
        }

        // Info.plist：蓝牙权限说明是 macOS 弹出授权框的前提
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>BLEUnlockCmd</string>
            <key>CFBundleIdentifier</key><string>\(Const.bundleID)</string>
            <key>CFBundleName</key><string>BLEUnlockCmd</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>\(AppInfo.serviceVersion)</string>
            <key>CFBundleVersion</key><string>1</string>
            <key>LSMinimumSystemVersion</key><string>11.0</string>
            <key>LSUIElement</key><true/>
            <key>NSBluetoothAlwaysUsageDescription</key>
            <string>BLEUnlockCmd 需要通过蓝牙接收手机发来的解锁指令。</string>
            <key>NSBluetoothPeripheralUsageDescription</key>
            <string>BLEUnlockCmd 需要通过蓝牙接收手机发来的解锁指令。</string>
        </dict>
        </plist>
        """
        do {
            try plist.write(to: Const.serviceApp.appendingPathComponent("Contents/Info.plist"),
                            atomically: true, encoding: .utf8)
        } catch {
            return .failed("写入 Info.plist 失败：\(error.localizedDescription)")
        }

        // 能力标记：安装器靠它判断二进制是否支持 --ax-status
        try? "name=BLEUnlockCmd\nversion=\(AppInfo.serviceVersion)\nfeatures=ax-status\n"
            .write(to: Const.serviceApp.appendingPathComponent("Contents/Resources/capabilities"),
                   atomically: true, encoding: .utf8)

        // 临时签名：辅助功能权限与签名绑定，签名稳定则权限不会因重装失效。
        // 直接调用 codesign，不经 shell——避免触发「终端想控制其他 App」的授权提示。
        _ = run("/usr/bin/codesign",
                ["--force", "--sign", "-", "--identifier", Const.bundleID, Const.serviceApp.path])

        log("服务端已安装")
        return .ok("服务端已安装")
    }

    // ---- 2. 配对密钥 ----

    func ensureKey() -> StepResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: Const.configFile.path) {
            log("保留原有配对密钥")
            return .ok("已保留原有配对密钥")
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        let key = Data(bytes).base64EncodedString()

        var computerName = Host.current().localizedName ?? "Mac"
        let sc = run("/usr/sbin/scutil", ["--get", "ComputerName"])
        if sc.code == 0, !sc.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            computerName = sc.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let account = NSUserName()

        let json = """
        {
          "deviceName" : "BLEUnlock-\(computerName)",
          "hmacKey" : "\(key)",
          "keychainAccount" : "\(account)"
        }
        """
        do {
            try json.write(to: Const.configFile, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Const.configFile.path)
        } catch {
            return .failed("写入配置失败：\(error.localizedDescription)")
        }
        log("已生成配对密钥")
        return .ok("已生成配对密钥")
    }

    // ---- 3. 开机自启 ----

    func installLaunchAgent() -> StepResult {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Const.serviceLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(Const.serviceBin.path)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Interactive</string>
            <key>StandardErrorPath</key><string>/dev/null</string>
            <key>StandardOutPath</key><string>/dev/null</string>
        </dict>
        </plist>
        """
        do {
            let dir = Const.launchAgent.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try plist.write(to: Const.launchAgent, atomically: true, encoding: .utf8)
        } catch {
            return .failed("写入开机自启配置失败：\(error.localizedDescription)")
        }
        log("已设置开机自启")
        return .ok("已设置开机自启")
    }

    func stopService() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(Const.serviceLabel)"])
        killServiceProcess()
    }

    func startService() {
        _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", Const.launchAgent.path])
        _ = run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Const.serviceLabel)"])
    }

    // ---- 4. 登录密码 ----

    func storePassword(_ password: String) -> StepResult {
        let account = NSUserName()

        // 直接带 -U 写入（存在则原地更新）。
        // 刻意不「先删后加」：一旦写入失败，用户原有的密码条目就丢了。
        let r = runFull("/usr/bin/security",
                        ["add-generic-password", "-U",
                         "-a", account,
                         "-s", Const.keychainService,
                         "-l", "BLEUnlockCmd",
                         "-w", password])
        if r.code != 0 {
            log("写入钥匙串失败：\(r.summary)")
            return .failed("""
            写入钥匙串失败（\(r.summary)）。

            最常见的原因是钥匙串被锁定。请打开「钥匙串访问」解锁后重试。
            """)
        }

        // 立刻回读确认。密码写错是「解锁静默失败」的头号原因。
        guard let readBack = verifyPassword() else {
            return .failed("""
            密码写入后无法回读，钥匙串可能处于锁定状态。
            请解锁「钥匙串访问」后重试。
            """)
        }
        if readBack != password {
            log("警告：回读内容与输入不一致（长度 \(readBack.count) vs \(password.count)）")
            return .failed("""
            钥匙串回读的内容与输入不一致：
              输入长度 \(password.count)，回读长度 \(readBack.count)

            请重新运行本 App 再试一次。
            """)
        }

        log("登录密码已存入钥匙串（长度 \(readBack.count)，已回读确认）")
        return .ok("密码已保存并验证")
    }

    func hasPassword() -> Bool {
        run("/usr/bin/security",
            ["find-generic-password", "-a", NSUserName(), "-s", Const.keychainService]).code == 0
    }

    /// 回读钥匙串里的密码，确认写入成功。
    /// 密码写错是「解锁静默失败」最常见的原因，装完立刻验证一次能省掉大量排查。
    @discardableResult
    func verifyPassword() -> String? {
        let r = run("/usr/bin/security",
                    ["find-generic-password", "-a", NSUserName(),
                     "-s", Const.keychainService, "-w"])
        guard r.code == 0 else {
            log("回读密码失败（退出码 \(r.code)）")
            return nil
        }
        var pw = r.out
        while pw.hasSuffix("\n") || pw.hasSuffix("\r") { pw.removeLast() }
        log("已回读钥匙串密码，长度 \(pw.count)")
        return pw.isEmpty ? nil : pw
    }

    // ---- 5. 辅助功能权限 ----

    /// 服务端二进制是否支持 --ax-status 查询。
    ///
    /// 必须用能力标记文件判断，不能直接调用后看结果：旧版二进制不认识这个参数，
    /// 会把 `--ax-status` 当成普通启动参数，于是**真的把服务跑起来并常驻**，
    /// 留下一个孤儿进程。也不能 grep 二进制——Swift 会合并参数字符串。
    private func serviceSupportsAxStatus() -> Bool {
        let caps = Const.serviceApp.appendingPathComponent("Contents/Resources/capabilities")
        guard let text = try? String(contentsOf: caps, encoding: .utf8) else { return false }
        return text.contains("ax-status")
    }

    /// 守护进程状态文件路径（由服务端自己写入）
    static var daemonStatusFile: URL {
        Const.supportDir.appendingPathComponent("daemon-status.json")
    }

    /// 读取守护进程自己报告的辅助功能权限状态。
    ///
    /// 为什么不能直接问二进制：TCC 的辅助功能信任**会从父进程继承**。
    /// 设置向导自身是受信任的（用户在系统设置里勾选了它，或从终端启动而继承了终端），
    /// 它 fork 出来的子进程也会报告"已授权"——但真正干活的守护进程由 launchd 启动，
    /// 不受此信任，实际是未授权。这正是"向导说已授权、手机却报缺少权限"的原因。
    ///
    /// 因此以守护进程自己落盘的状态为准。
    func daemonAccessibility() -> Bool? {
        guard let data = FileManager.default.contents(atPath: Self.daemonStatusFile.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ax = obj["axTrusted"] as? Bool else {
            return nil
        }
        return ax
    }

    /// 删除守护进程状态文件，确保随后读到的是本次启动后的新状态
    func clearDaemonStatus() {
        try? FileManager.default.removeItem(at: Self.daemonStatusFile)
    }

    /// 旧接口：子进程视角的判定，仅作为守护进程尚未报告时的兜底参考。
    /// **不要用它来判断解锁能否成功**。
    func childProcessAccessibility() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Const.serviceBin.path) else { return false }
        guard serviceSupportsAxStatus() else {
            log("服务端版本过旧，无法查询权限状态（需重新安装）")
            return false
        }
        let r = runFull(Const.serviceBin.path, ["--ax-status"])
        guard r.code == 0 || r.code == 1 else {
            log("权限查询异常：\(r.summary)")
            return false
        }
        return r.code == 0
    }

    /// 让守护进程自己发起「辅助功能」授权请求。
    ///
    /// 这比让用户手动在系统设置里添加可靠：手动添加时用户容易选中外层 App 或
    /// 找错路径，而由守护进程自己调用 AXIsProcessTrustedWithOptions(prompt: true)，
    /// 系统会把授权记录绑定到正确的主体上。
    func requestAccessibilityFromDaemon() -> String {
        guard FileManager.default.isExecutableFile(atPath: Const.serviceBin.path) else {
            return "服务端未安装"
        }
        let r = runFull(Const.serviceBin.path, ["--request-accessibility"])
        let combined = (r.out + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
        log("守护进程授权请求：\(r.summary)")
        return combined
    }

    /// 请求守护进程刷新权限状态（用户在系统设置里授权后调用）
    func requestDaemonRefresh() {
        let path = Const.supportDir.appendingPathComponent("refresh.request")
        try? "refresh-ax".write(to: path, atomically: true, encoding: .utf8)
    }

    /// 等待守护进程写出状态文件（服务启动后需要一点时间）
    func waitForDaemonStatus(timeout: TimeInterval = 12) -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ax = daemonAccessibility() { return ax }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return daemonAccessibility()
    }

    func openAccessibilitySettings() {
        _ = run("/usr/bin/open",
                ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    }

    // ---- 令牌 ----

    func pairingToken() -> String? {
        guard let data = FileManager.default.contents(atPath: Const.configFile.path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = obj["hmacKey"] as? String else { return nil }
        return key
    }
}

enum AppInfo {
    /// 由 build-installer.sh 在编译时写入（见 BuildInfo.swift）
    static let serviceVersion = BuildInfo.serviceVersion
    static let installerVersion = BuildInfo.installerVersion
}
