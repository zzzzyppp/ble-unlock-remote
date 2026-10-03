// 安装流程的端到端测试（控制台，不启动界面）
//
// 用真实的 Installer 代码与真实的服务端二进制，在临时目录里跑完整流程
// （安装服务端 → 生成密钥 → 开机自启 → 写入钥匙串 → 回读验证）。
//
// 通过环境变量重定向，避免触碰用户的真实安装与真实密码条目：
//   BLEUNLOCK_SUPPORT_DIR / BLEUNLOCK_LAUNCH_AGENT / BLEUNLOCK_KEYCHAIN_SERVICE
//
// 顶层语句必须位于名为 main.swift 的文件，该名字已被 App 入口占用，
// 因此这里包成函数，由 test/main.swift 调用。

import Cocoa

func runInstallerTests() {
    var failures = 0

    func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)  \(detail)")
            failures += 1
        }
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func mode(_ url: URL) -> Int {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    print("=== 安装流程端到端测试 ===")
    print("  支持目录:     \(Const.supportDir.path)")
    print("  LaunchAgent:  \(Const.launchAgent.path)")
    print("  钥匙串服务名: \(Const.keychainService)")
    print()

    let installer = Installer(log: { print("     [log] \($0)") })
    let testPassword = "test-pw-\(Int(Date().timeIntervalSince1970))"

    // ---- 1. 安装服务端 ----
    print("== 1. 安装服务端 ==")
    switch installer.installService() {
    case .failed(let e): check("installService", false, e)
    case .ok: check("installService", true)
    }
    check("服务端 bundle 存在", exists(Const.serviceApp))
    check("可执行文件存在", exists(Const.serviceBin))
    check("可执行权限 755", mode(Const.serviceBin) == 0o755,
          "实际 \(String(mode(Const.serviceBin), radix: 8))")

    let infoPlist = (try? String(contentsOf: Const.serviceApp
        .appendingPathComponent("Contents/Info.plist"), encoding: .utf8)) ?? ""
    check("服务端为完整 app（含 Info.plist）",
          exists(Const.serviceApp.appendingPathComponent("Contents/Info.plist")))
    check("服务端含 PkgInfo",
          exists(Const.serviceApp.appendingPathComponent("Contents/PkgInfo")))
    check("Info.plist 含 CFBundleIdentifier", infoPlist.contains(Const.bundleID))
    check("Info.plist 含蓝牙权限说明", infoPlist.contains("NSBluetoothAlwaysUsageDescription"))

    let capsURL = Const.serviceApp.appendingPathComponent("Contents/Resources/capabilities")
    let caps = (try? String(contentsOf: capsURL, encoding: .utf8)) ?? ""
    check("capabilities 含 ax-status", caps.contains("ax-status"), "内容: \(caps)")

    let ver = runFull(Const.serviceBin.path, ["--version"])
    check("装好的服务端可运行", ver.code == 0, ver.summary)
    check("版本输出正常", ver.out.contains("BLEUnlockCmd"), ver.out)

    let ax = runFull(Const.serviceBin.path, ["--ax-status"])
    check("--ax-status 可查询（退出码 0/1）", ax.code == 0 || ax.code == 1,
          "退出码 \(ax.code) \(ax.err)")

    // ---- 2. 配对密钥 ----
    print()
    print("== 2. 配对密钥 ==")
    switch installer.ensureKey() {
    case .failed(let e): check("ensureKey", false, e)
    case .ok: check("ensureKey", true)
    }
    check("config.json 存在", exists(Const.configFile))
    check("config.json 权限 600", mode(Const.configFile) == 0o600,
          "实际 \(String(mode(Const.configFile), radix: 8))")

    var firstKey = ""
    if let data = FileManager.default.contents(atPath: Const.configFile.path),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        firstKey = obj["hmacKey"] as? String ?? ""
        check("hmacKey 为 32 字节 base64",
              Data(base64Encoded: firstKey)?.count == 32,
              "解码长度 \(Data(base64Encoded: firstKey)?.count ?? -1)")
        check("deviceName 以 BLEUnlock- 开头",
              (obj["deviceName"] as? String)?.hasPrefix("BLEUnlock-") ?? false,
              "实际 \(obj["deviceName"] ?? "nil")")
        check("keychainAccount 非空",
              !((obj["keychainAccount"] as? String) ?? "").isEmpty)
    } else {
        check("config.json 可解析", false)
    }
    check("配对令牌可读取", installer.pairingToken() == firstKey && !firstKey.isEmpty)

    // ---- 3. 开机自启 ----
    print()
    print("== 3. 开机自启 ==")
    switch installer.installLaunchAgent() {
    case .failed(let e): check("installLaunchAgent", false, e)
    case .ok: check("installLaunchAgent", true)
    }
    check("plist 存在", exists(Const.launchAgent))
    if let data = FileManager.default.contents(atPath: Const.launchAgent.path),
       let parsed = try? PropertyListSerialization.propertyList(
           from: data, options: [], format: nil) as? [String: Any] {
        check("plist 可解析", true)
        check("Label 正确", parsed["Label"] as? String == Const.serviceLabel)
        check("RunAtLoad", (parsed["RunAtLoad"] as? Bool) == true)
        check("KeepAlive", (parsed["KeepAlive"] as? Bool) == true)
        check("ProgramArguments 指向服务端",
              (parsed["ProgramArguments"] as? [String])?.first == Const.serviceBin.path)
    } else {
        check("plist 可解析", false)
    }

    // ---- 4. 钥匙串与多密码（真实写入，但用临时服务名）----
    //
    // 这里刻意使用向导实际调用的 loadPasswords / savePasswords，
    // 而不是自己拼 security 命令——保证测的是真实路径。
    print()
    print("== 4. 登录密码（多密码）==")

    let multi = ["first-password", "second-password", "third-password"]
    check("savePasswords 成功", installer.savePasswords(multi),
          installer.lastPasswordError)
    let loaded = installer.loadPasswords()
    check("读回数量正确", loaded.count == multi.count, "实际 \(loaded.count)")
    check("顺序与内容一致", loaded == multi, "实际 \(loaded)")
    check("密码未因换行被拆开", loaded.allSatisfy { !$0.isEmpty },
          "出现空密码项")

    // 含换行的密码必须被明确拒绝，而不是静默拆成两条
    check("拒绝含换行的密码",
          installer.savePasswords(["line-one\nline-two", "normal"]) == false)
    check("拒绝后原密码未被破坏", installer.loadPasswords() == multi,
          "实际 \(installer.loadPasswords())")

    // 特殊字符（引号、反斜杠、空格、中文）必须能原样存取
    let tricky = ["p@ss w0rd", "with\"quote", "with\\backslash", "中文密码", "$dollar`tick"]
    check("特殊字符可保存", installer.savePasswords(tricky), installer.lastPasswordError)
    check("特殊字符原样读回", installer.loadPasswords() == tricky,
          "实际 \(installer.loadPasswords())")

    // 单个密码（最常见情形）仍要正常
    check("单密码可用", installer.savePasswords(["only-one"]), installer.lastPasswordError)
    check("单密码读回正确", installer.loadPasswords() == ["only-one"])
    _ = installer.savePasswords(multi)

    // 空列表必须被拒绝，否则解锁会失败
    check("拒绝空密码列表", installer.savePasswords([]) == false)
    check("拒绝后原密码仍在", installer.loadPasswords() == multi)

    // 顺序敏感：把列表倒过来应如实保存
    _ = installer.savePasswords(multi.reversed())
    check("顺序可调整", installer.loadPasswords() == multi.reversed(),
          "实际 \(installer.loadPasswords())")
    _ = installer.savePasswords(multi)

    // 旧格式兼容：钥匙串里直接放明文（老版本就是这么存的）
    _ = runFull("/usr/bin/security",
                ["add-generic-password", "-U", "-a", NSUserName(),
                 "-s", Const.keychainService, "-w", "legacy-plain-password"])
    check("旧格式单密码可识别", installer.loadPasswords() == ["legacy-plain-password"],
          "实际 \(installer.loadPasswords())")
    _ = installer.savePasswords(multi)

    // ---- 5. 升级幂等 ----
    print()
    print("== 5. 升级幂等 ==")
    switch installer.installService() {
    case .failed(let e): check("升级 installService", false, e)
    case .ok: check("升级 installService", true)
    }
    switch installer.ensureKey() {
    case .failed(let e): check("升级 ensureKey", false, e)
    case .ok: check("升级 ensureKey", true)
    }
    var thirdKey = ""
    if let data = FileManager.default.contents(atPath: Const.configFile.path),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        thirdKey = obj["hmacKey"] as? String ?? ""
    }
    check("升级后配对密钥保持不变", thirdKey == firstKey && !firstKey.isEmpty)
    check("升级后服务端仍可运行", runFull(Const.serviceBin.path, ["--version"]).code == 0)
    check("升级后 capabilities 仍在", exists(capsURL))

    // ---- 6. 签名 ----
    print()
    print("== 6. 签名 ==")
    check("服务端签名有效",
          runFull("/usr/bin/codesign", ["-v", Const.serviceApp.path]).code == 0)

    // ---- 7. 旧版二进制的防护 ----
    //
    // 装上旧版服务端（没有 capabilities 标记）时，绝不能用 --ax-status 去探它：
    // 旧二进制不认这个参数，会把它当成启动参数而**常驻运行**，留下孤儿进程。
    print()
    print("== 7. 旧版二进制防护 ==")
    let capsBackup = (try? String(contentsOf: capsURL, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: capsURL)

    // 注意：这里用的是 childProcessAccessibility —— 子进程视角的判定。
    // 真正决定解锁能否成功的是守护进程自己的判定（daemonAccessibility），
    // 因为 TCC 的信任会从父进程继承，子进程会假报已授权。
    check("移除 capabilities 后子进程查询返回 false",
          installer.childProcessAccessibility() == false)

    // 守护进程状态文件的读取
    installer.clearDaemonStatus()
    check("清除后 daemonAccessibility 返回 nil", installer.daemonAccessibility() == nil)
    let fakeStatus = Const.supportDir.appendingPathComponent("daemon-status.json")
    try? "{\"axTrusted\": false, \"pid\": 1}".write(to: fakeStatus, atomically: true, encoding: .utf8)
    check("能读到 axTrusted=false", installer.daemonAccessibility() == false)
    try? "{\"axTrusted\": true, \"pid\": 1}".write(to: fakeStatus, atomically: true, encoding: .utf8)
    check("能读到 axTrusted=true", installer.daemonAccessibility() == true)
    try? "不是 JSON".write(to: fakeStatus, atomically: true, encoding: .utf8)
    check("损坏的状态文件返回 nil", installer.daemonAccessibility() == nil)
    installer.clearDaemonStatus()

    // 关键：不能留下 --ax-status 孤儿进程
    let orphans = runFull("/usr/bin/pgrep", ["-fl", "--ax-status"])
    let orphanText = orphans.out.trimmingCharacters(in: .whitespacesAndNewlines)
    check("未产生 --ax-status 孤儿进程", orphanText.isEmpty,
          "发现: \(orphanText)")

    // 恢复标记，确认防护不会误伤正常情况
    try? capsBackup.write(to: capsURL, atomically: true, encoding: .utf8)
    check("恢复 capabilities 后可正常查询",
          runFull(Const.serviceBin.path, ["--ax-status"]).code <= 1)

    print()
    if failures == 0 {
        print("结果: 全部通过 ✓")
        exit(0)
    } else {
        print("结果: \(failures) 项失败 ✗")
        exit(1)
    }
}
