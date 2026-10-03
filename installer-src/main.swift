// 安装器逻辑的自动化测试驱动（控制台，不启动图形界面）
//
// 用真实的服务端二进制在临时目录里跑一遍 installService / ensureKey /
// installLaunchAgent，验证产出结构与权限，不触碰钥匙串与真实安装。

import Cocoa

// 测试用：仅在编译期用于定位源文件同名类型
let testSupportDir = ProcessInfo.processInfo.environment["BLEUNLOCK_SUPPORT_DIR"] ?? ""
let testLaunchAgent = ProcessInfo.processInfo.environment["BLEUNLOCK_LAUNCH_AGENT"] ?? ""
let serviceBinaryPath = ProcessInfo.processInfo.environment["BLEUNLOCK_TEST_BINARY"] ?? ""

var failures = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ✓ \(label)")
    } else {
        print("  ✗ \(label)  \(detail)")
        failures += 1
    }
}

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

func posixMode(_ url: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

print("=== 安装器逻辑测试 ===")
print("  支持目录: \(Const.supportDir.path)")
print("  LaunchAgent: \(Const.launchAgent.path)")
print()

let installer = Installer(log: { print("     [log] \($0)") })

// ---- 1. 安装服务端 ----
print("== 1. installService ==")
switch installer.installService() {
case .failed(let e):
    check("installService 成功", false, e)
case .ok:
    check("installService 成功", true)
}

check("服务端 bundle 存在", fileExists(Const.serviceApp))
check("可执行文件存在", fileExists(Const.serviceBin))
check("可执行文件权限为 755", posixMode(Const.serviceBin) == 0o755,
      "实际 \(String(posixMode(Const.serviceBin), radix: 8))")
check("Info.plist 存在", fileExists(Const.serviceApp.appendingPathComponent("Contents/Info.plist")))
check("capabilities 标记存在",
      fileExists(Const.serviceApp.appendingPathComponent("Contents/Resources/capabilities")))

let caps = (try? String(contentsOf: Const.serviceApp
    .appendingPathComponent("Contents/Resources/capabilities"), encoding: .utf8)) ?? ""
check("capabilities 含 ax-status", caps.contains("ax-status"), "内容: \(caps)")

let plist = (try? String(contentsOf: Const.serviceApp
    .appendingPathComponent("Contents/Info.plist"), encoding: .utf8)) ?? ""
check("Info.plist 含蓝牙权限说明", plist.contains("NSBluetoothAlwaysUsageDescription"))
check("Info.plist 含正确 BundleID", plist.contains(Const.bundleID))

// 服务端装好后应能运行
let ver = run(Const.serviceBin.path, ["--version"])
check("装好的服务端可运行", ver.code == 0, "退出码 \(ver.code)")
check("版本输出正常", ver.out.contains("BLEUnlockCmd"), "输出: \(ver.out)")

// ---- 2. 配对密钥 ----
print()
print("== 2. ensureKey ==")
switch installer.ensureKey() {
case .failed(let e): check("ensureKey 成功", false, e)
case .ok: check("ensureKey 成功", true)
}
check("config.json 存在", fileExists(Const.configFile))
check("config.json 权限为 600", posixMode(Const.configFile) == 0o600,
      "实际 \(String(posixMode(Const.configFile), radix: 8))")

var firstKey = ""
if let data = FileManager.default.contents(atPath: Const.configFile.path),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    firstKey = obj["hmacKey"] as? String ?? ""
    check("含 hmacKey", !firstKey.isEmpty)
    check("hmacKey 为 32 字节 base64",
          Data(base64Encoded: firstKey)?.count == 32,
          "长度 \(Data(base64Encoded: firstKey)?.count ?? -1)")
    check("含 deviceName", (obj["deviceName"] as? String)?.hasPrefix("BLEUnlock-") ?? false)
    check("含 keychainAccount", !(obj["keychainAccount"] as? String ?? "").isEmpty)
} else {
    check("config.json 可解析", false)
}

// 幂等性：重复执行不应更换密钥
switch installer.ensureKey() {
case .failed(let e): check("重复 ensureKey 成功", false, e)
case .ok: check("重复 ensureKey 成功", true)
}
var secondKey = ""
if let data = FileManager.default.contents(atPath: Const.configFile.path),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    secondKey = obj["hmacKey"] as? String ?? ""
}
check("重复安装不更换密钥", firstKey == secondKey && !firstKey.isEmpty)

check("配对令牌可读取", installer.pairingToken() == firstKey)

// ---- 3. LaunchAgent ----
print()
print("== 3. installLaunchAgent ==")
switch installer.installLaunchAgent() {
case .failed(let e): check("installLaunchAgent 成功", false, e)
case .ok: check("installLaunchAgent 成功", true)
}
check("plist 文件存在", fileExists(Const.launchAgent))

if let data = FileManager.default.contents(atPath: Const.launchAgent.path),
   let parsed = try? PropertyListSerialization.propertyList(
       from: data, options: [], format: nil) as? [String: Any] {
    check("plist 可解析", true)
    check("Label 正确", parsed["Label"] as? String == Const.serviceLabel,
          "实际 \(parsed["Label"] ?? "nil")")
    check("RunAtLoad 为 true", (parsed["RunAtLoad"] as? Bool) == true)
    check("KeepAlive 为 true", (parsed["KeepAlive"] as? Bool) == true)
    let args = parsed["ProgramArguments"] as? [String]
    check("ProgramArguments 指向服务端",
          args?.first == Const.serviceBin.path,
          "实际 \(args?.first ?? "nil")")
} else {
    check("plist 可解析", false)
}

// ---- 4. 升级场景 ----
print()
print("== 4. 升级场景（密钥应保留）==")
switch installer.installService() {
case .failed(let e): check("升级时 installService 成功", false, e)
case .ok: check("升级时 installService 成功", true)
}
switch installer.ensureKey() {
case .failed(let e): check("升级时 ensureKey 成功", false, e)
case .ok: check("升级时 ensureKey 成功", true)
}
var thirdKey = ""
if let data = FileManager.default.contents(atPath: Const.configFile.path),
   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    thirdKey = obj["hmacKey"] as? String ?? ""
}
check("升级后密钥保持不变", thirdKey == firstKey && !firstKey.isEmpty)
check("升级后服务端仍可运行", run(Const.serviceBin.path, ["--version"]).code == 0)
check("升级后 capabilities 仍存在",
      fileExists(Const.serviceApp.appendingPathComponent("Contents/Resources/capabilities")))

// ---- 5. 签名 ----
print()
print("== 5. 签名 ==")
let cs = run("/usr/bin/codesign", ["-v", Const.serviceApp.path])
check("服务端签名有效", cs.code == 0, "退出码 \(cs.code)")

print()
if failures == 0 {
    print("结果: 全部通过 ✓")
    exit(0)
} else {
    print("结果: \(failures) 项失败 ✗")
    exit(1)
}
