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
    static let keychainService = "ble-unlock-cmd"
    static let serviceLabel = "jp.sone.bleunlockcmd"
    static let bundleID = "jp.sone.bleunlockcmd"
}

// MARK: - 小工具

func run(_ path: String, _ args: [String], input: String? = nil) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    if input != nil {
        let inPipe = Pipe()
        p.standardInput = inPipe
        do { try p.run() } catch { return (-1, "") }
        inPipe.fileHandleForWriting.write(input!.data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
    } else {
        do { try p.run() } catch { return (-1, "") }
    }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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

/// 诊断日志。写入 ~/Library/Logs/BLEUnlockInstaller.log。
/// 安装器在图形环境下出错时没有任何终端输出，必须留痕才能排查。
func diag(_ message: String) {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BLEUnlockInstaller.log")
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
        // 先删旧条目再写入（与命令行版脚本行为一致）
        _ = run("/usr/bin/security",
                ["delete-generic-password", "-a", account, "-s", Const.keychainService])
        let r = run("/usr/bin/security",
                    ["add-generic-password", "-U",
                     "-a", account,
                     "-s", Const.keychainService,
                     "-l", "BLEUnlockCmd",
                     "-w", password])
        if r.code != 0 {
            return .failed("写入钥匙串失败，请确认密码是否正确后重试。")
        }
        log("登录密码已存入钥匙串")
        return .ok("密码已保存")
    }

    func hasPassword() -> Bool {
        run("/usr/bin/security",
            ["find-generic-password", "-a", NSUserName(), "-s", Const.keychainService]).code == 0
    }

    // ---- 5. 辅助功能权限 ----

    func hasAccessibility() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Const.serviceBin.path) else { return false }
        return run(Const.serviceBin.path, ["--ax-status"]).code == 0
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
